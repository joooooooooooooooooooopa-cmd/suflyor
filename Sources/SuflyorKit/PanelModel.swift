import Foundation

/// Где сейчас сессия.
public enum SessionPhase: Equatable {
    /// Вне созвона: панель скрыта, ничего не слушаем.
    case sleeping
    /// Сессия: по ⌃⌥⌘ сразу слушаем, тема и шпаргалка догоняют в фоне.
    case listening
}

/// Состояние мозга глазами панели.
public enum BrainState: Equatable {
    case none
    case warming
    case ready
    case timedOut
    case limit(String)
    case error(String)
}

/// Цветная точка в статус-строке.
public enum Indicator: Equatable {
    case sleep, preparing, listening, thinking, ready, limit, error
}

/// Готовность шпаргалки.
public enum CheatState: Equatable {
    case none, preparing, ready, failed
}

/// Состояние панели. Все изменения — только на main (SwiftUI так требует).
public final class PanelModel: ObservableObject {
    @Published public internal(set) var they: [Utterance] = []
    @Published public internal(set) var me: [Utterance] = []
    @Published public internal(set) var hint: String = PanelModel.placeholderHint
    @Published public internal(set) var errors: [String] = []
    /// Состояние расшифровки («Загрузка whisper…», «Без расшифровки»); пусто — всё работает.
    @Published public internal(set) var status: String = ""
    @Published public internal(set) var phase: SessionPhase = .sleeping
    @Published public internal(set) var brainState: BrainState = .none
    @Published public internal(set) var modeTitle = SessionMode.product.title
    /// На какую реплику отвечает подсказка и за сколько секунд пришёл ответ (nil — ещё идёт).
    @Published public internal(set) var hintQuestion: String?
    @Published public internal(set) var hintSeconds: Double?
    /// Номер ответа: по нему подсказка плавно сменяется, а не мигает.
    @Published public internal(set) var answerID = 0
    /// Короткая надпись на 1.5 с: «скопировано», «в подсказке нет ссылки».
    @Published public internal(set) var flash: String?
    /// Крупная надпись по центру («Готов, начинаем»).
    @Published public internal(set) var banner: String?

    /// Тема из календаря или из разговора; пусто — пока не знаем.
    @Published public internal(set) var topic = CallTopic()
    /// Что надо разрешить в настройках macOS — одна строка («Включи Suflyor в открывшемся окне…»).
    @Published public internal(set) var notice: String?
    /// Нет доступа к звуку системы: работаем на одном микрофоне.
    @Published public internal(set) var systemAudioOff = false

    // Шпаргалка.
    @Published public internal(set) var cheatText = ""
    @Published public internal(set) var cheatState: CheatState = .none
    /// Шпаргалка готовится, пока уже идёт разговор, поэтому всегда свёрнута в строку:
    /// развернуть — только кликом, место на панели — у подсказки.
    @Published public internal(set) var cheatExpanded = false

    // Вид.
    @Published public internal(set) var compact = false
    @Published public var theyExpanded = true
    @Published public var meExpanded = true
    /// Панель стоит на экране, который может уйти в демонстрацию (нет встроенного дисплея).
    @Published public internal(set) var screenWarning = false

    // Настройки (сохраняет приложение).
    @Published public var opacity: Double = PanelSettings.defaults.opacity
    @Published public var hintFontSize: Double = PanelSettings.defaults.hintFontSize
    @Published public var calendarEnabled = false

    /// Ссылки из брифа текущего режима: всё остальное не показываем и не копируем.
    public internal(set) var whitelist = LinkWhitelist.empty

    /// В selftest панель заливается маркером, по которому ищем её на снимке экрана.
    @Published var markerMode = false

    /// Пустая подсказка рисуется как «…слушаю».
    static let placeholderHint = ""
    static let questionLimit = 80
    static let theyShown = 3
    static let meShown = 2
    static let flashTime: TimeInterval = 1.5
    static let bannerTime: TimeInterval = 3
    static let fontRange: ClosedRange<Double> = 14...32

    /// Новый ответ, ещё не дошедший до первого осмысленного куска: старая подсказка
    /// стоит на экране, пока его не будет что читать. nil — такого ответа нет.
    @Published public internal(set) var pendingQuestion: String?
    private var pendingText = ""
    private var flashToken = 0
    private var bannerToken = 0

    public init() {}

    func add(_ u: Utterance) {
        // Держим немного больше, чем показываем: место на панели — у подсказки.
        switch u.channel {
        case .they:
            they.append(u)
            if they.count > Self.theyShown { they.removeFirst(they.count - Self.theyShown) }
        case .me:
            me.append(u)
            if me.count > Self.meShown { me.removeFirst(me.count - Self.meShown) }
        }
    }

    /// Заменить подсказку целиком.
    public func setHint(_ text: String) {
        hint = text
    }

    /// Дописать кусок к подсказке — для потоковой выдачи по токенам. Пока новый ответ
    /// не набрал осмысленного текста, он копится в стороне, а на экране остаётся прошлая подсказка.
    public func appendHint(_ chunk: String) {
        guard let q = pendingQuestion else {
            hint += chunk
            return
        }
        pendingText += chunk
        if Self.isMeaningful(pendingText) { show(pendingText, question: q) }
    }

    /// Начало нового ответа. Подсказку не стираем: пользователь может как раз её дочитывать,
    /// а пустая зона на секунды до первого слова ничем не лучше прошлого ответа.
    func beginAnswer(question: String) {
        pendingQuestion = question
        pendingText = ""
    }

    /// Ответ закончен. Если он так и не стал осмысленным («-»: подсказывать нечего) — прошлая
    /// подсказка остаётся со своей подписью; если весь текст пришёл только в конце — показываем его.
    func finishAnswer(question: String, text: String, seconds: Double) {
        if pendingQuestion != nil {
            guard Self.isMeaningful(text) else {
                clearPending()
                return
            }
            show(text, question: question)
        }
        setHintMeta(question: question, seconds: seconds)
    }

    /// Ответа не будет: недописанный новый ответ забываем, прошлая подсказка остаётся.
    /// Уже идущий на экране ответ не держим в «…думаю» вечно.
    func answerFailed() {
        if pendingQuestion != nil {
            clearPending()
        } else if waitingAnswer {
            setHintMeta(question: nil, seconds: nil)
        }
    }

    private func show(_ text: String, question: String) {
        clearPending()
        hint = text
        setHintMeta(question: question, seconds: nil)
        answerID += 1
    }

    private func clearPending() {
        pendingQuestion = nil
        pendingText = ""
    }

    /// Есть что читать: хотя бы две буквы в блоках подсказки (одиночная «С» — обычно начало метки «СКАЖИ:»),
    /// и это не «-» (реплика не к пользователю).
    static func isMeaningful(_ text: String) -> Bool {
        let p = HintParts.parse(text)
        guard !p.silent else { return false }
        return (p.say + p.facts + p.ifPushed + p.link).filter(\.isLetter).count >= 2
    }

    /// Подпись над подсказкой: на какую реплику ответ и за сколько секунд.
    public func setHintMeta(question: String?, seconds: Double?) {
        hintQuestion = question.map(Self.shorten)
        hintSeconds = seconds
    }

    /// Ссылка для показа: из брифа (возможно, восстановленная) или nil — тогда вместо неё пометка.
    func displayURL(_ raw: String) -> String? { whitelist.allowed(raw) }

    func setWhitelist(_ w: LinkWhitelist) { whitelist = w }

    /// Клик по ссылке (подсказка или шпаргалка).
    func copy(_ url: String, to clipboard: Clipboard) {
        clipboard.copy(url)
        showFlash("скопировано")
    }

    func showFlash(_ text: String) {
        flash = text
        flashToken += 1
        let token = flashToken
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.flashTime) { [weak self] in
            // Новая надпись продлевает показ, а не гасится старым таймером.
            if self?.flashToken == token { self?.flash = nil }
        }
    }

    /// Убрать надпись, только если на виду всё ещё она: более свежую не трогаем.
    func clearFlash(_ text: String) {
        guard flash == text else { return }
        flash = nil
        flashToken += 1
    }

    func showBanner(_ text: String) {
        banner = text
        bannerToken += 1
        let token = bannerToken
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.bannerTime) { [weak self] in
            if self?.bannerToken == token { self?.banner = nil }
        }
    }

    func setPhase(_ p: SessionPhase) { phase = p }
    func setBrainState(_ s: BrainState) { brainState = s }
    func setTopic(_ t: CallTopic) { topic = t }
    func setNotice(_ s: String?) { notice = s }
    func setSystemAudioOff(_ off: Bool) { systemAudioOff = off }
    func setScreenWarning(_ w: Bool) { screenWarning = w }
    func setCompact(_ c: Bool) { compact = c }

    func setCheat(_ text: String, state: CheatState) {
        cheatText = text
        cheatState = state
    }

    func appendCheat(_ chunk: String) { cheatText += chunk }

    func toggleCheat() { cheatExpanded.toggle() }

    func changeFont(by delta: Double) {
        hintFontSize = min(max(hintFontSize + delta, Self.fontRange.lowerBound), Self.fontRange.upperBound)
    }

    /// Новая сессия или конец старой: всё, что было на экране, забываем вместе с транскриптом.
    func reset() {
        they = []
        me = []
        hint = Self.placeholderHint
        clearPending()
        hintQuestion = nil
        hintSeconds = nil
        errors = []
        flash = nil
        banner = nil
        status = ""
        brainState = .none
        topic = CallTopic()
        notice = nil
        systemAudioOff = false
        cheatText = ""
        cheatState = .none
        cheatExpanded = false
        compact = false
    }

    /// Ждём ответа на вопрос: новый ещё не показан или показан, но не дописан (подпись есть, времени нет).
    var waitingAnswer: Bool { pendingQuestion != nil || (hintQuestion != nil && hintSeconds == nil) }

    public var indicator: Indicator {
        if phase == .sleeping { return .sleep }
        switch brainState {
        case .limit: return .limit
        case .error, .timedOut: return .error
        default: break
        }
        if brainState == .warming { return .preparing }
        if waitingAnswer { return .thinking }
        if hintSeconds != nil { return .ready }
        return .listening
    }

    /// Текст рядом с точкой: что происходит сейчас, самое важное — первым.
    public var statusText: String {
        var parts: [String] = []
        switch phase {
        case .sleeping: parts.append("Сплю · ⌃⌥⌘ — включить")
        case .listening:
            parts.append(status.isEmpty ? "Слушаю · \(modeTitle)" : status)
            if systemAudioOff { parts.append(Self.noSystemAudio) }
            if cheatState == .failed { parts.append("шпаргалка не готова") }
        }
        switch brainState {
        case .warming: parts.append("прогрев…")
        case .timedOut: parts.append("мозг не ответил")
        case .limit(let m): parts.append("лимит: \(m)")
        case .error(let m): parts.append("мозг недоступен: \(m)")
        default:
            // Пока думаем над новым, время прошлого ответа только путает.
            if phase == .listening && waitingAnswer {
                parts.append("думаю…")
            } else if phase == .listening, let s = hintSeconds {
                parts.append(String(format: "ответ %.1f с", s))
            }
        }
        if screenWarning { parts.append("⚠ на показываемом экране") }
        return parts.joined(separator: " · ")
    }

    static let noSystemAudio = "собеседника не слышу — нет доступа к звуку системы"

    static func shorten(_ s: String) -> String {
        let one = s.replacingOccurrences(of: "\n", with: " ")
        return one.count > questionLimit ? String(one.prefix(questionLimit - 1)) + "…" : one
    }

    func addError(_ text: String) {
        if !errors.contains(text) { errors.append(text) }
    }
}

/// Настройки вида, которые переживают перезапуск.
public struct PanelSettings: Equatable {
    public var opacity: Double
    public var hintFontSize: Double
    public var calendarEnabled: Bool

    /// Тема из календаря включена по умолчанию: без окна темы это главный её источник.
    public static let defaults = PanelSettings(opacity: 0.95, hintFontSize: 22, calendarEnabled: true)

    /// Прозрачность подложки: ниже 0.6 подсказку на пёстром окне созвона уже не прочесть.
    /// Сохранённое раньше 0.5 при загрузке поднимается до 0.6.
    public static let minOpacity = 0.6
    static let opacityChoices: [Double] = [0.6, 0.7, 0.8, 0.9, 0.95, 1.0]

    /// Ключ календаря новый: под старым («suflyor.calendarEnabled») лежит false, записанный
    /// вместе с прозрачностью, когда календарь был выключен по умолчанию, — он не выбор пользователя.
    static let keys = (opacity: "suflyor.opacity", font: "suflyor.hintFontSize", calendar: "suflyor.calendarTopic")

    public static func load(_ d: UserDefaults) -> PanelSettings {
        var s = defaults
        if d.object(forKey: keys.opacity) != nil { s.opacity = min(max(d.double(forKey: keys.opacity), minOpacity), 1) }
        if d.object(forKey: keys.font) != nil {
            s.hintFontSize = min(max(d.double(forKey: keys.font), PanelModel.fontRange.lowerBound), PanelModel.fontRange.upperBound)
        }
        if d.object(forKey: keys.calendar) != nil { s.calendarEnabled = d.bool(forKey: keys.calendar) }
        return s
    }

    public func save(_ d: UserDefaults) {
        d.set(opacity, forKey: Self.keys.opacity)
        d.set(hintFontSize, forKey: Self.keys.font)
        d.set(calendarEnabled, forKey: Self.keys.calendar)
    }
}
