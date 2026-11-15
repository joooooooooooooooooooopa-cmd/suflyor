import Foundation

/// Похоже ли на вопрос, который стоит отдать мозгу без нажатия клавиши.
///
/// Правила: «?» в любом месте (whisper ставит его только там, где слышит вопрос, а в длинной
/// реплике вопрос часто в середине: «Сколько это стоит? Нам к пятнице надо»), ИЛИ вопросительное слово в первых трёх словах, ИЛИ просьба
/// («расскажи», «можете», «подскажи») в любом месте. Вопросительное слово ищем только
/// в начале: в середине фразы «что/когда/как» почти всегда союз («я думаю, что всё ок»).
/// Короткие реплики («Что?», «Как дела») отсекаем по длине: на них пользователь ответит и без суфлёра.
public enum QuestionDetector {
    static let minWords = 4
    static let headWords = 3

    static let questionWords: Set<String> = [
        "как", "что", "сколько", "когда", "почему", "зачем", "где", "кто", "куда", "откуда",
        "какой", "какая", "какие", "какое", "каких", "какую",
    ]

    static let requestWords: Set<String> = [
        "расскажи", "расскажите", "объясни", "объясните", "покажи", "покажите",
        "можешь", "можете", "подскажи", "подскажите",
    ]

    /// Пары слов подряд в начале фразы: по одному они слишком частые («есть», «если»).
    static let pairs: [(String, String)] = [("можно", "ли"), ("есть", "ли"), ("а", "если")]

    /// «Я думаю, что…», «мы знаем, когда…»: местоимение в начале и слово не первым — это
    /// придаточное, а не вопрос.
    static let pronouns: Set<String> = ["я", "мы", "ты", "вы", "он", "она", "они"]

    public static func isQuestion(_ text: String) -> Bool {
        let tokens = tokenize(text)
        guard tokens.count >= minWords else { return false }
        if text.contains("?") { return true }
        if tokens.contains(where: requestWords.contains) { return true }
        let startsWithPronoun = pronouns.contains(tokens[0])
        for i in 0..<min(headWords, tokens.count) where questionWords.contains(tokens[i]) {
            if startsWithPronoun && i >= 2 { continue }
            return true
        }
        for i in 0..<min(headWords, tokens.count - 1) where pairs.contains(where: { $0 == (tokens[i], tokens[i + 1]) }) {
            return true
        }
        return false
    }

    /// Слова — по буквам и цифрам: знаки препинания и дефисы whisper ставит как попало.
    static func tokenize(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }
}

/// Вопрос, собранный из одной или нескольких подряд идущих реплик собеседника.
public struct PendingQuestion: Equatable, Sendable {
    public var text: String
    public var seqs: [Int]
    public var channel: Channel
    public var end: Date

    public init(_ u: Utterance) {
        text = u.text
        seqs = [u.seq]
        channel = u.channel
        end = u.end
    }
}

/// Дебаунс автовопросов: whisper режет длинный вопрос на куски по паузам,
/// и без склейки мозг получил бы первую половину фразы.
///
/// Сам таймер держит владелец: `feed` говорит, когда его (пере)запустить, `delay` — на сколько,
/// `fire` — что спросить.
public final class QuestionGate {
    /// Реплика кончается на «?» — фраза, скорее всего, закончена: ждём совсем немного.
    public static let quickDelay: TimeInterval = 0.4
    /// Иначе ждём продолжения: whisper режет длинный вопрос по паузам.
    public static let slowDelay: TimeInterval = 1.2
    /// Дольше копить нельзя: собеседник, который говорит без пауз, иначе не получил бы подсказку вовсе.
    public static let maxAge: TimeInterval = 3
    public static let maxPieces = 3

    public private(set) var pending: PendingQuestion?
    /// Когда начали копить (по часам, не по звуку: ждёт живой человек).
    private var startedAt: Date?

    public init() {}

    /// true — запустить или продлить таймер дебаунса.
    public func feed(_ u: Utterance, now: Date = Date()) -> Bool {
        guard u.channel == .they else { return false }
        if var p = pending {
            p.text += " " + u.text
            p.seqs.append(u.seq)
            p.end = u.end
            pending = p
            return true
        }
        guard QuestionDetector.isQuestion(u.text) else { return false }
        pending = PendingQuestion(u)
        startedAt = now
        return true
    }

    /// Через сколько спросить после реплики `u`, только что поданной в `feed`. `slow` и `quick` —
    /// обычная и короткая пауза (в тестах короче); копившийся вопрос старше `maxAge`
    /// или из `maxPieces` кусков уходит сразу.
    public func delay(after u: Utterance, now: Date = Date(),
                      slow: TimeInterval = QuestionGate.slowDelay, quick: TimeInterval = QuestionGate.quickDelay) -> TimeInterval {
        guard let p = pending else { return slow }
        if p.seqs.count >= Self.maxPieces { return 0 }
        let wanted = u.text.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("?") ? min(quick, slow) : slow
        let left = Self.maxAge - now.timeIntervalSince(startedAt ?? now)
        return max(0, min(wanted, left))
    }

    /// Таймер истёк: отдаём собранный вопрос и забываем его.
    public func fire() -> PendingQuestion? {
        defer {
            pending = nil
            startedAt = nil
        }
        return pending
    }

    public func reset() {
        pending = nil
        startedAt = nil
    }
}

/// Тема созвона: из календаря или определённая мозгом по разговору.
public struct CallTopic: Equatable, Sendable {
    public var topic: String
    public var with: String

    public init(topic: String = "", with: String = "") {
        self.topic = topic.trimmingCharacters(in: .whitespacesAndNewlines)
        self.with = with.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var isEmpty: Bool { topic.isEmpty }

    /// Первая строка каждого вопроса мозгу: без темы мозг гадает, о чём созвон.
    public var header: String? {
        guard !topic.isEmpty || !with.isEmpty else { return nil }
        var parts: [String] = []
        if !topic.isEmpty { parts.append("ТЕМА: \(topic)") }
        if !with.isEmpty { parts.append("С КЕМ: \(with)") }
        return parts.joined(separator: " · ")
    }

    /// Сообщение подготовки шпаргалки (формат разбирает `CheatSheet`).
    public var prepMessage: String {
        """
        ПОДГОТОВКА К СОЗВОНУ. Тема: \(topic). С кем: \(with.isEmpty ? "не указано" : with). Дай шпаргалку строго в формате:
        ГЛАВНОЕ: 5–7 фактов с цифрами из брифа по теме, каждый с новой строки, начиная с «· »
        СПРОСЯТ: 3–5 строк «вопрос → короткий ответ»
        ССЫЛКИ: до 3 ссылок из брифа, каждая с новой строки «название — URL»
        Ничего не выдумывай: только бриф.
        """
    }
}

/// Текст сообщения мозгу: короткий контекст созвона + реплика, на которую нужен ответ.
public enum BrainPrompt {
    public static let maxLines = 12
    public static let window: TimeInterval = 120

    public static func build(log: [Utterance], question: PendingQuestion, topic: CallTopic = CallTopic()) -> String {
        let asked = Set(question.seqs)
        let from = question.end.addingTimeInterval(-window)
        // Части самого вопроса в контекст не кладём: они идут отдельным блоком ниже.
        let context = log.filter { !asked.contains($0.seq) && $0.end >= from }.suffix(maxLines)
        var lines: [String] = []
        if let h = topic.header { lines.append(h) }
        lines.append("КОНТЕКСТ (последние ~2 мин созвона):")
        lines += context.map { "\(label($0.channel)): \($0.text)" }
        lines.append("ВОПРОС/РЕПЛИКА, на которую нужен ответ:")
        lines.append("\(label(question.channel)): \(question.text)")
        return lines.joined(separator: "\n")
    }

    static func label(_ c: Channel) -> String { c == .they ? "ОНИ" : "Я" }
}

/// Голосовая команда пользователя «подскажи»: вместо клавиши «ответь на последнее».
public enum VoiceCommand {
    /// Команда — если триггер в первых или последних `edgeWords` словах реплики. В середине длинной фразы
    /// «подскажите, пожалуйста, клиенту…» — это разговор с человеком, а не обращение к суфлёру.
    static let edgeWords = 3

    public static func isAskTrigger(_ text: String) -> Bool {
        let tokens = QuestionDetector.tokenize(dehyphen(text.lowercased().replacingOccurrences(of: "ё", with: "е")))
        return tokens.indices.contains { i in
            (i < edgeWords || i >= tokens.count - edgeWords) && isTriggerWord(tokens[i])
        }
    }

    /// Насколько свежей должна быть реплика, чтобы «подскажи» ответил на неё: старше — уже другой разговор.
    public static let freshness: TimeInterval = 90
    /// Меньше слов после триггеров — это не вопрос, а просто «суфлёр, подскажи мне».
    static let minQuestionWords = 3
    /// Обращения и междометия по краям команды: «эй, суфлёр, ну какие сроки?» — вопрос без «эй» и «ну».
    static let fillers: Set<String> = ["эй", "ну", "а", "так", "вот", "слушай", "пожалуйста", "ок", "окей", "давай"]

    /// whisper (small, ru) пишет «суфлёр» как попало: «софлер», «сюфлёр», «суплер», «суфер», «sufler».
    /// Поэтому — по началу слова, а для остального — близость к «суфлер».
    static let triggerPrefixes = ["суфл", "софл", "сюфл", "суфер", "суплер", "суфлер", "sufl", "soufl"]
    static let triggerWord = "суфлер"
    static let maxTypos = 2
    static let typoLengths = 5...9
    /// «супер» в двух правках от «суфлер», а пользователь говорит его на созвонах постоянно («супер, договорились»).
    static let notTriggers: Set<String> = ["супер"]

    /// `token` — уже нормализованное слово: нижний регистр, ё→е, без дефисов и знаков.
    static func isTriggerWord(_ token: String) -> Bool {
        if token.hasPrefix("подскаж") || token == "подсказка" { return true }
        if notTriggers.contains(token) { return false }
        if triggerPrefixes.contains(where: token.hasPrefix) { return true }
        return typoLengths.contains(token.count) && levenshtein(token, triggerWord) <= maxTypos
    }

    /// «подскажи-ка», «суф-лёр»: дефис whisper ставит внутри слова, и без склейки слово развалится на два.
    static func dehyphen(_ text: String) -> String {
        text.replacingOccurrences(of: "[-‐‑]", with: "", options: .regularExpression)
    }

    /// Слово из исходного текста → вид, в котором его сравниваем с триггерами.
    static func normalize(_ word: String) -> String {
        String(word.lowercased().replacingOccurrences(of: "ё", with: "е")
            .unicodeScalars.filter(CharacterSet.alphanumerics.contains).map(Character.init))
    }

    static func levenshtein(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        var prev = Array(0...b.count)
        for (i, ca) in a.enumerated() {
            var cur = [i + 1]
            for (j, cb) in b.enumerated() {
                cur.append(min(prev[j + 1] + 1, cur[j] + 1, prev[j] + (ca == cb ? 0 : 1)))
            }
            prev = cur
        }
        return prev[b.count]
    }

    /// Вопрос, заданный прямо в команде («Суфлёр, какие изменения в релизе?»): текст без триггеров
    /// и обращений по краям; nil — осталось меньше трёх слов, т. е. это голая команда.
    /// Слова берём из исходного текста, чтобы мозг видел регистр (CRM, TAG5), а не lowercased-токены.
    /// Триггеры срезаем в любом месте: команда уже распознана, а «суфлёр» мозгу ничего не говорит.
    public static func question(in text: String) -> String? {
        let edge = CharacterSet.alphanumerics.inverted
        var words = text.split(whereSeparator: \.isWhitespace)
            .map { $0.trimmingCharacters(in: edge) }
            .filter { !$0.isEmpty && !isTriggerWord(normalize($0)) }
        while let w = words.first, fillers.contains(normalize(w)) { words.removeFirst() }
        while let w = words.last, fillers.contains(normalize(w)) { words.removeLast() }
        return words.count >= minQuestionWords ? words.joined(separator: " ") : nil
    }

    /// Что спросить по команде `command`: вопрос из самой команды (его сказали только что и именно суфлёру) →
    /// копившийся автовопрос `pending` (он свежее и полнее одной реплики) → свежая реплика собеседника →
    /// свежая своя реплика (пользователь сам говорит вопрос, а следом «подскажи») → nil.
    /// Свежесть считаем от конца команды, а не от часов: в тестах и при задержке расшифровки так честнее.
    public static func pick(command: Utterance, log: [Utterance], pending: PendingQuestion? = nil) -> PendingQuestion? {
        if let text = question(in: command.text) {
            var q = PendingQuestion(command)
            q.text = text
            return q
        }
        if let pending { return pending }
        let from = command.end.addingTimeInterval(-freshness)
        // Только до команды: что сказано после, к этой команде не относится.
        let before = log.filter { $0.seq < command.seq && $0.end >= from }
        if let they = before.last(where: { $0.channel == .they }) { return PendingQuestion(they) }
        if let me = before.last(where: { $0.channel == .me && !isAskTrigger($0.text) }) { return PendingQuestion(me) }
        return nil
    }
}

/// Тема созвона по расшифровке, если календарь её не дал.
public enum TopicDetection {
    /// Сколько разговора нужно, чтобы тема была понятна.
    public static let after: TimeInterval = 60
    public static let maxLines = 40
    public static let maxAttempts = 3

    public static func message(log: [Utterance]) -> String {
        var lines = [
            "Определи тему созвона одной строкой и собеседников по контексту.",
            "Ответ строго в две строки, без подсказки и без других строк:",
            "ТЕМА: <тема одной строкой>",
            "С КЕМ: <имена или роли собеседников; если непонятно — пропусти строку>",
            "Если тему понять нельзя — ответь одним символом: —",
            "РАСШИФРОВКА:",
        ]
        lines += log.suffix(maxLines).map { "\(BrainPrompt.label($0.channel)): \($0.text)" }
        return lines.joined(separator: "\n")
    }

    /// nil — тема не определилась.
    public static func parse(_ text: String) -> CallTopic? {
        var topic = "", with = ""
        for raw in text.components(separatedBy: "\n") {
            let line = raw.replacingOccurrences(of: "**", with: "").trimmingCharacters(in: .whitespaces)
            let upper = line.uppercased()
            if upper.hasPrefix("ТЕМА:") { topic = String(line.dropFirst(5)) }
            if upper.hasPrefix("С КЕМ:") { with = String(line.dropFirst(6)) }
        }
        let t = CallTopic(topic: topic, with: with)
        guard !t.topic.isEmpty, t.topic != "—", t.topic != "-" else { return nil }
        return t
    }
}

/// Эхо на динамиках: микрофон слышит собеседника из колонок, и его слова повторяются в канале «я».
/// Такую «свою» реплику нельзя считать словами пользователя: ни командой «подскажи», ни контекстом для мозга.
/// Без эхоподавления узнаём её по совпадению с репликой «они» в то же время.
public enum Echo {
    /// Насколько могут разъехаться границы одной и той же речи в двух каналах: VAD режет
    /// тихое эхо иначе, чем чистый звук системы.
    static let slack: TimeInterval = 1.5
    /// Доля слов реплики «я», найденных у собеседника, начиная с которой это эхо.
    static let minShare = 0.6
    /// Сравниваем по началу слова: whisper по-разному дописывает окончания у тихого эха.
    static let stemLength = 5

    public static func isEcho(_ u: Utterance, in log: [Utterance]) -> Bool {
        guard u.channel == .me else { return false }
        let mine = stems(u.text)
        guard !mine.isEmpty else { return false }
        return log.contains { o in
            guard o.channel == .they,
                  o.start <= u.end.addingTimeInterval(slack),
                  o.end >= u.start.addingTimeInterval(-slack) else { return false }
            let theirs = Set(stems(o.text))
            let hit = mine.filter(theirs.contains).count
            return Double(hit) / Double(mine.count) >= minShare
        }
    }

    static func stems(_ text: String) -> [String] {
        QuestionDetector.tokenize(VoiceCommand.dehyphen(text.lowercased().replacingOccurrences(of: "ё", with: "е")))
            .map { String($0.prefix(stemLength)) }
    }
}
