import AppKit
import ScreenCaptureKit

/// `Suflyor --selftest-capture`: проверяет, что панель не попадает в захват экрана.
///
/// Панель заливается маркерным цветом (маджента), снимаем экран тремя способами и считаем
/// пиксели маркера. Сначала контроль с `sharingType = .readOnly` — панель обязана быть видна,
/// иначе проверка ничего не доказывает (не тот экран, не отрисовалась, нет прав).
/// Снимки держим в памяти; файл от `screencapture` — во временной папке, удаляется сразу.
public enum SelfTest {
    /// Меньше — шум от обоев/иконок, панель 420×560 даёт сотни тысяч пикселей.
    static let visibleThreshold = 2_000

    public static func run() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let model = PanelModel()
        model.markerMode = true
        let panel = SuflyorPanel(model: model)
        panel.alphaValue = 1  // полупрозрачность размыла бы цвет маркера
        // Именно экран с меню (= CGMainDisplayID), а не NSScreen.main: при внешнем мониторе
        // main — тот, где фокус, и панель оказалась бы не на снимаемом дисплее.
        if let f = NSScreen.screens.first?.frame {
            panel.setFrameOrigin(NSPoint(x: f.midX - 210, y: f.midY - 280))
        }
        panel.orderFrontRegardless()

        Task { @MainActor in
            let code = await check(panel: panel)
            panel.orderOut(nil)
            exit(code)
        }
        app.run()
    }

    struct Shot {
        let name: String
        let pixels: Int?   // nil — способ недоступен
        let note: String
    }

    @MainActor
    static func check(panel: NSPanel) async -> Int32 {
        try? await Task.sleep(nanoseconds: 800_000_000)
        guard CGPreflightScreenCaptureAccess() else {
            print("""
            SELFTEST: нет разрешения «Запись экрана и системного звука» для процесса, который запустил тест.
            Дать: Системные настройки → Конфиденциальность и безопасность → Запись экрана и системного звука →
            включить терминал (или Suflyor.app, если запуск из бандла), затем перезапустить терминал.
            """)
            return 2
        }

        panel.sharingType = .readOnly
        try? await Task.sleep(nanoseconds: 500_000_000)
        let control = await shots(panel: panel)

        panel.sharingType = .none
        try? await Task.sleep(nanoseconds: 500_000_000)
        let real = await shots(panel: panel)

        print("SELFTEST захвата экрана (пикселей маркера; порог «видна» > \(visibleThreshold))")
        var ok = true
        var verified = 0
        for (c, r) in zip(control, real) {
            guard let cp = c.pixels, let rp = r.pixels else {
                print("  \(r.name): недоступен (\(r.note.isEmpty ? c.note : r.note))")
                continue
            }
            let controlSeen = cp > visibleThreshold
            let hidden = rp <= visibleThreshold
            let verdict: String
            if !controlSeen {
                verdict = "НЕ ПРОВЕРЕНО — в контроле (.readOnly) панель тоже не видна"
            } else {
                verified += 1
                verdict = hidden ? "панель скрыта" : "панель ВИДНА"
                if !hidden { ok = false }
            }
            print("  \(r.name): \(verdict)  [контроль \(cp), sharingType=.none \(rp)]\(r.note.isEmpty ? "" : " — \(r.note)")")
        }
        // Ни одного подтверждённого способа — не «OK»: проверка ничего не доказала.
        if !ok {
            print("ИТОГ: ПАНЕЛЬ ПОПАДАЕТ В ЗАХВАТ")
            return 1
        }
        if verified == 0 {
            print("ИТОГ: НЕ ПРОВЕРЕНО")
            return 3
        }
        print("ИТОГ: OK (подтверждено способов: \(verified))")
        return 0
    }

    @MainActor
    static func shots(panel: NSPanel) async -> [Shot] {
        let windowID = CGWindowID(panel.windowNumber)
        var out: [Shot] = []
        out.append(await sckShot(windowID: windowID))
        out.append(cgShot())
        out.append(screencaptureShot())
        return out
    }

    static func sckShot(windowID: CGWindowID) async -> Shot {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? content.displays.first else {
                return Shot(name: "SCK", pixels: nil, note: "нет дисплея")
            }
            let listed = content.windows.contains { $0.windowID == windowID }
            // Фильтр как у типичной демонстрации экрана в Zoom/Meet: весь дисплей, без исключений.
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let cfg = SCStreamConfiguration()
            let scale = CGFloat(filter.pointPixelScale)
            cfg.width = Int(CGFloat(display.width) * scale)
            cfg.height = Int(CGFloat(display.height) * scale)
            cfg.showsCursor = false
            let img = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
            return Shot(name: "SCK", pixels: countMarker(img),
                        note: listed ? "окно есть в SCShareableContent" : "окна нет в SCShareableContent")
        } catch {
            return Shot(name: "SCK", pixels: nil, note: error.localizedDescription)
        }
    }

    /// CGWindowListCreateImage в SDK macOS 15+ закрыт для Swift, берём его через dlsym:
    /// для проверки важно увидеть и старый путь захвата, которым ещё пользуются некоторые приложения.
    static func cgShot() -> Shot {
        typealias Fn = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else {
            return Shot(name: "CG", pixels: nil, note: "функция недоступна")
        }
        let fn = unsafeBitCast(sym, to: Fn.self)
        // optionOnScreenOnly = 1, kCGNullWindowID = 0, imageDefault = 0
        guard let img = fn(CGDisplayBounds(CGMainDisplayID()), 1, 0, 0)?.takeRetainedValue() else {
            return Shot(name: "CG", pixels: nil, note: "снимок не получен")
        }
        return Shot(name: "CG", pixels: countMarker(img), note: "")
    }

    static func screencaptureShot() -> Shot {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("suflyor-selftest-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: dir) }
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let file = dir.appendingPathComponent("shot.png")
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            // -x без звука, -m только главный дисплей
            p.arguments = ["-x", "-m", "-t", "png", file.path]
            try p.run()
            p.waitUntilExit()
            guard let src = CGImageSourceCreateWithURL(file as CFURL, nil),
                  let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
                return Shot(name: "screencapture", pixels: nil, note: "снимок не получен")
            }
            return Shot(name: "screencapture", pixels: countMarker(img), note: "")
        } catch {
            return Shot(name: "screencapture", pixels: nil, note: error.localizedDescription)
        }
    }

    /// Перерисовываем в sRGB RGBA8 и считаем «почти маджента» с допуском на цветовой профиль дисплея.
    static func countMarker(_ img: CGImage) -> Int {
        let w = img.width, h = img.height
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        let ok: Bool = buf.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return 0 }
        var n = 0
        var i = 0
        while i < buf.count {
            if buf[i] > 200 && buf[i + 1] < 60 && buf[i + 2] > 200 { n += 1 }
            i += 4
        }
        return n
    }
}
