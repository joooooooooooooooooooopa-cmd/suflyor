import AppKit
import ApplicationServices

/// Распознавание «⌃⌥⌘ без буквы»: зажать вместе Control, Option, Command и отпустить.
///
/// Срабатывает, только если были зажаты ровно эти три модификатора (без Shift и Fn),
/// между ними не нажималась обычная клавиша или кнопка мыши и от момента «все три зажаты» до полного
/// отпускания прошло не больше секунды. Так ⌃⌥⌘+буква в других программах суфлёр не трогает.
public struct ChordDetector {
    public struct Mods: OptionSet, Hashable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let control = Mods(rawValue: 1)
        public static let option = Mods(rawValue: 2)
        public static let command = Mods(rawValue: 4)
        public static let shift = Mods(rawValue: 8)
        public static let function = Mods(rawValue: 16)

        public static let chord: Mods = [.control, .option, .command]
    }

    public static let maxHold: TimeInterval = 1.0

    private var armedAt: Date?
    /// Аккорд испорчен (лишний модификатор или буква) — ждём полного отпускания.
    private var spoiled = false
    private var held: Mods = []

    public init() {}

    /// Изменились модификаторы. true — сработать.
    public mutating func flags(_ m: Mods, at t: Date) -> Bool {
        held = m
        if m.isEmpty {
            defer { armedAt = nil; spoiled = false }
            guard let a = armedAt, !spoiled else { return false }
            return t.timeIntervalSince(a) <= Self.maxHold
        }
        if !m.isSubset(of: .chord) {
            spoiled = true
        } else if m == .chord, armedAt == nil, !spoiled {
            armedAt = t
        }
        return false
    }

    /// Нажата обычная клавиша: если модификаторы зажаты — это чьё-то сочетание, не наше.
    /// Обычный набор текста без модификаторов ничего не портит.
    public mutating func keyDown() {
        if !held.isEmpty { spoiled = true }
    }

    /// Клик или перетаскивание мышью: ⌃⌥⌘+клик/драг — жест другой программы (перенос окна,
    /// выделение), отпускание после него не должно включать или гасить суфлёр.
    public mutating func pointer() {
        if !held.isEmpty { spoiled = true }
    }

    /// Флаги NSEvent → наши (Caps Lock и цифровой блок не в счёт).
    static func mods(_ f: NSEvent.ModifierFlags) -> Mods {
        var m: Mods = []
        if f.contains(.control) { m.insert(.control) }
        if f.contains(.option) { m.insert(.option) }
        if f.contains(.command) { m.insert(.command) }
        if f.contains(.shift) { m.insert(.shift) }
        if f.contains(.function) { m.insert(.function) }
        return m
    }
}

/// Слушает модификаторы во всей системе. Для чужих окон macOS требует «Универсальный доступ».
final class ChordMonitor {
    private var detector = ChordDetector()
    private var global: Any?
    private var local: Any?
    private let onChord: () -> Void

    init(onChord: @escaping () -> Void) {
        self.onChord = onChord
    }

    static var trusted: Bool { AXIsProcessTrusted() }

    /// Системный запрос «разрешить Suflyor управлять компьютером» — один раз, дальше помнит macOS.
    static func askTrust() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    func install() {
        guard global == nil else { return }
        let mask: NSEvent.EventTypeMask = [.flagsChanged, .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown,
                                           .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        global = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] e in self?.handle(e) }
        // В своём окне глобальный монитор событий не видит — ловим локальным.
        local = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] e in
            self?.handle(e)
            return e
        }
    }

    /// Снять и поставить заново (после выдачи «Универсального доступа»). Состояние аккорда — с нуля.
    func reinstall() {
        if let g = global { NSEvent.removeMonitor(g) }
        if let l = local { NSEvent.removeMonitor(l) }
        global = nil
        local = nil
        detector = ChordDetector()
        install()
    }

    private func handle(_ e: NSEvent) {
        switch e.type {
        case .keyDown:
            detector.keyDown()
        case .leftMouseDown, .rightMouseDown, .otherMouseDown, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            detector.pointer()
        case .flagsChanged:
            if detector.flags(ChordDetector.mods(e.modifierFlags), at: Date()) {
                DispatchQueue.main.async { self.onChord() }
            }
        default:
            break
        }
    }
}

/// Разрешения macOS: спрашиваем сами, пользователь только жмёт «Разрешить».
enum Permissions {
    static func openScreenCapturePane() {
        if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(u)
        }
    }

    /// Разрешение на запись экрана/звука система применяет только после перезапуска процесса.
    static func relaunch() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-n", Bundle.main.bundlePath]
        try? p.run()
    }
}
