import AppKit
import SwiftUI

/// Что панель просит у приложения. Все колбэки — на main.
struct PanelActions {
    var endSession: () -> Void = {}
    var quit: () -> Void = {}
    var toggleCompact: () -> Void = {}
    var toggleCalendar: () -> Void = {}
}

struct PanelView: View {
    @ObservedObject var model: PanelModel
    var actions = PanelActions()
    var clipboard: Clipboard = SystemClipboard()

    var body: some View {
        if model.markerMode {
            // Чистый маркерный цвет без текста: так его легко посчитать по пикселям.
            Color(red: 1, green: 0, blue: 1)
        } else if model.compact {
            compactView
        } else {
            content
        }
    }

    // MARK: - Полоска

    /// Компактный режим: только «скажи», крупно, на 1–2 строки. Клик — развернуть.
    private var compactView: some View {
        let parts = HintParts.parse(model.hint).sanitized(by: model.whitelist)
        let text = parts.silent || parts.say.isEmpty ? (model.waitingAnswer ? "…думаю" : "…слушаю") : parts.say
        return HStack(spacing: 8) {
            dot
            Text(text).font(.system(size: model.hintFontSize + 2, weight: .medium))
                .foregroundStyle(parts.say.isEmpty ? Color.secondary : Color.white)
                .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                .id(model.answerID).transition(.opacity)
        }
        .animation(.easeOut(duration: 0.25), value: model.answerID)
        .padding(.horizontal, 14).padding(.vertical, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.black.opacity(model.opacity)))
        .contentShape(Rectangle())
        .onTapGesture { actions.toggleCompact() }
        .help("Клик — развернуть")
        .environment(\.colorScheme, .dark)
    }

    // MARK: - Полный вид

    private var content: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            // Что разрешить и последняя ошибка — по одной строке: панель для подсказок, а не для логов.
            if let n = model.notice {
                Text(n).font(.system(size: 12, weight: .medium)).foregroundStyle(.yellow)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            if let e = model.errors.last {
                Text(e).font(.system(size: 12)).foregroundStyle(.orange).lineLimit(1).truncationMode(.tail).help(e)
            }
            if model.cheatState != .none {
                cheatSheet
            }
            if model.phase == .listening {
                section("Они говорят", model.they, color: .cyan, expanded: $model.theyExpanded)
                section("Ты говоришь", model.me, color: .green, expanded: $model.meExpanded)
                hintZone
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // Прозрачность из меню — только у подложки: текст поверх неё всегда непрозрачный.
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.black.opacity(model.opacity)))
        .overlay {
            if let b = model.banner {
                Text(b).font(.system(size: 28, weight: .bold)).foregroundStyle(.white)
                    .padding(.horizontal, 22).padding(.vertical, 14)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.green.opacity(0.85)))
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: model.banner)
        .environment(\.colorScheme, .dark)
    }

    private var dot: some View {
        Circle().fill(Self.color(model.indicator)).frame(width: 9, height: 9)
    }

    static func color(_ i: Indicator) -> Color {
        switch i {
        case .sleep: return .gray
        case .preparing: return .blue
        case .listening: return .green
        case .thinking: return .yellow
        case .ready: return .mint
        case .limit: return .purple
        case .error: return .red
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            dot
            Text(model.statusText).font(.system(size: 11)).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.tail).help(model.statusText)
            Spacer(minLength: 4)
            if let f = model.flash {
                Text(f).font(.system(size: 11)).foregroundStyle(.green)
            }
            menu
            Button(action: actions.endSession) { Image(systemName: "power") }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("Выключить (⌃⌥⌘)")
        }
    }

    private var menu: some View {
        Menu {
            Picker("Прозрачность", selection: $model.opacity) {
                ForEach(PanelSettings.opacityChoices, id: \.self) { v in
                    Text("\(Int(v * 100))%").tag(v)
                }
            }
            Button("Шрифт подсказки A+") { model.changeFont(by: 2) }
            Button("Шрифт подсказки A−") { model.changeFont(by: -2) }
            Toggle("Тема из календаря", isOn: Binding(
                get: { model.calendarEnabled }, set: { _ in actions.toggleCalendar() }))
            Button("Компактный режим") { actions.toggleCompact() }
            Divider()
            Button("Выйти совсем", action: actions.quit)
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .foregroundStyle(.secondary)
    }

    // MARK: - Шпаргалка

    private var cheatSheet: some View {
        let sheet = CheatSheet.parse(model.cheatText).sanitized(by: model.whitelist)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: model.cheatExpanded ? "chevron.down" : "chevron.right").font(.system(size: 10))
                Text(model.topic.isEmpty ? "Шпаргалка" : "Шпаргалка · \(model.topic.topic)")
                    .font(.system(size: 12, weight: .bold)).lineLimit(1)
                switch model.cheatState {
                case .preparing: Text("готовлю…").font(.system(size: 11)).foregroundStyle(.secondary)
                case .failed: Text("не готова").font(.system(size: 11)).foregroundStyle(.orange)
                default: EmptyView()
                }
                if !model.cheatExpanded {
                    Text(sheet.summary).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
            }
            .foregroundStyle(.orange)
            .contentShape(Rectangle())
            .onTapGesture { model.toggleCheat() }
            if model.cheatExpanded {
                ScrollView {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(sheet.main.enumerated()), id: \.offset) { _, f in
                            Text("· \(f)").font(.system(size: 13)).foregroundStyle(.white)
                        }
                        ForEach(Array(sheet.asks.enumerated()), id: \.offset) { _, qa in
                            (Text(qa.question).foregroundStyle(.gray)
                             + Text(qa.answer.isEmpty ? "" : " → \(qa.answer)").foregroundStyle(.white))
                                .font(.system(size: 13))
                        }
                        ForEach(Array(sheet.links.enumerated()), id: \.offset) { _, l in
                            linkRow(title: l.title, raw: l.url, hint: nil)
                        }
                        if !sheet.raw.isEmpty {
                            Text(sheet.raw).font(.system(size: 13)).foregroundStyle(.white)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                }
                .frame(maxHeight: 220)
            }
        }
    }

    // MARK: - Подсказка

    private var hintZone: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Подсказка").font(.system(size: 12, weight: .bold)).foregroundStyle(.yellow)
            if let q = model.hintQuestion {
                HStack(spacing: 6) {
                    Text("→ \(q)").lineLimit(1)
                    Spacer(minLength: 4)
                    if let s = model.hintSeconds { Text(String(format: "%.1f с", s)) }
                }
                .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            ScrollView {
                hintBody.frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                    .id(model.answerID).transition(.opacity)
            }
            .animation(.easeOut(duration: 0.25), value: model.answerID)
            // Минимальная высота: потоковый текст растёт внутри зоны, а не двигает панель.
            .frame(minHeight: 150, maxHeight: .infinity)
        }
        .layoutPriority(1)
    }

    /// «Скажи» — крупно, его читают вслух; факты и запасной ответ — мельче и приглушённо,
    /// чтобы глаз не цеплялся за них первым. Цифры выделены: за них глаз цепляется сам.
    /// Блоки — по одному Text на строку с устойчивыми номерами: пока подсказка идёт потоком,
    /// меняется только последняя строка, остальные не перерисовываются и не прыгают.
    /// Адреса во всех блоках — только из брифа: выдуманную ссылку из «скажи» или фактов
    /// перепечатали бы руками так же, как из строки «ссылка».
    @ViewBuilder private var hintBody: some View {
        let parts = HintParts.parse(model.hint).sanitized(by: model.whitelist)
        if parts.silent || parts.isEmpty {
            Text(model.waitingAnswer ? "…думаю" : "…слушаю").font(.system(size: 15)).foregroundStyle(Self.muted)
        } else {
            VStack(alignment: .leading, spacing: 12) {
                if !parts.say.isEmpty {
                    let size = model.hintFontSize
                    // Между фразами чуть больше воздуха, чем между строками одной фразы:
                    // так видно, где одна мысль кончилась.
                    VStack(alignment: .leading, spacing: size * 0.3) {
                        ForEach(Array(HintLayout.sentences(parts.say).enumerated()), id: \.offset) { _, line in
                            Self.highlighted(line, size: size, color: .white)
                                .lineSpacing(Self.extraLineSpacing(size: size))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                if !parts.facts.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(HintLayout.facts(parts.facts).enumerated()), id: \.offset) { _, fact in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text("•").font(.system(size: 15)).foregroundStyle(Self.muted)
                                Self.highlighted(fact, size: 15, color: Self.muted)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                if !parts.ifPushed.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("если дожмут").font(.system(size: 11, weight: .semibold)).foregroundStyle(Self.label)
                        Text(parts.ifPushed).font(.system(size: 14)).foregroundStyle(Self.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if let url = parts.url {
                    linkRow(title: nil, raw: url, hint: "клик — скопировать")
                }
            }
        }
    }

    /// Приглушённые, но непрозрачные цвета: на подложке с прозрачностью 0.6 полупрозрачный
    /// серый сливался бы с тем, что под панелью.
    static let muted = Color(white: 0.78)
    static let label = Color(white: 0.6)
    /// Цифры — тёплым жёлтым: контрастно на чёрном и не путается с голубой ссылкой.
    static let accent = Color(red: 1, green: 0.82, blue: 0.3)

    /// Межстрочный интервал 1.25 от кегля: SwiftUI задаёт только добавку к естественной высоте строки шрифта.
    static func extraLineSpacing(size: Double) -> Double {
        let natural = NSLayoutManager().defaultLineHeight(for: .systemFont(ofSize: size))
        return max(0, size * 1.25 - natural)
    }

    /// Строка с выделенными цифрами (semibold + акцент), остальное — обычным начертанием.
    static func highlighted(_ text: String, size: Double, color: Color) -> Text {
        var out = AttributedString()
        for seg in HintLayout.numberSegments(text) {
            var a = AttributedString(seg.text)
            a.font = .system(size: size, weight: seg.isNumber ? .semibold : .regular)
            a.foregroundColor = seg.isNumber ? accent : color
            out += a
        }
        return Text(out)
    }

    /// Клик только копирует: открывать браузер посреди созвона не нужно.
    /// Ссылку не из брифа не показываем вовсе — только пометку, чтобы её не перепечатали руками.
    @ViewBuilder
    private func linkRow(title: String?, raw: String, hint: String?) -> some View {
        if let url = model.displayURL(raw) {
            allowedLinkRow(title: title, url: url, hint: hint)
        } else {
            HStack(spacing: 6) {
                if let title { Text(title).font(.system(size: 13)).foregroundStyle(.gray).lineLimit(1) }
                Text(LinkWhitelist.rejectedNote).font(.system(size: 12)).foregroundStyle(.orange)
            }
        }
    }

    private func allowedLinkRow(title: String?, url: String, hint: String?) -> some View {
        HStack(spacing: 6) {
            if let title, title != url {
                Text(title).font(.system(size: 13)).foregroundStyle(.white).lineLimit(1)
            }
            Text(url).font(.system(size: 13)).foregroundStyle(.cyan).underline().lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            if let hint { Text(hint).font(.system(size: 11)).foregroundStyle(.secondary) }
        }
        .contentShape(Rectangle())
        .onTapGesture { model.copy(url, to: clipboard) }
        .help("Клик — скопировать ссылку")
    }

    // MARK: - Они / Ты

    private func section(_ title: String, _ items: [Utterance], color: Color, expanded: Binding<Bool>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: expanded.wrappedValue ? "chevron.down" : "chevron.right").font(.system(size: 10))
                Text(title).font(.system(size: 12, weight: .bold))
            }
            .foregroundStyle(color)
            .contentShape(Rectangle())
            .onTapGesture { expanded.wrappedValue.toggle() }
            if expanded.wrappedValue {
                ForEach(items, id: \.seq) { u in
                    // Мельче подсказки и не больше 2 строк: главное на панели — подсказка.
                    Text(u.text).font(.system(size: 13)).foregroundStyle(Self.muted).lineLimit(2)
                        .truncationMode(.head)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}

/// Плавающая панель. Не активирует приложение по клику, чтобы фокус оставался в Zoom/Meet.
final class SuflyorPanel: NSPanel {
    init(model: PanelModel, actions: PanelActions = PanelActions()) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 560),
            styleMask: [.titled, .nonactivatingPanel, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        for b in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            standardWindowButton(b)?.isHidden = true
        }
        isFloatingPanel = true
        level = .floating
        // Видна на всех рабочих столах и поверх полноэкранного Zoom.
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        isMovableByWindowBackground = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        // Окно целиком непрозрачно: прозрачность из меню задаёт только подложка в PanelView,
        // иначе вместе с фоном бледнел бы и текст подсказки.
        alphaValue = 1
        // Главное: окно исключается из захвата экрана (демонстрация в Zoom/Meet, скриншоты).
        sharingType = .none
        contentView = NSHostingView(rootView: PanelView(model: model, actions: actions))
        minSize = NSSize(width: 300, height: 60)
    }

    override var canBecomeKey: Bool { true }
}
