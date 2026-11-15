import Foundation

/// Белый список ссылок: только адреса, которые есть в брифе.
///
/// Мозг иногда обрезает ссылку или собирает её «по памяти». Скопированная в чат созвона
/// выдуманная ссылка хуже, чем никакой, поэтому показываем и копируем только то, что
/// дословно есть в брифе; обрезанную восстанавливаем, если вариант ровно один.
public struct LinkWhitelist: Equatable {
    public enum Resolution: Equatable {
        /// Ссылка из брифа (в том виде, как она записана в брифе).
        case allowed(String)
        /// Не из брифа или неоднозначна — не показываем и не копируем.
        case rejected
    }

    public static let rejectedNote = "ссылка не из брифа — не копирую"
    /// Замена чужого адреса внутри текста подсказки или шпаргалки.
    public static let inlineNote = "ссылка не из брифа"
    /// Короче этого путь после хоста не достраиваем: «https://acme.example.com/» — это корень,
    /// а не обрывок, и превращать его в глубокую ссылку из брифа нельзя.
    static let minRestorePath = 10

    /// Адреса как в брифе.
    public let urls: [String]
    /// Нормализованный вид → адрес из брифа.
    private let byKey: [String: String]

    public init(urls: [String]) {
        var seen = Set<String>(), list: [String] = [], map: [String: String] = [:]
        for u in urls where seen.insert(Self.key(u)).inserted {
            list.append(u)
            map[Self.key(u)] = u
        }
        self.urls = list
        byKey = map
    }

    /// Все https-адреса из текста брифа.
    public init(briefText: String) {
        self.init(urls: Self.extract(briefText))
    }

    public static let empty = LinkWhitelist(urls: [])

    public func resolve(_ url: String) -> Resolution {
        // Многоточие на конце — модель сама показала, что адрес оборван.
        var raw = url
        var cut = false
        for e in ["…", "..."] where raw.hasSuffix(e) {
            raw.removeLast(e.count)
            cut = true
        }
        let k = Self.key(Self.trimTail(raw))
        guard k.count > "https://".count else { return .rejected }
        if let exact = byKey[k] { return .allowed(exact) }
        // Обрезанная ссылка: подставляем, только если продолжение однозначно и это правда обрывок,
        // а не другой (короткий) адрес того же хоста.
        guard cut || Self.pathAfterHost(k).count >= Self.minRestorePath else { return .rejected }
        let candidates = byKey.filter { $0.key.hasPrefix(k) }.map(\.value)
        return candidates.count == 1 ? .allowed(candidates[0]) : .rejected
    }

    /// Все http(s)-адреса в тексте: из брифа — как в брифе, остальные — пометкой `inlineNote`.
    public func sanitize(_ text: String) -> String {
        guard text.contains("://"),
              let re = try? NSRegularExpression(pattern: #"https?://[^\s<>«»"]+"#) else { return text }
        let ns = text as NSString
        var out = ""
        var pos = 0
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: pos, length: m.range.location - pos))
            let found = ns.substring(with: m.range)
            // Точку или скобку после адреса оставляем тексту, к адресу они не относятся.
            let url = found.hasSuffix("…") || found.hasSuffix("...") ? found : Self.trimTail(found)
            let tail = String(found.dropFirst(url.count))
            out += (allowed(url) ?? Self.inlineNote) + tail
            pos = m.range.location + m.range.length
        }
        out += ns.substring(from: pos)
        return out
    }

    /// Адрес из брифа или nil.
    public func allowed(_ url: String?) -> String? {
        guard let url, case .allowed(let u) = resolve(url) else { return nil }
        return u
    }

    static func extract(_ text: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: #"https://[^\s<>"'`|]+"#) else { return [] }
        let ns = text as NSString
        return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { m in
            let u = trimTail(ns.substring(with: m.range))
            return u.count > "https://".count ? u : nil
        }
    }

    /// Хвост, который приклеивается к адресу в тексте: точка в конце предложения,
    /// скобка markdown-ссылки, звёздочки жирного.
    static func trimTail(_ s: String) -> String {
        var u = s
        while let last = u.last, ".,;:!?)]}*»>\"'".contains(last) {
            // Скобка внутри адреса (…/Foo_(bar)) — часть адреса, если открывающая тоже есть.
            if last == ")" && u.filter({ $0 == "(" }).count >= u.filter({ $0 == ")" }).count { break }
            u.removeLast()
        }
        return u
    }

    /// Часть ключа после хоста (с ведущим «/», «?» или «#»).
    static func pathAfterHost(_ key: String) -> Substring {
        guard let r = key.range(of: "://") else { return "" }
        let rest = key[r.upperBound...]
        let hostEnd = rest.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) ?? rest.endIndex
        return rest[hostEnd...]
    }

    /// Сравниваем без процент-кодирования и без регистра хоста: «…/Изменения» и
    /// «…/%D0%98%D0%B7…» — одна и та же ссылка.
    static func key(_ s: String) -> String {
        let decoded = s.removingPercentEncoding ?? s
        guard let r = decoded.range(of: "://") else { return decoded }
        let rest = decoded[r.upperBound...]
        let hostEnd = rest.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) ?? rest.endIndex
        return decoded[..<r.upperBound].lowercased() + rest[..<hostEnd].lowercased() + rest[hostEnd...]
    }
}
