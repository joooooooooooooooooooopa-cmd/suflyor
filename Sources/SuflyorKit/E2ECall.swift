import AVFoundation
import Foundation

/// `Suflyor --e2e-call they.wav me.wav [--topic "…"] [--speed N]` — сквозная проверка без интерфейса
/// и без разрешений macOS: два файла вместо захвата звука идут по тому же пути, что в сессии
/// (ChannelPipeline → whisper-server → TranscriptStore → детектор → мозг), и печатается лог.
public enum E2ECall {
    /// Сколько ждать шпаргалку перед подачей звука: в прогоне её ждём, чтобы напечатать.
    static let prepLimit: TimeInterval = 40

    public struct Summary: Equatable {
        public var utterances = 0
        public var asked = 0
        public var answered = 0
        public var failed = 0
        public var firstWord: [TimeInterval] = []
        public var full: [TimeInterval] = []
    }

    /// Файл → моно 16 кГц Float32 (любой формат, который читает AVAudioFile).
    static func loadMono16k(_ url: URL) throws -> [Float] {
        let f = try AVAudioFile(forReading: url)
        guard let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length)) else {
            throw CaptureError.other("не прочитать \(url.lastPathComponent)")
        }
        try f.read(into: buf)
        return MonoResampler().convert(buf)
    }

    /// Ядро прогона. `transcribe` и `brainConfig` подменяются в тестах (фейковый whisper и мозг).
    /// `speed` — во сколько раз быстрее реального времени подавать звук (.infinity — без пауз);
    /// время реплик в логе — по звуку, а не по часам, поэтому порядок и тайминги сохраняются.
    /// `projectRoot` — где искать prompts/ и briefs/ (тесты); nil — `ProjectPaths.root()`.
    static func runCore(they: [Float], me: [Float], topic: CallTopic, speed: Double,
                        transcribe: @escaping (Data) -> String?, brainConfig: Brain.Config? = nil,
                        projectRoot: URL? = nil,
                        debounce: TimeInterval = Prompter.debounceDelay, quietWait: TimeInterval = 30,
                        log: @escaping (String) -> Void) -> Summary {
        let q = DispatchQueue(label: "suflyor.e2e")
        let store = TranscriptStore()
        let model = PanelModel()
        let p = Prompter(mode: .product, store: store, model: model, queue: q)
        p.brainConfig = brainConfig
        p.projectRoot = projectRoot
        p.debounceDelay = debounce
        p.topic = topic
        // Без --topic — как в приложении: тема определяется по первой минуте разговора.
        p.autoTopic = topic.isEmpty
        p.onTopic = { t in log("  ★ тема по разговору: \(t.header ?? t.topic)") }

        var summary = Summary()
        var pending = 0
        var lastEvent = Date()
        var prepDone: Bool?
        p.onPrepDone = { ok in prepDone = ok }
        p.onEvent = { e in
            lastEvent = Date()
            switch e {
            case .asked(let label):
                summary.asked += 1
                pending += 1
                log("  → вопрос мозгу: \(label)")
            case .firstWord(_, let s):
                summary.firstWord.append(s)
                log(String(format: "  ← первое слово через %.1f с", s))
            case .answered(_, let text, let s):
                summary.answered += 1
                summary.full.append(s)
                pending = max(0, pending - 1)
                log(String(format: "  ← подсказка целиком за %.1f с:", s))
                for line in text.components(separatedBy: "\n") where !line.isEmpty { log("     \(line)") }
                if let raw = HintParts.parse(text).url {
                    switch model.whitelist.resolve(raw) {
                    case .allowed(let u): log("     ссылка (белый список): \(u)\(u == raw ? "" : " — восстановлена из «\(raw)»")")
                    case .rejected: log("     ссылка «\(raw)»: \(LinkWhitelist.rejectedNote)")
                    }
                }
            case .failed(let label, let why):
                summary.failed += 1
                pending = max(0, pending - 1)
                log("  ← нет ответа на «\(label)»: \(why)")
            }
        }

        func waitOnQueue(_ timeout: TimeInterval, _ cond: () -> Bool) -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if q.sync(execute: cond) { return true }
                Thread.sleep(forTimeInterval: 0.05)
            }
            return q.sync(execute: cond)
        }

        q.sync { p.start() }
        let t0 = Date()
        guard waitOnQueue(60, { model.brainState == .ready || isFailure(model.brainState) }),
              model.brainState == .ready else {
            log("мозг не прогрелся: \(q.sync { model.brainState })")
            q.sync { p.stop(wait: true) }
            return summary
        }
        log(String(format: "мозг готов за %.1f с", Date().timeIntervalSince(t0)))

        if !topic.isEmpty {
            let tp = Date()
            q.sync { p.prepare(topic) }
            _ = waitOnQueue(prepLimit) { prepDone != nil }
            let ok = q.sync { prepDone == true }
            log(String(format: "шпаргалка: %@ за %.1f с", ok ? "готова" : "не готова", Date().timeIntervalSince(tp)))
            if ok { for line in q.sync(execute: { model.cheatText }).components(separatedBy: "\n") { log("  │ \(line)") } }
        }

        let transcriber = Transcriber(store: store, transcribe: transcribe)
        let theyPipe = ChannelPipeline(channel: .they, transcriber: transcriber)
        let mePipe = ChannelPipeline(channel: .me, transcriber: transcriber)
        q.sync { p.listening = true }
        let feedStart = Date()
        store.subscribe { u in
            let t = u.start.timeIntervalSince(feedStart)
            let line = String(format: "[%02d:%04.1f] %@: %@", Int(t) / 60, t.truncatingRemainder(dividingBy: 60),
                              u.channel == .they ? "ОНИ" : "Я", u.text)
            q.async { log(line) }
        }

        // Оба канала кусками по 0.1 с вперемешку — как приходит из захвата звука.
        let chunk = 1_600
        let total = max(they.count, me.count)
        var i = 0
        while i < total {
            if i < they.count { theyPipe.feed(Array(they[i..<min(i + chunk, they.count)])) }
            if i < me.count { mePipe.feed(Array(me[i..<min(i + chunk, me.count)])) }
            i += chunk
            if speed.isFinite { Thread.sleep(forTimeInterval: 0.1 / speed) }
        }
        theyPipe.flush()
        mePipe.flush()
        transcriber.waitUntilIdle()
        // Ждём, пока сработает последний дебаунс и мозг ответит на всё, что успел получить.
        // Вытесненный в очереди вопрос ответа не получит — поэтому выходим и по тишине.
        Thread.sleep(forTimeInterval: debounce + 0.2)
        _ = waitOnQueue(120) { pending == 0 || Date().timeIntervalSince(lastEvent) > quietWait }
        q.sync { p.stop(wait: true) }
        var out = q.sync { summary }
        out.utterances = store.utterances.count
        return out
    }

    static func isFailure(_ s: BrainState) -> Bool {
        switch s {
        case .error, .limit: return true
        default: return false
        }
    }

    static func describe(_ s: Summary) -> String {
        func stat(_ xs: [TimeInterval]) -> String {
            guard !xs.isEmpty else { return "—" }
            return String(format: "ср %.1f с, макс %.1f с", xs.reduce(0, +) / Double(xs.count), xs.max()!)
        }
        return """
        ИТОГ: реплик \(s.utterances), вопросов мозгу \(s.asked), ответов \(s.answered), без ответа \(s.failed)
        до первого слова: \(stat(s.firstWord)); подсказка целиком: \(stat(s.full))
        """
    }

    /// Разбор аргументов и прогон с настоящими whisper-server и мозгом.
    public static func run(arguments args: [String]) -> Int32 {
        guard let i = args.firstIndex(of: "--e2e-call"), i + 2 < args.count else {
            print("использование: Suflyor --e2e-call they.wav me.wav [--topic \"…\"] [--speed N]")
            return 2
        }
        func value(_ flag: String) -> String? {
            guard let j = args.firstIndex(of: flag), j + 1 < args.count else { return nil }
            return args[j + 1]
        }
        let topic = CallTopic(topic: value("--topic") ?? "")
        let speed = value("--speed").flatMap(Double.init) ?? 1
        let they: [Float], me: [Float]
        do {
            they = try loadMono16k(URL(fileURLWithPath: args[i + 1]))
            me = try loadMono16k(URL(fileURLWithPath: args[i + 2]))
        } catch {
            print("не прочитать звук: \(error.localizedDescription)")
            return 1
        }
        print(String(format: "звук: они %.1f с, я %.1f с; скорость ×%g; тема: %@",
                     Double(they.count) / 16_000, Double(me.count) / 16_000, speed, topic.isEmpty ? "—" : topic.topic))
        let server = WhisperServer()
        do { try server.start() } catch {
            print("whisper-server: \(error.localizedDescription)")
            return 1
        }
        defer { server.stop() }
        let client = WhisperClient(baseURL: server.baseURL, language: server.config.language)
        let s = runCore(they: they, me: me, topic: topic, speed: speed,
                        transcribe: { client.transcribe(wav: $0) }, log: { print($0) })
        print(describe(s))
        return s.asked > 0 && s.answered > 0 ? 0 : 1
    }
}
