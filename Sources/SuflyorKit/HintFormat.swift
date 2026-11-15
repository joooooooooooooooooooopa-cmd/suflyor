import Foundation

/// Разбор ответа мозга на части для панели (формат задан в prompts/system.md).
public struct HintParts: Equatable {
    public var say = ""
    public var facts = ""
    public var ifPushed = ""
    /// Строка ССЫЛКА как есть и первый URL из неё (его и копируем).
    public var link = ""
    public var url: String?
    /// Ответ «—»: реплика не к пользователю, подсказывать нечего.
    public var silent = false

    public var isEmpty: Bool { say.isEmpty && facts.isEmpty && ifPushed.isEmpty && link.isEmpty }

    public static func parse(_ text: String) -> HintParts {
        var p = HintParts()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "—" || trimmed == "-" || trimmed == "–" {
            p.silent = true
            return p
        }
        // Пока поток не дошёл до первой метки (или модель её не поставила), текст идёт в «скажи».
        var current = \HintParts.say
        for raw in text.components(separatedBy: "\n") {
            // Звёздочки — на случай, если модель выделит метку жирным в markdown.
            var line = raw.replacingOccurrences(of: "**", with: "").trimmingCharacters(in: .whitespaces)
            for (marker, path) in markers where line.uppercased().hasPrefix(marker) {
                current = path
                line = String(line.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
                break
            }
            guard !line.isEmpty else { continue }
            p[keyPath: current] += (p[keyPath: current].isEmpty ? "" : "\n") + line
        }
        p.url = firstURL(in: p.link)
        p.dropUnfinishedMarker(of: text)
        return p
    }

    /// Адреса не из брифа в «скажи», фактах и «если дожмут» — пометкой; строку «ссылка»
    /// не трогаем: её адрес панель сама проверяет и показывает пометку вместо него.
    public func sanitized(by whitelist: LinkWhitelist) -> HintParts {
        var p = self
        p.say = whitelist.sanitize(say)
        p.facts = whitelist.sanitize(facts)
        p.ifPushed = whitelist.sanitize(ifPushed)
        return p
    }

    /// Первый http(s)-адрес до пробела. Кириллица и параметры внутри адреса допустимы
    /// (ссылки на внутренние дашборды и вики бывают такими); хвостовую пунктуацию предложения отрезаем.
    static func firstURL(in text: String) -> String? {
        guard let r = text.range(of: #"https?://[^\s<>«»"]+"#, options: .regularExpression) else { return nil }
        var u = String(text[r])
        while let last = u.last, ".,;:!?)]»".contains(last) {
            // Закрывающую скобку оставляем, если в адресе есть открывающая: …/wiki/Foo_(bar).
            if last == ")" && u.contains("(") { break }
            u.removeLast()
        }
        return u
    }

    /// Пока метка приходит по токенам («ФАК», «ФАКТЫ»), её куски падали бы в текущий блок крупным
    /// шрифтом и через миг исчезали — подсказка дёргалась. Недописанную последнюю строку,
    /// похожую на начало метки, не показываем: следующий токен всё равно решит, что это.
    private mutating func dropUnfinishedMarker(of text: String) {
        guard !text.hasSuffix("\n"), let lastRaw = text.components(separatedBy: "\n").last else { return }
        let last = lastRaw.replacingOccurrences(of: "**", with: "").trimmingCharacters(in: .whitespaces)
        let upper = last.uppercased()
        // Хотя бы 2 буквы: одиночная «С»/«Е» — чаще начало обычной фразы, прятать её незачем.
        guard upper.count >= 2,
              Self.markers.contains(where: { $0.0.hasPrefix(upper) && $0.0 != upper }) else { return }
        for (_, path) in Self.markers where self[keyPath: path].hasSuffix(last) {
            var v = self[keyPath: path]
            v.removeLast(last.count)
            if v.hasSuffix("\n") { v.removeLast() }
            self[keyPath: path] = v
            break
        }
    }

    static let markers: [(String, WritableKeyPath<HintParts, String>)] = [
        ("СКАЖИ:", \.say), ("ФАКТЫ:", \.facts), ("ЕСЛИ ДОЖМУТ:", \.ifPushed), ("ССЫЛКА:", \.link),
    ]
}

/// Как разложить подсказку на строки для чтения глазами за пару секунд. Чистые функции:
/// панель только рисует то, что здесь нарезано.
public enum HintLayout {
    /// «Скажи» по фразам: каждая с новой строки, так глаз видит, где вдохнуть.
    /// Режем только по «. ! ? …», за которыми пробел и заглавная буква, цифра или кавычка:
    /// «3.5», «т. е.» и адреса не рвутся. Недописанная фраза потока остаётся последней строкой,
    /// уже показанные строки при этом не меняются.
    public static func sentences(_ text: String) -> [String] {
        var out: [String] = []
        for para in text.components(separatedBy: "\n") {
            var rest = Substring(para)
            while let r = rest.range(of: #"[.!?…]+[»")]?\s+(?=[\p{Lu}\p{N}«"—–-])"#, options: .regularExpression) {
                let head = rest[..<r.upperBound].trimmingCharacters(in: .whitespaces)
                if !head.isEmpty { out.append(head) }
                rest = rest[r.upperBound...]
            }
            let tail = rest.trimmingCharacters(in: .whitespaces)
            if !tail.isEmpty { out.append(tail) }
        }
        return out
    }

    /// Факты списком: модель пишет их через « · », иногда строками или с маркерами.
    public static func facts(_ text: String) -> [String] {
        text.components(separatedBy: "\n")
            .flatMap { $0.components(separatedBy: "·") }
            .map { CheatSheet.stripBullet($0.trimmingCharacters(in: .whitespaces)) }
            .filter { !$0.isEmpty }
    }

    /// Кусок строки: обычный текст или число, которое выделяем цветом.
    public struct Segment: Equatable {
        public var text: String
        public var isNumber: Bool
        public init(_ text: String, number: Bool) { self.text = text; self.isNumber = number }
    }

    /// Числа с процентами, валютой и разрядами («1 500», «3,5%», «$4») — за них цепляется глаз.
    /// Цифры внутри слов и кодов (TICKET-1, mp3, адреса) не выделяем: это не цифры для ответа.
    static let numberPattern =
        #"(?<![\p{L}\p{N}_/.\-])[$€₽]?\d{1,3}(?:[ \u00A0\u202F]\d{3})+(?:[.,]\d+)?\s?%?(?![\p{L}\p{N}])|(?<![\p{L}\p{N}_/.\-])[$€₽]?\d+(?:[.,]\d+)?\s?%?(?![\p{L}\p{N}])"#

    public static func numberSegments(_ text: String) -> [Segment] {
        guard let re = try? NSRegularExpression(pattern: numberPattern) else { return [Segment(text, number: false)] }
        let ns = text as NSString
        var out: [Segment] = []
        var pos = 0
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            var r = m.range
            // Пробел перед «%» входит в число, а хвостовой пробел без «%» — нет.
            while r.length > 0, ns.substring(with: NSRange(location: r.location + r.length - 1, length: 1)) == " " {
                r.length -= 1
            }
            guard r.length > 0 else { continue }
            if r.location > pos { out.append(Segment(ns.substring(with: NSRange(location: pos, length: r.location - pos)), number: false)) }
            out.append(Segment(ns.substring(with: r), number: true))
            pos = r.location + r.length
        }
        if pos < ns.length { out.append(Segment(ns.substring(from: pos), number: false)) }
        return out
    }
}

/// Шпаргалка к созвону (формат задан в `CallTopic.prepMessage`).
public struct CheatSheet: Equatable {
    public struct QA: Equatable {
        public var question: String
        public var answer: String
    }

    public struct Link: Equatable {
        public var title: String
        public var url: String
    }

    public var main: [String] = []
    public var asks: [QA] = []
    public var links: [Link] = []
    /// Ответ без единой метки: показываем как есть, чтобы не потерять текст.
    public var raw = ""

    public var isEmpty: Bool { main.isEmpty && asks.isEmpty && links.isEmpty && raw.isEmpty }

    /// Строка для свёрнутой шпаргалки.
    public var summary: String {
        if let first = main.first { return first }
        if let q = asks.first { return q.question }
        return raw.components(separatedBy: "\n").first ?? ""
    }

    /// Адреса не из брифа в «главном», «спросят» и тексте без меток — пометкой;
    /// раздел ссылок панель проверяет сама построчно.
    public func sanitized(by whitelist: LinkWhitelist) -> CheatSheet {
        var s = self
        s.main = main.map(whitelist.sanitize)
        s.asks = asks.map { QA(question: whitelist.sanitize($0.question), answer: whitelist.sanitize($0.answer)) }
        s.raw = whitelist.sanitize(raw)
        return s
    }

    public static func parse(_ text: String) -> CheatSheet {
        enum Section { case none, main, asks, links }
        var s = CheatSheet()
        var section = Section.none
        var sawMarker = false
        for rawLine in text.components(separatedBy: "\n") {
            var line = rawLine.replacingOccurrences(of: "**", with: "").trimmingCharacters(in: .whitespaces)
            let upper = line.uppercased()
            for (marker, sec) in [("ГЛАВНОЕ:", Section.main), ("СПРОСЯТ:", .asks), ("ССЫЛКИ:", .links)]
            where upper.hasPrefix(marker) {
                section = sec
                sawMarker = true
                line = String(line.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
                break
            }
            line = stripBullet(line)
            guard !line.isEmpty else { continue }
            switch section {
            case .none:
                s.raw += (s.raw.isEmpty ? "" : "\n") + line
            case .main:
                s.main.append(line)
            case .asks:
                if let r = line.range(of: "→") ?? line.range(of: "->") {
                    s.asks.append(QA(question: line[..<r.lowerBound].trimmingCharacters(in: .whitespaces),
                                     answer: line[r.upperBound...].trimmingCharacters(in: .whitespaces)))
                } else {
                    s.asks.append(QA(question: line, answer: ""))
                }
            case .links:
                // Строка без адреса — не ссылка: копировать нечего, выдумывать адрес не будем.
                guard let url = HintParts.firstURL(in: line), let r = line.range(of: url) else { continue }
                // Название — то, что до адреса, без разделителя «—» и скобок вокруг адреса;
                // кавычки «…» в названии оставляем.
                let seps = CharacterSet(charactersIn: "—–-:(<").union(.whitespaces)
                var title = String(line[..<r.lowerBound]).trimmingCharacters(in: seps)
                if title.isEmpty { title = url }
                s.links.append(Link(title: title, url: url))
            }
        }
        // Текст до первой метки при наличии меток — обычно вступление вроде «Вот шпаргалка», он не нужен.
        if sawMarker { s.raw = "" }
        return s
    }

    static func stripBullet(_ line: String) -> String {
        var l = line
        for b in ["· ", "•", "- ", "– ", "* "] where l.hasPrefix(b) {
            l = String(l.dropFirst(b.count))
            break
        }
        return l.trimmingCharacters(in: .whitespaces)
    }
}
