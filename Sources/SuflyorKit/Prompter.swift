import Foundation

/// Режим сессии: какой бриф подкладывать мозгу и что писать в статусе.
public struct SessionMode: Equatable, Sendable {
    public let id: String
    public let title: String

    public static let product = SessionMode(id: "product", title: "Продукт")
}

/// Где лежат prompts/ и briefs/. По порядку: `SUFLYOR_HOME` (явный выбор — e2e и smoke на рабочей копии),
/// Contents/Resources бандла (сборка кладёт их туда, и приложение не зависит от папки проекта),
/// вверх от бинаря (.build/…/Suflyor), запасной ~/Library/Application Support/Suflyor (там же модель whisper).
public enum ProjectPaths {
    public static func root(env: [String: String] = ProcessInfo.processInfo.environment,
                            resources: URL? = Bundle.main.resourceURL,
                            executable: URL? = Bundle.main.executableURL) -> URL {
        let fm = FileManager.default
        func hasPrompts(_ d: URL) -> Bool { fm.fileExists(atPath: d.appendingPathComponent("prompts/system.md").path) }
        if let home = env["SUFLYOR_HOME"], !home.isEmpty {
            return URL(fileURLWithPath: home)
        }
        if let r = resources, hasPrompts(r) { return r }
        var dir = executable?.resolvingSymlinksInPath().deletingLastPathComponent()
        while let d = dir, d.path != "/" {
            if hasPrompts(d) { return d }
            dir = d.deletingLastPathComponent()
        }
        return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support/Suflyor")
    }

    public static var systemPrompt: URL { systemPrompt(in: root()) }

    public static func brief(_ mode: SessionMode) -> URL { brief(mode, in: root()) }

    static func systemPrompt(in root: URL) -> URL { root.appendingPathComponent("prompts/system.md") }

    static func brief(_ mode: SessionMode, in root: URL) -> URL {
        root.appendingPathComponent("briefs/\(mode.id).md")
    }
}

/// Что происходило с вопросом — для сквозной проверки (`--e2e-call`) и логов.
enum PrompterEvent {
    case asked(label: String)
    case firstWord(label: String, seconds: TimeInterval)
    case answered(label: String, text: String, seconds: TimeInterval)
    case failed(label: String, why: String)
}

/// Связка «реплики → мозг → подсказка» на одну сессию. Живёт на `queue` (в приложении — main).
final class Prompter {
    static let debounceDelay: TimeInterval = QuestionGate.slowDelay
    /// Сколько ждать, прежде чем решить, команда «подскажи» это или эхо собеседника: звук системы
    /// расшифровывается своим потоком и реплика «они» может прийти позже эха в микрофоне.
    static let echoWait: TimeInterval = 1.2
    /// Надпись сразу на команду «подскажи», до решения, не эхо ли это.
    static let hearingFlash = "слышу…"

    /// Очередь, на которой живут prompter, модель и колбэки мозга. В приложении main;
    /// в `--e2e-call` и тестах — своя, чтобы не зависеть от главного цикла.
    let queue: DispatchQueue
    /// Обычная пауза дебаунса; после «?» — короткая (`QuestionGate.quickDelay`, но не дольше этой).
    var debounceDelay = Prompter.debounceDelay
    var echoWait = Prompter.echoWait
    /// Подмена запуска мозга (фейковый бинарь в тестах); nil — как в приложении.
    var brainConfig: Brain.Config?
    /// Где искать prompts/ и briefs/ (тесты); nil — `ProjectPaths.root()`.
    var projectRoot: URL?
    var onEvent: ((PrompterEvent) -> Void)?
    /// Отладочный журнал в файл. По умолчанию выключен: включённый журнал отдаёт только приложение,
    /// иначе тесты и `--e2e-call` при включённом флаге писали бы в настоящий ~/Library/Logs.
    var debugLog: DebugLog = .off
    private var askedAt: [String: Date] = [:]
    private var firstSeen: Set<String> = []

    let mode: SessionMode
    /// Тема созвона: первой строкой в каждый вопрос.
    var topic = CallTopic()
    /// Шпаргалка готова (true) или не получилась (false). Зовётся один раз на подготовку.
    var onPrepDone: ((Bool) -> Void)?
    /// Тему, если её не дали, определить по разговору (в приложении — да, в `--e2e-call` — без `--topic`).
    var autoTopic = false
    /// Тема определилась по разговору (до подготовки шпаргалки по ней).
    var onTopic: ((CallTopic) -> Void)?
    /// Мозг впервые за сессию прогрелся — «Готов, начинаем».
    var onReady: (() -> Void)?
    /// Пользователь сказал «суфлёр, подскажи»: приходит последняя реплика собеседника.
    var onVoiceAsk: ((Utterance?) -> Void)?
    private var greeted = false
    private var topicAttempts = 0
    private var topicInFlight = false

    private let store: TranscriptStore
    private let model: PanelModel
    private var brain: Brain?
    private let gate = QuestionGate()
    private var debounce: DispatchWorkItem?
    /// Голосовая команда ждёт проверки на эхо: пока ждёт, автовопрос не отправляем,
    /// иначе он и команда спросили бы мозг об одном и том же дважды.
    private var commandCheck: DispatchWorkItem?
    private var subscription: UUID?
    /// Вопросы задаём только в режиме «слушаю»; в окне темы и при подготовке — нет.
    var listening = false

    init(mode: SessionMode, store: TranscriptStore, model: PanelModel, queue: DispatchQueue = .main) {
        self.mode = mode
        self.store = store
        self.model = model
        self.queue = queue
    }

    var started: Bool { brain != nil }

    func start() {
        guard brain == nil else { return }
        let fm = FileManager.default
        let root = projectRoot ?? ProjectPaths.root()
        let system = ProjectPaths.systemPrompt(in: root)
        guard fm.fileExists(atPath: system.path) else {
            model.setBrainState(.error("нет \(system.path)"))
            return
        }
        var brief: URL? = ProjectPaths.brief(mode, in: root)
        var briefText = ""
        if let b = brief, !fm.fileExists(atPath: b.path) {
            // Без брифа мозг всё равно полезен: подскажет формулировки, но без цифр.
            model.addError("Нет брифа briefs/\(mode.id).md — подсказки без фактов режима.")
            brief = nil
        } else if let b = brief {
            do {
                briefText = try String(contentsOf: b, encoding: .utf8)
            } catch {
                // Нечитаемый бриф мозгу не отдаём: процесс упал бы на нём при старте.
                model.addError("Бриф briefs/\(mode.id).md не читается: \(error.localizedDescription)")
                brief = nil
            }
        }
        // Белый список — из того же брифа, что видит мозг: ссылки не оттуда не показываем.
        model.setWhitelist(LinkWhitelist(briefText: briefText))
        var cfg = Brain.Config(systemPromptFile: system, briefFile: brief)
        if let o = brainConfig {
            cfg = o
            // Подменённый запуск (тесты) видит тот же бриф, что и белый список.
            if projectRoot != nil { cfg.briefFile = brief }
        }
        let b = Brain(config: cfg, callbackQueue: queue)
        b.onStatus = { [weak self] s in self?.show(s) }
        b.onLog = { [weak self] line in self?.debugLog.log(line) }
        b.onAnswerStart = { [weak self] r in
            guard let self else { return }
            switch r.kind {
            case .prep: self.model.setCheat("", state: .preparing)
            case .topic: return
            default: self.model.beginAnswer(question: r.label)
            }
            self.askedAt[r.label] = Date()
            self.firstSeen.remove(r.label)
        }
        b.onDelta = { [weak self] r, s in
            guard let self else { return }
            switch r.kind {
            case .prep: self.model.appendCheat(s)
            // Ответ про тему — служебный, на экран не идёт.
            case .topic: return
            default: self.model.appendHint(s)
            }
            if r.kind == .answer, !self.firstSeen.contains(r.label), let t = self.askedAt[r.label] {
                self.firstSeen.insert(r.label)
                let secs = Date().timeIntervalSince(t)
                self.debugLog.log(String(format: "первое слово за %.1f с", secs))
                self.onEvent?(.firstWord(label: r.label, seconds: secs))
            }
        }
        b.onAnswerEnd = { [weak self] r, text, secs in
            guard let self else { return }
            if r.kind == .topic {
                self.topicInFlight = false
                self.topicDetected(text)
            } else if r.kind == .prep {
                self.debugLog.log("шпаргалка готова")
                self.model.setCheat(text, state: .ready)
                self.onPrepDone?(true)
            } else {
                self.debugLog.log(String(format: "подсказка за %.1f с: ", secs) + text)
                self.model.finishAnswer(question: r.label, text: text, seconds: secs)
                self.onEvent?(.answered(label: r.label, text: text, seconds: secs))
            }
        }
        b.onAnswerFailed = { [weak self] r, why in
            guard let self else { return }
            self.debugLog.log("ошибка мозга (\(r.kind)): \(why)")
            if r.kind == .answer { self.onEvent?(.failed(label: r.label, why: why)) }
            if r.kind == .topic {
                self.topicInFlight = false
            } else if r.kind == .prep {
                self.debugLog.log("шпаргалка не получилась")
                self.model.setCheat(self.model.cheatText, state: .failed)
                self.onPrepDone?(false)
            } else {
                // Ответа не будет — не держим «…думаю» вечно; прошлая подсказка остаётся.
                self.model.answerFailed()
            }
        }
        brain = b
        subscription = store.subscribe { [weak self] u in
            guard let self else { return }
            self.queue.async { [weak self] in self?.utterance(u) }
        }
        b.start()
    }

    /// Шпаргалка к созвону; ответ идёт в зону «Шпаргалка», не в подсказку.
    func prepare(_ t: CallTopic) {
        guard let brain else { onPrepDone?(false); return }
        model.setCheat("", state: .preparing)
        brain.prepare(t.prepMessage)
    }

    /// Тема известна (календарь или разговор): дальше она идёт в каждый вопрос,
    /// шпаргалка по ней готовится в фоне и подсказкам не мешает.
    func useTopic(_ t: CallTopic) {
        guard !t.isEmpty else { return }
        debugLog.log("тема: \(t.topic) · с кем: \(t.with)")
        topic = t
        model.setTopic(t)
        prepare(t)
    }

    func stop(wait: Bool = false) {
        if let s = subscription { store.unsubscribe(s) }
        subscription = nil
        debounce?.cancel()
        debounce = nil
        commandCheck?.cancel()
        commandCheck = nil
        gate.reset()
        brain?.stop(wait: wait)
        brain = nil
        listening = false
    }

    /// «Суфлёр, подскажи»: спросить сразу, без эвристики; что именно — решает `VoiceCommand.pick`.
    /// Сама команда в контекст не идёт, но вопрос из неё (если был) уходит мозгу как вопрос.
    func manual(command: Utterance) {
        guard brain != nil else { return }
        debounce?.cancel()
        debounce = nil
        // Автовопрос забираем и тогда, когда победил вопрос из команды: таймер уже снят,
        // а висящий pending склеился бы со следующей репликой собеседника.
        guard let q = VoiceCommand.pick(command: command, log: conversation, pending: gate.fire()) else {
            debugLog.log("голосом «подскажи»: не слышу вопроса")
            model.showFlash("не слышу вопроса")
            return
        }
        debugLog.log("голосом «подскажи», выбран вопрос: \(q.text)")
        // Ответ мозга идёт секунды: без отметки непонятно, услышал ли суфлёр команду.
        model.showFlash("подсказываю…")
        ask(q)
    }

    /// Текст реплик в системный лог (unified log) не пишем никогда: его читает любой процесс
    /// пользователя. Разговор попадает только в отладочный журнал, и то по явному включению.
    private func utterance(_ u: Utterance) {
        debugLog.log("\(u.channel == .me ? "я" : "они"): \(u.text)")
        guard brain != nil, listening else { return }
        if u.channel == .me && VoiceCommand.isAskTrigger(u.text) {
            voiceCommand(u)
            return
        }
        maybeDetectTopic()
        guard gate.feed(u) else { return }
        // Пока решаем, команда ли «подскажи», вопрос копится: команда заберёт его сама.
        guard commandCheck == nil else { return }
        armDebounce(after: u)
    }

    private func armDebounce(after u: Utterance) {
        debounce?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self, let q = self.gate.fire() else { return }
            self.ask(q)
        }
        debounce = w
        queue.asyncAfter(deadline: .now() + gate.delay(after: u, slow: debounceDelay), execute: w)
    }

    /// «Подскажи» из динамиков (сказал собеседник, микрофон подхватил) — не команда пользователя.
    /// Реплика «они» с теми же словами может прийти позже эха (звук системы расшифровывается
    /// своим потоком), поэтому решаем не сразу, а через `echoWait`, по всем репликам к этому моменту.
    private func voiceCommand(_ u: Utterance) {
        if Echo.isEcho(u, in: store.utterances) {
            debugLog.log("«подскажи» — эхо собеседника, пропускаю")
            return
        }
        // Ответ пойдёт только через ~1.2 с проверки на эхо: без отметки сразу кажется, что команду не услышали.
        model.showFlash(Self.hearingFlash)
        let last = store.last(.they)
        debounce?.cancel()
        debounce = nil
        commandCheck?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.commandCheck = nil
            guard self.brain != nil, self.listening else { return }
            if Echo.isEcho(u, in: self.store.utterances) {
                self.debugLog.log("«подскажи» — эхо собеседника (реплика пришла позже), пропускаю")
                self.model.clearFlash(Self.hearingFlash)
                // Вопрос собеседника, копившийся пока ждали, — обычным порядком.
                if self.gate.pending != nil, let they = self.store.last(.they) { self.armDebounce(after: they) }
                return
            }
            self.manual(command: u)
            self.onVoiceAsk?(last)
        }
        commandCheck = w
        queue.asyncAfter(deadline: .now() + echoWait, execute: w)
    }

    private func ask(_ q: PendingQuestion) {
        debugLog.log("вопрос мозгу: \(q.text)")
        onEvent?(.asked(label: q.text))
        brain?.ask(BrainPrompt.build(log: conversation, question: q, topic: topic), label: q.text)
    }

    /// Лог без голосовых команд («суфлёр, подскажи» — обращение к суфлёру, а не часть разговора)
    /// и без эха: на динамиках микрофон повторяет собеседника, и мозг принял бы его слова за слова пользователя.
    private var conversation: [Utterance] {
        let log = store.utterances
        return log.filter { !($0.channel == .me && (VoiceCommand.isAskTrigger($0.text) || Echo.isEcho($0, in: log))) }
    }

    /// Тему спрашиваем после минуты разговора; не определилась — ещё через минуту, но не больше трёх раз,
    /// чтобы не жечь мозг на созвоне, где темы просто нет.
    private func maybeDetectTopic() {
        guard autoTopic, topic.isEmpty, !topicInFlight, topicAttempts < TopicDetection.maxAttempts,
              let brain else { return }
        let log = conversation
        guard let first = log.first, let last = log.last,
              last.end.timeIntervalSince(first.start) >= TopicDetection.after * Double(topicAttempts + 1) else { return }
        topicAttempts += 1
        topicInFlight = true
        brain.detectTopic(TopicDetection.message(log: log))
    }

    private func topicDetected(_ text: String) {
        // Пока мозг думал, тема могла прийти из календаря — она точнее.
        guard topic.isEmpty, let t = TopicDetection.parse(text) else {
            debugLog.log("тема по разговору не определилась")
            return
        }
        appLog.info("Тема определена по разговору")
        onTopic?(t)
        useTopic(t)
    }

    private func show(_ s: Brain.Status) {
        debugLog.log("мозг: \(s)")
        switch s {
        case .warming: model.setBrainState(.warming)
        case .ready:
            model.setBrainState(.ready)
            if !greeted {
                greeted = true
                onReady?()
            }
        case .timedOut: model.setBrainState(.timedOut)
        case .unavailable(let why):
            model.setBrainState(BrainStream.looksLikeLimit(why) ? .limit(why) : .error(why))
        }
    }
}

/// Текст реплик в системный лог — только по явному включению: по умолчанию в лог не уходит ни слова
/// из разговора. Нужен, чтобы пользователь сам увидел, как whisper записал команду, когда она не сработала.
public enum TranscriptDebug {
    public static let envKey = "SUFLYOR_DEBUG"
    public static let defaultsKey = "suflyor.debugTranscript"

    public static func enabled(env: [String: String] = ProcessInfo.processInfo.environment,
                               defaults: UserDefaults = .standard) -> Bool {
        env[envKey] == "1" || defaults.bool(forKey: defaultsKey)
    }
}
