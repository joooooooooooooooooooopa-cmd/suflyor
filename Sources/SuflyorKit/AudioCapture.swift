import AVFoundation
import CoreMedia
import ScreenCaptureKit

/// Приведение любого PCM-буфера к моно 16 кГц Float32 — формату, который ждёт VAD и whisper.
final class MonoResampler {
    static let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
                                      channels: 1, interleaved: false)!
    private var converter: AVAudioConverter?
    private var sourceFormat: AVAudioFormat?

    func convert(_ buffer: AVAudioPCMBuffer) -> [Float] {
        let fmt = buffer.format
        if fmt.sampleRate == 16_000, fmt.channelCount == 1, fmt.commonFormat == .pcmFormatFloat32,
           let ch = buffer.floatChannelData {
            return Array(UnsafeBufferPointer(start: ch[0], count: Int(buffer.frameLength)))
        }
        if sourceFormat != fmt {
            converter = AVAudioConverter(from: fmt, to: Self.target)
            // Стерео → моно: смешиваем каналы, а не берём левый (в созвонах бывает звук только справа).
            converter?.downmix = true
            sourceFormat = fmt
        }
        guard let converter else { return [] }
        let ratio = 16_000 / fmt.sampleRate
        let cap = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: Self.target, frameCapacity: cap) else { return [] }
        var fed = false
        var err: NSError?
        converter.convert(to: out, error: &err) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        guard err == nil, let ch = out.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: ch[0], count: Int(out.frameLength)))
    }
}

public enum CaptureError: LocalizedError {
    /// Вход есть, но формат ещё 0 Гц / 0 каналов: устройство (обычно Bluetooth) поднимается.
    case micNotReady
    case screenDenied
    case noDisplay
    case other(String)

    public var errorDescription: String? {
        switch self {
        case .micNotReady:
            return "Микрофон ещё не готов."
        case .screenDenied:
            return "Нет доступа к звуку системы. Системные настройки → Конфиденциальность и безопасность → Запись экрана и системного звука → включить Suflyor, затем перезапустить приложение."
        case .noDisplay:
            return "Не найден дисплей для захвата звука системы."
        case .other(let s):
            return s
        }
    }
}

/// Источник буферов микрофона. В приложении — AVAudioEngine, в тестах — фейк:
/// так перезапуск при смене устройства проверяется без настоящего звука и разрешений.
protocol MicSource: AnyObject {
    /// Устройство или его формат сменились, источник замолчал — его надо пересоздать.
    var onConfigurationChange: (() -> Void)? { get set }
    func start(onBuffer: @escaping (AVAudioPCMBuffer) -> Void) throws
    func stop()
}

/// Микрофон через AVAudioEngine. Engine одноразовый: после смены устройства создаём новый,
/// старый на macOS может остаться привязан к ушедшему входу.
final class EngineMicSource: MicSource {
    private let engine = AVAudioEngine()
    private var observer: NSObjectProtocol?
    var onConfigurationChange: (() -> Void)?

    func start(onBuffer: @escaping (AVAudioPCMBuffer) -> Void) throws {
        let input = engine.inputNode
        // installTap при нулевом или разъехавшемся формате кидает исключение ObjC, которое Swift
        // не ловит, — приложение падает посреди созвона. Так бывает в первые доли секунды после
        // подключения AirPods: формат входа ещё 0 Гц или уже другой, чем у выхода узла.
        // Поэтому сверяем заранее и, если не готово, просим подождать и повторить.
        let hw = input.inputFormat(forBus: 0)
        let fmt = input.outputFormat(forBus: 0)
        guard hw.sampleRate > 0, hw.channelCount > 0, fmt.sampleRate > 0, fmt.channelCount > 0,
              hw.sampleRate == fmt.sampleRate else {
            throw CaptureError.micNotReady
        }
        observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in self?.onConfigurationChange?() }
        input.installTap(onBus: 0, bufferSize: 4096, format: fmt) { buf, _ in onBuffer(buf) }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        if let o = observer { NotificationCenter.default.removeObserver(o) }
        observer = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }
}

/// Микрофон. Переживает смену устройства посреди созвона: надели AirPods, сняли, сменили вход
/// в настройках — AVAudioEngine при этом молча останавливается, и без перезапуска канал «я» глохнет.
public final class MicCapture {
    /// Пауза перед повторной попыткой: новое устройство (Bluetooth) появляется не сразу.
    static let retryDelay: TimeInterval = 1
    static let maxRetries = 5
    /// AirPods при подключении шлют несколько смен конфигурации подряд: перезапускаемся один раз,
    /// когда устройство успокоилось, а не на каждое уведомление.
    static let settleDelay: TimeInterval = 0.7
    /// Больше перезапусков за окно — устройство дёргается по кругу; сдаёмся, чтобы не крутить вечно.
    static let maxRestarts = 6
    static let restartWindow: TimeInterval = 30

    private let resampler = MonoResampler()
    private let onSamples: ([Float]) -> Void
    private let makeSource: () -> MicSource
    private let queue = DispatchQueue(label: "suflyor.mic")
    private var source: MicSource?
    private var stopped = false
    private var restarts: [Date] = []
    private var pendingRestart: DispatchWorkItem?
    var retryDelay = MicCapture.retryDelay
    var settleDelay = MicCapture.settleDelay
    /// Перезапуск после смены устройства (для журнала); зовётся на своей очереди.
    var onRestart: (() -> Void)?
    /// Микрофон пропал и не вернулся после всех попыток.
    var onError: ((Error) -> Void)?

    public convenience init(onSamples: @escaping ([Float]) -> Void) {
        self.init(onSamples: onSamples, makeSource: { EngineMicSource() })
    }

    init(onSamples: @escaping ([Float]) -> Void, makeSource: @escaping () -> MicSource) {
        self.onSamples = onSamples
        self.makeSource = makeSource
    }

    public static func requestAccess(_ done: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: done(true)
        case .notDetermined: AVCaptureDevice.requestAccess(for: .audio) { done($0) }
        default: done(false)
        }
    }

    /// Первый запуск: ошибку отдаём сразу — это «нет микрофона», а не смена устройства.
    /// Исключение — вход ещё не готов (0 Гц): тогда ждём и повторяем в фоне, как после смены устройства.
    public func start() throws {
        try queue.sync {
            do {
                try startSource()
            } catch CaptureError.micNotReady {
                queue.asyncAfter(deadline: .now() + retryDelay) { [weak self] in self?.attempt(1) }
            }
        }
    }

    public func stop() {
        queue.sync {
            stopped = true
            pendingRestart?.cancel()
            pendingRestart = nil
            source?.stop()
            source = nil
        }
    }

    /// На `queue`.
    private func startSource() throws {
        let s = makeSource()
        s.onConfigurationChange = { [weak self, weak s] in
            guard let self, let s else { return }
            self.queue.async { self.scheduleRestart(from: s) }
        }
        try s.start { [weak self] buf in
            guard let self else { return }
            let samples = self.resampler.convert(buf)
            if !samples.isEmpty { self.onSamples(samples) }
        }
        source = s
    }

    /// Каждое новое уведомление откладывает перезапуск ещё на `settleDelay`: пачка уведомлений — один перезапуск.
    private func scheduleRestart(from s: MicSource) {
        guard !stopped, source === s else { return }
        pendingRestart?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.restart(from: s) }
        pendingRestart = w
        queue.asyncAfter(deadline: .now() + settleDelay, execute: w)
    }

    /// Устаревшие уведомления (от уже заменённого источника) пропускаем: одно событие — один перезапуск.
    private func restart(from s: MicSource) {
        pendingRestart = nil
        guard !stopped, source === s else { return }
        s.stop()
        source = nil
        let now = Date()
        restarts = restarts.filter { now.timeIntervalSince($0) < Self.restartWindow } + [now]
        guard restarts.count <= Self.maxRestarts else {
            onError?(CaptureError.other("Микрофон перезапускается по кругу — остановил"))
            return
        }
        attempt(0)
    }

    private func attempt(_ n: Int) {
        guard !stopped, source == nil else { return }
        do {
            try startSource()
            onRestart?()
        } catch {
            guard n < Self.maxRetries else { onError?(error); return }
            queue.asyncAfter(deadline: .now() + retryDelay) { [weak self] in self?.attempt(n + 1) }
        }
    }
}

/// Звук системы через ScreenCaptureKit. Видео не нужно, но SCStream без него не живёт —
/// просим кадр 2×2 раз в секунду и выбрасываем.
public final class SystemAudioCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    /// Пишет start (async), читают stop с фоновой очереди и выход приложения — под замком.
    private let lock = NSLock()
    private var stream: SCStream?
    private let resampler = MonoResampler()
    private let onSamples: ([Float]) -> Void
    private let onError: (Error) -> Void
    private let audioQueue = DispatchQueue(label: "suflyor.sck.audio")
    private let videoQueue = DispatchQueue(label: "suflyor.sck.video")

    public init(onSamples: @escaping ([Float]) -> Void, onError: @escaping (Error) -> Void) {
        self.onSamples = onSamples
        self.onError = onError
    }

    public func start() async throws {
        if !CGPreflightScreenCaptureAccess() {
            // Первый вызов показывает системный запрос; разрешение вступит в силу после перезапуска.
            CGRequestScreenCaptureAccess()
            throw CaptureError.screenDenied
        }
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw CaptureError.screenDenied
        }
        guard let display = content.displays.first else { throw CaptureError.noDisplay }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let cfg = SCStreamConfiguration()
        cfg.capturesAudio = true
        // Свой звук не слушаем: иначе будущие звуковые подсказки попадут в «Они».
        cfg.excludesCurrentProcessAudio = true
        cfg.sampleRate = 16_000
        cfg.channelCount = 1
        cfg.width = 2
        cfg.height = 2
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        cfg.queueDepth = 3
        cfg.showsCursor = false

        let s = SCStream(filter: filter, configuration: cfg, delegate: self)
        try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: videoQueue)
        try await s.startCapture()
        lock.withLock { stream = s }
    }

    /// Остановка без Swift Concurrency, с ожиданием не дольше `timeout`. Звать не с main:
    /// при выходе main ждёт, и Task с await на нём может так и не стартовать — раньше это съедало 2 с.
    public func stopBlocking(timeout: TimeInterval = 1.5) {
        guard let s = lock.withLock({ () -> SCStream? in defer { stream = nil }; return stream }) else { return }
        let sem = DispatchSemaphore(value: 0)
        s.stopCapture { _ in sem.signal() }
        _ = sem.wait(timeout: .now() + timeout)
    }

    /// Остановить в фоне и не ждать (конец сессии, перезапуск после обрыва).
    public func stopInBackground() {
        DispatchQueue.global(qos: .utility).async { self.stopBlocking() }
    }

    public func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sb.isValid, let pcm = Self.pcmBuffer(from: sb) else { return }
        let s = resampler.convert(pcm)
        if !s.isEmpty { onSamples(s) }
    }

    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        onError(error)
    }

    /// CMSampleBuffer → AVAudioPCMBuffer копированием (буфер SCK живёт только в колбэке).
    static func pcmBuffer(from sb: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let desc = sb.formatDescription,
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc) else { return nil }
        var streamDesc = asbd.pointee
        guard let fmt = AVAudioFormat(streamDescription: &streamDesc) else { return nil }
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sb))
        guard frames > 0, let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames) else { return nil }
        buf.frameLength = frames
        let st = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sb, at: 0, frameCount: Int32(frames), into: buf.mutableAudioBufferList)
        return st == noErr ? buf : nil
    }
}

/// Запас перезапусков потока, который восстанавливается, если поток после перезапуска прожил
/// `stableAfter` без обрыва. Иначе три случайных обрыва за весь долгий созвон (сменили дисплей утром
/// и вечером) навсегда оставили бы «они» без звука.
struct RetryBudget {
    let max: Int
    let stableAfter: TimeInterval
    private(set) var left: Int
    private var startedAt: Date?

    init(max: Int, stableAfter: TimeInterval) {
        self.max = max
        self.stableAfter = stableAfter
        self.left = max
    }

    /// Поток поднялся.
    mutating func started(at t: Date) { startedAt = t }

    /// Поток оборвался: true — можно поднять ещё раз (попытка списана).
    mutating func failed(at t: Date) -> Bool {
        if let s = startedAt, t.timeIntervalSince(s) >= stableAfter { left = max }
        startedAt = nil
        guard left > 0 else { return false }
        left -= 1
        return true
    }
}
