import Foundation

/// Разбор потока stream-json от процесса мозга: одна JSON-строка — одно событие.
public enum BrainStream {
    public enum Event: Equatable {
        /// Кусок текста ответа (потоковая выдача).
        case delta(String)
        /// Конец ответа. `error != nil` — ответа не будет (ошибка, лимит).
        case result(text: String, error: String?)
    }

    /// nil — строка не про текст ответа (init, служебные события) или вообще не JSON.
    public static func parse(_ line: String) -> Event? {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else { return nil }
        switch type {
        case "stream_event":
            guard let ev = obj["event"] as? [String: Any], ev["type"] as? String == "content_block_delta",
                  let delta = ev["delta"] as? [String: Any], delta["type"] as? String == "text_delta",
                  let text = delta["text"] as? String else { return nil }
            return .delta(text)
        case "result":
            let text = obj["result"] as? String ?? ""
            let isError = obj["is_error"] as? Bool ?? false
            let subtype = obj["subtype"] as? String ?? "success"
            if isError || subtype != "success" {
                return .result(text: text, error: short(text.isEmpty ? subtype : text))
            }
            // Текст успешного ответа на маркеры лимита не проверяем: подсказка вида «у вас rate limit
            // на API» — нормальный ответ, а не лимит. Лимит приходит с is_error.
            return .result(text: text, error: nil)
        default:
            return nil
        }
    }

    /// Сколько токенов ушло на ответ: по ним видно, как растёт контекст процесса и работает ли кэш.
    public struct Usage: Equatable {
        public var input = 0
        public var cacheRead = 0
        public var cacheCreation = 0
        public var output = 0

        /// Весь вход хода — это и есть размер контекста процесса (кэш тоже вход, просто дешевле).
        public var totalInput: Int { input + cacheRead + cacheCreation }
    }

    /// usage из строки result; nil — строка не result или usage в ней нет.
    public static func usage(_ line: String) -> Usage? {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              obj["type"] as? String == "result",
              let u = obj["usage"] as? [String: Any] else { return nil }
        func n(_ k: String) -> Int { (u[k] as? NSNumber)?.intValue ?? 0 }
        return Usage(input: n("input_tokens"), cacheRead: n("cache_read_input_tokens"),
                     cacheCreation: n("cache_creation_input_tokens"), output: n("output_tokens"))
    }

    static let limitMarkers = ["usage limit", "rate limit", "limit reached", "hit your limit", "limit will reset"]

    /// Только для текста ошибки (is_error или пустой ответ): лимит это или другая беда.
    /// Только английские маркеры и только в коротком тексте: русское «лимит» вполне
    /// может быть в нормальной подсказке («лимит по карте 5000»).
    static func looksLikeLimit(_ text: String) -> Bool {
        guard text.count < 300 else { return false }
        let t = text.lowercased()
        return limitMarkers.contains { t.contains($0) }
    }

    static func short(_ s: String) -> String {
        let one = s.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        return one.count > 120 ? String(one.prefix(120)) + "…" : one
    }
}

/// Сборка одного ответа из потока строк.
public struct BrainAnswerAccumulator {
    public enum Output: Equatable {
        case delta(String)
        case finished(String)
        case failed(String)
    }

    public private(set) var text = ""

    public init() {}

    public mutating func feed(_ line: String) -> Output? {
        switch BrainStream.parse(line) {
        case .delta(let s)?:
            text += s
            return .delta(s)
        case .result(let full, let error)?:
            if let error { return .failed(error) }
            // Без частичных событий весь текст приходит только в result.
            if text.isEmpty { text = full }
            // Пустой «успешный» ответ — не ответ: так процесс иногда отдаёт лимит без текста.
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .failed("пустой ответ") }
            return .finished(text)
        case nil:
            return nil
        }
    }
}

/// Запуск процесса мозга: аргументы, окружение и поиск бинаря.
public enum BrainLaunch {
    static let brainBinaryName = "llm-cli"

    /// Модель ответов на вопросы: самая умная, ответы короткие. Переопределить — `SUFLYOR_BRAIN_MODEL`.
    public static let defaultModel = "smart"
    /// Фоновая работа (шпаргалка, тема) длинная и не срочная: ей хватает модели попроще,
    /// а лимиты основной модели остаются вопросам.
    public static let backgroundModel = "fast"
    /// Если основная модель перегружена, процесс сам переключается на запасную, а не молчит до таймаута.
    public static let fallbackModel = "fast"
    /// Низкий effort: подсказка нужна за секунды, долгие размышления ей не помогают.
    /// Переопределить — `SUFLYOR_BRAIN_EFFORT` (пусто или `default` — без флага, как у CLI по умолчанию).
    public static let defaultEffort = "low"

    public static func model(env: [String: String] = ProcessInfo.processInfo.environment) -> String {
        if let m = env["SUFLYOR_BRAIN_MODEL"]?.trimmingCharacters(in: .whitespaces), !m.isEmpty { return m }
        return defaultModel
    }

    /// nil — флаг `--effort` не передаём.
    public static func effort(env: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        guard let e = env["SUFLYOR_BRAIN_EFFORT"]?.trimmingCharacters(in: .whitespaces) else { return defaultEffort }
        return e.isEmpty || e == "default" ? nil : e
    }

    /// Флаги изоляции обязательны: без них процесс подтянул бы чужие настройки,
    /// MCP-серверы и инструменты (файлы, shell) — суфлёру они не нужны и опасны.
    /// `--safe-mode` вдобавок выключает файлы инструкций проекта, память, хуки и плагины:
    /// так изолируем CLI от пользовательских настроек.
    public static func arguments(model: String, effort: String? = nil, fallbackModel: String? = nil,
                                 systemPromptFile: URL, briefFile: URL?) -> [String] {
        var a = [
            "-p",
            "--safe-mode",
            "--model", model,
        ]
        if let effort { a += ["--effort", effort] }
        // Запасная модель, совпадающая с основной, бессмысленна.
        if let fallbackModel, fallbackModel != model { a += ["--fallback-model", fallbackModel] }
        a += [
            "--setting-sources", "",
            "--strict-mcp-config",
            "--tools", "",
            "--no-session-persistence",
            "--system-prompt-file", systemPromptFile.path,
        ]
        if let briefFile { a += ["--append-system-prompt-file", briefFile.path] }
        a += [
            "--input-format", "stream-json",
            "--output-format", "stream-json",
            "--include-partial-messages",
            "--verbose",
        ]
        return a
    }

    /// Окружение процесса мозга — только по белому списку. Переменные провайдера LLM (ключ, конфиг) из окружения
    /// приложения (например, когда его запустили из терминала с другой сессией CLI) переключили бы
    /// процессу ключ, модель или конфиг; остальное ему просто не нужно.
    public static let environmentKeys = ["HOME", "PATH", "USER", "LOGNAME", "LANG", "LC_ALL", "TMPDIR", "SHELL", "TERM"]

    public static func environment(from env: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        env.filter { environmentKeys.contains($0.key) }
    }

    /// Сообщение пользователя в формате stream-json (одна строка).
    public static func userMessage(_ content: String) -> Data {
        let obj: [String: Any] = ["type": "user", "message": ["role": "user", "content": content]]
        var d = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data()
        d.append(0x0A)
        return d
    }

    /// Ищем по PATH и типичным местам: при запуске из LaunchAgent/open PATH урезан
    /// до системных папок, и ~/.local/bin в нём нет.
    public static func findBrainBinary(env: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        let fm = FileManager.default
        if let o = env["SUFLYOR_BRAIN_BIN"], !o.isEmpty {
            return fm.isExecutableFile(atPath: o) ? o : nil
        }
        let home = env["HOME"] ?? NSHomeDirectory()
        var dirs = (env["PATH"] ?? "").split(separator: ":").map(String.init)
        dirs += [home + "/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"]
        for d in dirs {
            let p = (d as NSString).appendingPathComponent(brainBinaryName)
            if fm.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }
}
