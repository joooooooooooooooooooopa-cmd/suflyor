import AppKit

/// Буфер обмена за абстракцией: в тестах подменяется фейком, чтобы не трогать буфер пользователя.
public protocol Clipboard: AnyObject {
    func copy(_ text: String)
}

public final class SystemClipboard: Clipboard {
    public init() {}

    public func copy(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }
}
