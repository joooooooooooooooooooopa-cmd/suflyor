import AppKit
import CoreGraphics

/// Где поставить панель. Логика отдельно от AppKit, чтобы её можно было проверить тестом.
///
/// Правило: встроенный дисплей ноутбука — его в Zoom/Meet обычно не показывают. Если его нет
/// (крышка закрыта), ставим на главный и предупреждаем: невидимость в захвате (sharingType .none)
/// остаётся, но глазами коллег в комнате экран виден.
public enum PanelPlacement {
    public struct Screen: Equatable {
        public var id: String
        public var isBuiltin: Bool
        public var isMain: Bool
        public var visibleFrame: CGRect

        public init(id: String, isBuiltin: Bool, isMain: Bool, visibleFrame: CGRect) {
            self.id = id
            self.isBuiltin = isBuiltin
            self.isMain = isMain
            self.visibleFrame = visibleFrame
        }
    }

    public struct Saved: Equatable {
        public var screenID: String
        public var frame: CGRect

        public init(screenID: String, frame: CGRect) {
            self.screenID = screenID
            self.frame = frame
        }
    }

    public struct Result: Equatable {
        public var frame: CGRect
        public var screenID: String?
        /// Встроенного дисплея нет — панель на экране, который могут показывать.
        public var warning: Bool
    }

    public static let defaultSize = CGSize(width: 420, height: 560)
    public static let margin: CGFloat = 20

    public static func place(screens: [Screen], saved: Saved?, size: CGSize = defaultSize) -> Result {
        let builtin = screens.first { $0.isBuiltin }
        let warning = builtin == nil
        // Сохранённое место — только если тот дисплей подключён и окно на нём хоть как-то видно.
        if let s = saved, let scr = screens.first(where: { $0.id == s.screenID }),
           scr.visibleFrame.intersects(s.frame) {
            return Result(frame: clamp(s.frame, into: scr.visibleFrame), screenID: scr.id, warning: warning)
        }
        guard let target = builtin ?? screens.first(where: { $0.isMain }) ?? screens.first else {
            return Result(frame: CGRect(origin: .zero, size: size), screenID: nil, warning: true)
        }
        let v = target.visibleFrame
        // Правый верхний угол с отступом (координаты AppKit: y растёт вверх).
        let frame = CGRect(x: v.maxX - size.width - margin, y: v.maxY - size.height - margin,
                           width: size.width, height: size.height)
        return Result(frame: clamp(frame, into: v), screenID: target.id, warning: warning)
    }

    /// Окно целиком внутри экрана: после смены разрешения оно могло уехать за край.
    static func clamp(_ f: CGRect, into v: CGRect) -> CGRect {
        var r = f
        r.size.width = min(r.width, v.width)
        r.size.height = min(r.height, v.height)
        r.origin.x = min(max(r.minX, v.minX), v.maxX - r.width)
        r.origin.y = min(max(r.minY, v.minY), v.maxY - r.height)
        return r
    }

    // MARK: - Сохранение

    static let savedKey = "suflyor.panelPlacement"

    public static func load(_ d: UserDefaults) -> Saved? {
        guard let dict = d.dictionary(forKey: savedKey), let id = dict["screen"] as? String,
              let x = dict["x"] as? Double, let y = dict["y"] as? Double,
              let w = dict["w"] as? Double, let h = dict["h"] as? Double else { return nil }
        return Saved(screenID: id, frame: CGRect(x: x, y: y, width: w, height: h))
    }

    public static func save(_ s: Saved, _ d: UserDefaults) {
        d.set(["screen": s.screenID, "x": Double(s.frame.minX), "y": Double(s.frame.minY),
               "w": Double(s.frame.width), "h": Double(s.frame.height)], forKey: savedKey)
    }

    // MARK: - Экраны AppKit

    /// UUID дисплея, а не его номер: номер меняется после переподключения, UUID — нет.
    static func screenID(_ s: NSScreen) -> String? {
        guard let n = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let uuid = CGDisplayCreateUUIDFromDisplayID(CGDirectDisplayID(n.uint32Value))?.takeRetainedValue(),
              let str = CFUUIDCreateString(nil, uuid) else { return nil }
        return str as String
    }

    static func currentScreens() -> [Screen] {
        NSScreen.screens.enumerated().compactMap { i, s in
            guard let id = screenID(s),
                  let n = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            // Первый в списке — экран со строкой меню (главный в настройках дисплеев).
            return Screen(id: id, isBuiltin: CGDisplayIsBuiltin(CGDirectDisplayID(n.uint32Value)) != 0,
                          isMain: i == 0, visibleFrame: s.visibleFrame)
        }
    }

    static func screenID(containing frame: CGRect) -> String? {
        let best = NSScreen.screens.max { a, b in
            a.frame.intersection(frame).area < b.frame.intersection(frame).area
        }
        return best.flatMap(screenID)
    }
}

private extension CGRect {
    var area: CGFloat { isNull ? 0 : width * height }
}
