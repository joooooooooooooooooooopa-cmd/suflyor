import Foundation

/// `Suflyor --brain-smoke "Клиент: а сколько стоит подключение?"` — разовая ручная проверка
/// настоящего мозга: прогрев, время до первого слова, ответ целиком. В тестах не используется,
/// чтобы прогон тестов не ходил в сеть.
///
/// С `--topic "…"` вместо вопроса прогоняется подготовка шпаргалки по теме.
public enum BrainSmoke {
    public static func run(text: String?, topic: String? = nil, mode: SessionMode = .product) -> Int32 {
        let fm = FileManager.default
        let system = ProjectPaths.systemPrompt
        let briefURL = ProjectPaths.brief(mode)
        let brief = fm.fileExists(atPath: briefURL.path) ? briefURL : nil
        print("корень: \(ProjectPaths.root().path)")
        print("мозг: \(BrainLaunch.findBrainBinary() ?? "не найден")")
        print("бриф: \(brief == nil ? "нет (\(briefURL.lastPathComponent))" : briefURL.path)")

        let cbq = DispatchQueue(label: "suflyor.smoke")
        let brain = Brain(config: .init(systemPromptFile: system, briefFile: brief), callbackQueue: cbq)
        let warmed = DispatchSemaphore(value: 0)
        let answered = DispatchSemaphore(value: 0)
        var failure: String?
        var firstDelta: Date?
        var askedAt = Date()
        var full = ""
        var total: TimeInterval = 0

        brain.onStatus = { s in
            switch s {
            case .warming, .timedOut: break
            case .ready: warmed.signal()
            case .unavailable(let why):
                failure = why
                warmed.signal()
                answered.signal()
            }
        }
        brain.onDelta = { _, _ in if firstDelta == nil { firstDelta = Date() } }
        brain.onAnswerFailed = { _, why in
            failure = why
            answered.signal()
        }
        brain.onAnswerEnd = { _, text, secs in
            full = text
            total = secs
            answered.signal()
        }

        let t0 = Date()
        brain.start()
        guard warmed.wait(timeout: .now() + 120) == .success, cbq.sync(execute: { failure }) == nil else {
            print("прогрев не удался: \(cbq.sync { failure } ?? "таймаут 120 с")")
            brain.stop(wait: true)
            return 1
        }
        print(String(format: "прогрев: %.1f с", Date().timeIntervalSince(t0)))

        cbq.sync { askedAt = Date() }
        if let topic {
            let t = CallTopic(topic: topic)
            print("тема: \(t.topic)")
            brain.prepare(t.prepMessage)
        } else {
            let text = text ?? "Клиент: а сколько стоит подключение?"
            let u = Utterance(seq: 0, channel: .they, text: text, start: Date(), end: Date())
            brain.ask(BrainPrompt.build(log: [], question: PendingQuestion(u)), label: text)
        }
        let ok = answered.wait(timeout: .now() + 120) == .success
        brain.stop(wait: true)
        return cbq.sync {
            guard ok, failure == nil else {
                print("ответа нет: \(failure ?? "таймаут 120 с")")
                return 1
            }
            if let f = firstDelta {
                print(String(format: "до первого слова: %.1f с", f.timeIntervalSince(askedAt)))
            }
            print(String(format: "ответ целиком: %.1f с", total))
            print("---\n\(full)\n---")
            if topic != nil {
                let sheet = CheatSheet.parse(full)
                print("разобрано: главное \(sheet.main.count), спросят \(sheet.asks.count), ссылок \(sheet.links.count)")
            }
            return 0
        }
    }
}
