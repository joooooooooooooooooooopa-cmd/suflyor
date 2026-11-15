import Foundation

/// Очередь расшифровки: до 2 запросов к whisper параллельно, порядок держит TranscriptStore.
public final class Transcriber {
    public typealias Backend = (Data) -> String?

    public let store: TranscriptStore
    private let queue: OperationQueue
    private let lock = NSLock()
    /// nil — whisper ещё не поднялся или перезапускается: такие фразы просто освобождают бронь.
    private var backend: Backend?
    /// Номер бэкенда: ответы от старого (уже заменённого) whisper в счётчик сбоев не идут.
    private var generation = 0
    private var failuresInRow = 0
    private var failureReported = false
    /// Короче секунды whisper.cpp отказывается считать — добиваем тишиной.
    static let minSamples = 17_600
    /// Столько ответов подряд без текста (таймаут, обрыв, 500) — whisper считаем упавшим.
    public static let failuresToReport = 3
    /// whisper перестал отвечать: зовётся один раз на бэкенд, на рабочей очереди транскрайбера.
    public var onBackendFailure: (() -> Void)?

    /// `transcribe` подменяется в тестах; в приложении это WhisperClient.transcribe,
    /// который подставляется через `setBackend`, когда whisper готов.
    public init(store: TranscriptStore, maxConcurrent: Int = 2, transcribe: Backend? = nil) {
        self.store = store
        self.backend = transcribe
        queue = OperationQueue()
        queue.name = "suflyor.transcriber"
        queue.maxConcurrentOperationCount = maxConcurrent
        queue.qualityOfService = .userInitiated
    }

    /// Переключить на другой whisper (перезапуск на новом порту) или снять (nil). Счётчик сбоев — с нуля.
    public func setBackend(_ b: Backend?) {
        lock.lock()
        backend = b
        generation += 1
        failuresInRow = 0
        failureReported = false
        lock.unlock()
    }

    /// Время фразы — от начала потока канала по числу сэмплов (тесты и старые вызовы).
    public func submit(_ seg: SpeechSegment, channel: Channel, streamStart: Date) {
        submit(seg, channel: channel, start: streamStart.addingTimeInterval(seg.startTime),
               end: streamStart.addingTimeInterval(seg.endTime))
    }

    public func submit(_ seg: SpeechSegment, channel: Channel, start: Date, end: Date) {
        // Бронь — сразу, в момент окончания фразы: так порядок в логе совпадает с порядком речи.
        let ticket = store.reserve(channel)
        var samples = seg.samples
        if samples.count < Self.minSamples {
            samples.append(contentsOf: [Float](repeating: 0, count: Self.minSamples - samples.count))
        }
        let store = self.store
        let op = BlockOperation { [weak self] in
            guard let self else { store.fulfill(ticket, text: nil, start: start, end: end); return }
            self.lock.lock()
            let b = self.backend, gen = self.generation
            self.lock.unlock()
            var text: String?
            if let b {
                text = b(WAV.encode(samples: samples))
                self.record(ok: text != nil, generation: gen)
            }
            store.fulfill(ticket, text: text, start: start, end: end)
        }
        // Собеседника расшифровываем первым: подсказка нужна на его вопрос, а не на мой монолог.
        op.queuePriority = channel == .they ? .high : .normal
        queue.addOperation(op)
    }

    private func record(ok: Bool, generation gen: Int) {
        lock.lock()
        guard gen == generation else { lock.unlock(); return }
        var fire = false
        if ok {
            failuresInRow = 0
        } else {
            failuresInRow += 1
            if failuresInRow >= Self.failuresToReport, !failureReported {
                failureReported = true
                fire = true
            }
        }
        let cb = onBackendFailure
        lock.unlock()
        if fire { cb?() }
    }

    public func waitUntilIdle() { queue.waitUntilAllOperationsAreFinished() }
}

/// Канал: сэмплы 16 кГц моно → VAD → фразы в транскрайбер.
/// Всё на своей последовательной очереди, чтобы колбэк захвата звука не ждал.
///
/// Время фразы — по настенным часам: конец фразы привязан к моменту, когда пришла пачка
/// с её последним сэмплом. Счёт «первый сэмпл + число сэмплов» плывёт на каждом разрыве потока
/// (перезапуск микрофона, обрыв SCK, сон мака), и каналы «я»/«они» разъезжаются — ломается
/// сверка эха и порядок реплик.
public final class ChannelPipeline {
    public let channel: Channel
    /// Сколько звука держим, пока whisper не готов: дольше — старое выбрасываем, память не растёт.
    public static let holdLimit: TimeInterval = 10
    static let sampleRate = 16_000.0

    private let vad = EnergyVAD()
    private let transcriber: Transcriber
    private let queue: DispatchQueue
    private var isOpen: Bool
    private var held: [(samples: [Float], at: Date)] = []
    private var heldCount = 0
    /// Сколько сэмплов уже отдано VAD (выброшенные из буфера не в счёт).
    private var fed = 0
    private var lastArrival: Date?

    /// `open: false` — звук копится (до `holdLimit`), пока не позовут `open()`.
    public init(channel: Channel, transcriber: Transcriber, open: Bool = true) {
        self.channel = channel
        self.transcriber = transcriber
        self.isOpen = open
        self.queue = DispatchQueue(label: "suflyor.pipeline.\(channel.rawValue)")
    }

    /// `at` — момент прихода пачки (в приложении — сейчас, в тестах — подставной).
    public func feed(_ samples: [Float], at: Date = Date()) {
        queue.async { [self] in
            if isOpen {
                process(samples, at: at)
            } else {
                hold(samples, at: at)
            }
        }
    }

    /// whisper готов: отдать накопленное и дальше работать без буфера.
    public func open() {
        queue.async { [self] in
            isOpen = true
            let batches = held
            held = []
            heldCount = 0
            for b in batches { process(b.samples, at: b.at) }
        }
    }

    /// whisper перезапускается: копить звук, а не слать в мёртвый сервер.
    public func pause() {
        queue.async { [self] in isOpen = false }
    }

    public func flush() {
        queue.sync { [self] in
            guard isOpen, let seg = vad.flush(), let at = lastArrival else { return }
            submit(seg, at: at)
        }
    }

    private func hold(_ samples: [Float], at: Date) {
        held.append((samples, at))
        heldCount += samples.count
        let limit = Int(Self.holdLimit * Self.sampleRate)
        while heldCount > limit, let first = held.first {
            heldCount -= first.samples.count
            held.removeFirst()
        }
    }

    private func process(_ samples: [Float], at: Date) {
        let segs = vad.process(samples)
        fed += samples.count
        lastArrival = at
        for seg in segs { submit(seg, at: at) }
    }

    /// Последний отданный VAD сэмпл пришёл в `at`; конец фразы — раньше на столько, сколько сэмплов после него.
    private func submit(_ seg: SpeechSegment, at: Date) {
        let endIndex = Int((seg.endTime * Self.sampleRate).rounded())
        let end = at.addingTimeInterval(-Double(max(0, fed - endIndex)) / Self.sampleRate)
        transcriber.submit(seg, channel: channel, start: end.addingTimeInterval(-seg.duration), end: end)
    }
}
