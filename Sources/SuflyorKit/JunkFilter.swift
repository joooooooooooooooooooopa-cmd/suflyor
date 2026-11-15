import Foundation

/// Отсев типовых галлюцинаций whisper. На тишине и музыке модель, обученная на субтитрах
/// YouTube, выдаёт титры («Субтитры сделал…», «Продолжение следует…») — в суфлёре это шум.
public enum JunkFilter {
    /// Подстроки, по которым вся реплика считается мусором (сравнение по нормализованному тексту).
    static let junkSubstrings: [String] = [
        "продолжение следует",
        "редактор субтитров",
        "спасибо за просмотр",
        "подписывайтесь на канал",
        "ставьте лайк",
        "dimatorzok",
        "amara.org",
        "thanks for watching",
        "thank you for watching",
        "subtitles by",
    ]

    /// Мусор, если реплика с этого начинается. «Субтитры» внутри фразы («включи субтитры») — живая речь.
    static let junkPrefixes: [String] = [
        "субтитры",
        "корректор",
    ]

    /// Реплики, которые мусор только целиком (как часть фразы — нормальные слова).
    static let junkWhole: Set<String> = [
        "музыка", "music", "тишина", "аплодисменты", "смех", "blank audio", "silence",
        "you",
    ]

    /// Возвращает очищенный текст или nil, если реплику нужно выбросить.
    /// `previous` — последняя принятая реплика того же канала: whisper любит повторять
    /// предыдущую фразу на следующем фрагменте тишины.
    public static func clean(_ raw: String, previous: String? = nil) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Целиком в скобках/звёздочках — это пометки звука: [музыка], (смех), *аплодисменты*.
        text = stripSoundTags(text)
        text = collapseRepeats(text)
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)

        let norm = normalize(text)
        if norm.isEmpty { return nil }
        if junkWhole.contains(norm) { return nil }
        for s in junkSubstrings where norm.contains(s) { return nil }
        for p in junkPrefixes where norm.hasPrefix(p) { return nil }
        if let prev = previous, normalize(prev) == norm { return nil }
        return text
    }

    /// Нижний регистр, без пунктуации и лишних пробелов — для сравнения, не для показа.
    public static func normalize(_ s: String) -> String {
        let lowered = s.lowercased().replacingOccurrences(of: "ё", with: "е")
        let scalars = lowered.unicodeScalars.map { c -> Character in
            if CharacterSet.letters.contains(c) || CharacterSet.decimalDigits.contains(c) || c == "." {
                return Character(c)
            }
            return " "
        }
        let joined = String(scalars)
        // Точка нужна только внутри доменов вроде amara.org, по краям слов — убираем.
        let words = joined.split(separator: " ").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".")) }
        return words.filter { !$0.isEmpty }.joined(separator: " ")
    }

    static func stripSoundTags(_ s: String) -> String {
        let pattern = #"\[[^\]]*\]|\([^)]*\)|\*[^*]*\*|♪+"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return s }
        let range = NSRange(s.startIndex..., in: s)
        return re.stringByReplacingMatches(in: s, range: range, withTemplate: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }

    /// Зацикливание внутри одного ответа: «Спасибо. Спасибо. Спасибо.» → «Спасибо.»
    static func collapseRepeats(_ s: String) -> String {
        let sentences = splitSentences(s)
        guard sentences.count > 1 else { return s }
        var out: [String] = []
        var lastNorm = ""
        var dropped = false
        for sent in sentences {
            let n = normalize(sent)
            if n.isEmpty { continue }
            if n == lastNorm { dropped = true; continue }
            out.append(sent)
            lastNorm = n
        }
        // Без повторов отдаём исходник как есть, чтобы не потерять многоточия и пробелы.
        return dropped ? out.joined(separator: " ") : s
    }

    static func splitSentences(_ s: String) -> [String] {
        var result: [String] = []
        var cur = ""
        for ch in s {
            cur.append(ch)
            if ".!?…".contains(ch) {
                let t = cur.trimmingCharacters(in: .whitespaces)
                if !t.isEmpty { result.append(t) }
                cur = ""
            }
        }
        let t = cur.trimmingCharacters(in: .whitespaces)
        if !t.isEmpty { result.append(t) }
        // «Многоточие» и «?!» не должны дробить на пустые куски.
        return result.filter { !normalize($0).isEmpty || $0.count > 1 }
    }
}
