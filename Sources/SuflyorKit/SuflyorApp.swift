import AppKit
import AVFoundation
import Carbon.HIToolbox
import Combine
import CoreGraphics

/// Сборка приложения: панель, ⌃⌥⌘, whisper-server, два канала звука, мозг подсказок.
///
/// Вне созвона приложение «спит»: панель скрыта, звук не захватывается, whisper-server и мозг
/// не запущены, слушаются только модификаторы (⌃⌥⌘). Ход сессии:
/// ⌃⌥⌘ → прогрев мозга и сразу захват звука → «Готов, начинаем» → подсказки; тема — из календаря
/// или из первой минуты разговора, шпаргалка по ней в фоне → ⌃⌥⌘ или кнопка питания → всё гасим,
/// транскрипт забываем.
///
/// Публичные точки:
/// - `store.subscribe { utterance in … }` — новые реплики (любой поток);
/// - `store.utterances` / `store.last(.they)` — лог текущей сессии в памяти;
/// - `model.setHint(_:)` / `model.appendHint(_:)` — только с main;
/// - `onAnswerRequest` — Пользователь сказал «суфлёр, подскажи», приходит последняя реплика собеседника (на main);
/// - `onSessionEnd` — конец сессии, весь транскрипт (на main), сразу после — он стирается.
public final class SuflyorApp: NSObject, NSApplicationDelegate, NSWindowDelegate {
    public let store = TranscriptStore()
    public let model = PanelModel()
    public var onAnswerRequest: ((Utterance?) -> Void)?
    /// Хук для конспекта. Пока никто не подписан.
    public var onSessionEnd: (([Utterance]) -> Void)?

    static let compactHeight: CGFloat = 76
    /// Как часто проверять, выдал ли пользователь разрешение в настройках macOS.
    static let permissionPoll: TimeInterval = 2
    /// Флаг «после перезапуска сразу продолжить сессию» (время записи; старый — не в счёт).
    static let resumeKey = "resume_session_after_relaunch"
    static let resumeWindow: TimeInterval = 60
    /// Аргумент запуска: сразу начать сессию, как от ⌃⌥⌘ (живой тест без нажатий).
    public static let startSessionArg = "--start-session"
    /// Как часто писать уровни звука в отладочный журнал.
    static let levelsInterval: TimeInterval = 5
    /// Звук системы оборвался (сменился дисплей, система сбросила поток) — столько раз поднимаем заново.
    /// Запас возвращается, если поток после перезапуска прожил минуту без обрыва.
    static let systemRetries = 3
    static let systemRetryDelay: TimeInterval = 2
    static let systemStableAfter: TimeInterval = 60
    /// Второй экземпляр с `--start-session` просит работающий начать сессию — без данных в уведомлении.
    static let startNotification = Notification.Name("com.danila-builds.suflyor.start")
    /// Перезапуск после выдачи доступа: старый процесс ещё может доживать, ждём его столько.
    static let relaunchOverlap: TimeInterval = 3

    private var panel: SuflyorPanel?
    private let hotKeys = HotKeys()
    private var chord: ChordMonitor?
    private var trustTimer: Timer?
    private var screenTimer: Timer?
    /// Системное окно «Запись экрана» открываем один раз за запуск, а не на каждую сессию.
    private var screenAsked = false
    private let defaults = UserDefaults.standard
    private var server: WhisperServer?
    private var mic: MicCapture?
    private var system: SystemAudioCapture?
    private var pipelines: [Channel: ChannelPipeline] = [:]
    private var prompter: Prompter?
    private let mode = SessionMode.product
    /// Номер сессии: запоздавшие колбэки прошлой сессии (whisper, микрофон) по нему отбрасываются.
    private var sessionID = 0
    private var fullFrame: NSRect?
    private var calendarSource: EventKitSource?
    private var bag: Set<AnyCancellable> = []
    private var signalSources: [DispatchSourceSignal] = []
    private var stopped = false
    private let debugLog = DebugLog.shared
    private var levels: [Channel: LevelMeter] = [:]
    private var levelsTimer: Timer?
    private var systemBudget = RetryBudget(max: SuflyorApp.systemRetries, stableAfter: SuflyorApp.systemStableAfter)
    private var transcriber: Transcriber?
    /// whisper в этой сессии уже перезапускали: второй сбой — сдаёмся с ошибкой в панели.
    private var whisperRestarted = false
    /// Доступ к микрофону не дали — проверяем, не включил ли его пользователь посреди сессии.
    private var micAccessTimer: Timer?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    public override init() { super.init() }

    /// Начать сессию сразу после запуска: `open Suflyor.app --args --start-session`.
    static func wantsAutoStart(_ args: [String]) -> Bool { args.contains(startSessionArg) }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        let s = PanelSettings.load(defaults)
        model.opacity = s.opacity
        model.hintFontSize = s.hintFontSize
        model.calendarEnabled = s.calendarEnabled
        makePanel()
        bindSettings()
        installChord()
        registerFallbackKey()
        installSignalHandlers()
        installObservers()
        // Уборка за упавшим прошлым запуском — в фоне, старт сессии её не ждёт.
        DispatchQueue.global(qos: .utility).async { StartupCleanup.run() }
        store.subscribe { [weak self] u in
            DispatchQueue.main.async { self?.model.add(u) }
        }
        resumeAfterRelaunch()
        if Self.wantsAutoStart(CommandLine.arguments) {
            debugLog.log("запуск с \(Self.startSessionArg)")
            startSession()
        }
    }

    public func applicationWillTerminate(_ notification: Notification) {
        shutdown()
    }

    // MARK: - Панель

    private func makePanel() {
        var a = PanelActions()
        a.endSession = { [weak self] in self?.endSession() }
        a.quit = { NSApp.terminate(nil) }
        a.toggleCompact = { [weak self] in self?.toggleCompact() }
        a.toggleCalendar = { [weak self] in self?.toggleCalendar() }
        let p = SuflyorPanel(model: model, actions: a)
        p.delegate = self
        panel = p
    }

    /// Прозрачность и шрифт сохраняем сразу при изменении из меню.
    private func bindSettings() {
        // Саму прозрачность рисует подложка PanelView, тут только сохраняем.
        model.$opacity.dropFirst().sink { [weak self] v in self?.saveSettings(opacity: v) }.store(in: &bag)
        model.$hintFontSize.dropFirst().sink { [weak self] v in self?.saveSettings(font: v) }.store(in: &bag)
    }

    private func saveSettings(opacity: Double? = nil, font: Double? = nil, calendar: Bool? = nil) {
        PanelSettings(opacity: opacity ?? model.opacity, hintFontSize: font ?? model.hintFontSize,
                      calendarEnabled: calendar ?? model.calendarEnabled).save(defaults)
    }

    /// Показ из сна: место — сохранённое (если тот дисплей подключён) или встроенный дисплей.
    private func showPanel() {
        guard let p = panel else { return }
        let r = PanelPlacement.place(screens: PanelPlacement.currentScreens(), saved: PanelPlacement.load(defaults))
        model.setScreenWarning(r.warning)
        p.minSize = NSSize(width: 300, height: 360)
        p.setFrame(r.frame, display: false)
        // Без активации: фокус остаётся в Zoom/Meet.
        p.orderFrontRegardless()
    }

    public func windowDidMove(_ notification: Notification) { savePlacement() }
    public func windowDidEndLiveResize(_ notification: Notification) { savePlacement() }

    private func savePlacement() {
        guard let p = panel, !model.compact, p.isVisible,
              let id = PanelPlacement.screenID(containing: p.frame) else { return }
        PanelPlacement.save(.init(screenID: id, frame: p.frame), defaults)
    }

    /// Компактный режим (меню ⋯): полоска с одной строкой «скажи». Верхний край остаётся на месте.
    private func toggleCompact() {
        guard let p = panel, model.phase != .sleeping else { return }
        if model.compact {
            model.setCompact(false)
            p.minSize = NSSize(width: 300, height: 360)
            if let f = fullFrame { p.setFrame(f, display: true, animate: true) }
        } else {
            fullFrame = p.frame
            model.setCompact(true)
            p.minSize = NSSize(width: 300, height: 60)
            let f = p.frame
            p.setFrame(NSRect(x: f.minX, y: f.maxY - Self.compactHeight, width: f.width, height: Self.compactHeight),
                       display: true, animate: true)
        }
    }

    // MARK: - Клавиши

    /// ⌃⌥⌘ без буквы — единственное сочетание. Для чужих окон нужен «Универсальный доступ»:
    /// спрашиваем сами системным окном и ждём, пока пользователь его включит.
    private func installChord() {
        let m = ChordMonitor { [weak self] in self?.toggleSession() }
        chord = m
        m.install()
        guard !ChordMonitor.trusted else { return }
        ChordMonitor.askTrust()
        model.setNotice(Self.trustNotice)
        showPanel()
        trustTimer = Timer.scheduledTimer(withTimeInterval: Self.permissionPoll, repeats: true) { [weak self] _ in
            self?.checkTrust()
        }
    }

    static let trustNotice = "Включи Suflyor в «Универсальном доступе» — тогда заработает ⌃⌥⌘"

    private func checkTrust() {
        guard ChordMonitor.trusted else { return }
        trustTimer?.invalidate()
        trustTimer = nil
        // Монитор, поставленный до разрешения, может так и не начать получать события — ставим заново.
        chord?.reinstall()
        if model.notice == Self.trustNotice { model.setNotice(nil) }
        if model.phase == .sleeping { panel?.orderOut(nil) }
        appLog.info("Универсальный доступ получен, ⌃⌥⌘ работает")
    }

    /// Запасной ⌃⌥C через Carbon: работает и без «Универсального доступа». Не афишируем
    /// и молчим, если занят, — основное сочетание ⌃⌥⌘.
    private func registerFallbackKey() {
        hotKeys.register([
            .init(code: UInt32(kVK_ANSI_C), modifiers: HotKeys.ctrlOpt, name: "⌃⌥C") { [weak self] in
                self?.toggleSession()
            },
        ])
        if !hotKeys.failed.isEmpty { appLog.info("Запасной ⌃⌥C занят другим приложением") }
    }

    private func toggleSession() {
        if model.phase == .sleeping { startSession() } else { endSession() }
    }

    // MARK: - Сессия

    /// ⌃⌥⌘: окна темы нет — сразу прогрев мозга и захват звука. Тема и шпаргалка догоняют в фоне.
    /// Звук захватываем, не дожидаясь whisper: первые секунды созвона копятся в каналах
    /// (до 10 с) и уходят в расшифровку, как только сервер поднялся.
    /// `fresh: false` — продолжение после перезапуска процесса: отладочный журнал не обнуляем.
    private func startSession(fresh: Bool = true) {
        guard model.phase == .sleeping, !stopped else { return }
        sessionID += 1
        let id = sessionID
        // Флаг журнала — на каждую сессию: включил/выключил между созвонами, перезапуск не нужен.
        debugLog.reload(enabled: TranscriptDebug.enabled())
        if fresh { debugLog.startOver() }
        debugLog.log("сессия \(id): старт")
        logPermissions()
        model.reset()
        if !ChordMonitor.trusted { model.setNotice(Self.trustNotice) }
        model.setPhase(.listening)
        showPanel()

        let p = Prompter(mode: mode, store: store, model: model)
        p.autoTopic = true
        p.onReady = { [weak self] in
            guard let self, self.sessionID == id else { return }
            self.model.showBanner("Готов, начинаем")
        }
        p.onVoiceAsk = { [weak self] last in self?.onAnswerRequest?(last) }
        p.debugLog = debugLog
        prompter = p
        p.start()
        p.listening = true

        topicFromCalendar(id)
        requestPermissions(id)
        startLevels()

        let tr = Transcriber(store: store)
        tr.onBackendFailure = { [weak self] in
            DispatchQueue.main.async { self?.whisperFailed(id, reason: "whisper не отвечает") }
        }
        transcriber = tr
        let they = ChannelPipeline(channel: .they, transcriber: tr, open: false)
        let me = ChannelPipeline(channel: .me, transcriber: tr, open: false)
        pipelines = [.they: they, .me: me]
        startMic(id, me: me)
        startSystem(id, they: they)

        whisperRestarted = false
        model.status = "Загрузка whisper…"
        bootWhisper(id)
    }

    private func endSession() {
        guard model.phase != .sleeping else { return }
        appLog.info("Сессия завершена")
        debugLog.log("сессия \(sessionID): стоп")
        sessionID += 1
        screenTimer?.invalidate()
        screenTimer = nil
        micAccessTimer?.invalidate()
        micAccessTimer = nil
        stopLevels()
        prompter?.stop()
        prompter = nil
        mic?.stop()
        mic = nil
        system?.stopInBackground()
        system = nil
        pipelines = [:]
        transcriber?.setBackend(nil)
        transcriber = nil
        if let srv = server { DispatchQueue.global(qos: .utility).async { srv.stop() } }
        server = nil

        let transcript = store.utterances
        onSessionEnd?(transcript)
        store.reset()
        if model.compact { toggleCompact() }
        savePlacement()
        model.reset()
        model.setPhase(.sleeping)
        if ChordMonitor.trusted {
            panel?.orderOut(nil)
        } else {
            // Без разрешения ⌃⌥⌘ не работает — строку про него держим на виду.
            model.setNotice(Self.trustNotice)
        }
    }

    private func isCurrent(_ id: Int) -> Bool { sessionID == id && model.phase == .listening }

    private func addError(_ s: String, _ id: Int) {
        DispatchQueue.main.async { if self.isCurrent(id) { self.model.addError(s) } }
    }

    // MARK: - whisper

    static let whisperRestarting = "Расшифровка остановилась — перезапускаю"
    static let whisperStopped = "Расшифровка остановилась"

    /// Поднять whisper-server в фоне и, когда готов, открыть каналы. Колбэки старого сервера
    /// (или прошлой сессии) отбрасываются по `server === srv`.
    private func bootWhisper(_ id: Int) {
        let srv = WhisperServer()
        server = srv
        srv.onExit = { [weak self, weak srv] code in
            DispatchQueue.main.async {
                guard let self, let srv else { return }
                self.whisperFailed(id, reason: "whisper-server завершился (код \(code))", srv)
            }
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                try srv.start()
            } catch {
                DispatchQueue.main.async {
                    self?.whisperFailed(id, reason: "не поднялся: \(error.localizedDescription)", srv)
                }
                return
            }
            let client = WhisperClient(baseURL: srv.baseURL, language: srv.config.language)
            DispatchQueue.main.async {
                guard let self, self.isCurrent(id), self.server === srv else {
                    DispatchQueue.global(qos: .utility).async { srv.stop() }
                    return
                }
                self.debugLog.log("whisper порт \(srv.port)")
                self.transcriber?.setBackend { client.transcribe(wav: $0) }
                self.pipelines.values.forEach { $0.open() }
                self.model.status = ""
                self.model.errors.removeAll { $0 == Self.whisperRestarting }
            }
        }
    }

    /// whisper упал, не поднялся или 3 раза подряд не ответил. Один раз перезапускаем на новом
    /// порту (звук пока копится в каналах), второй сбой за сессию — ошибка в панели и без расшифровки.
    private func whisperFailed(_ id: Int, reason: String, _ srv: WhisperServer? = nil) {
        guard isCurrent(id), let current = server, srv == nil || srv === current else { return }
        debugLog.log("whisper: \(reason)")
        appLog.error("whisper: \(reason, privacy: .public)")
        pipelines.values.forEach { $0.pause() }
        transcriber?.setBackend(nil)
        server = nil
        DispatchQueue.global(qos: .utility).async { current.stop() }
        guard !whisperRestarted else {
            model.errors.removeAll { $0 == Self.whisperRestarting }
            model.status = "Без расшифровки"
            model.addError("\(Self.whisperStopped): \(reason)")
            return
        }
        whisperRestarted = true
        model.addError(Self.whisperRestarting)
        model.status = "Перезапуск whisper…"
        bootWhisper(id)
    }

    // MARK: - Захват звука

    private func startMic(_ id: Int, me: ChannelPipeline) {
        MicCapture.requestAccess { [weak self] ok in
            DispatchQueue.main.async {
                guard let self, self.isCurrent(id) else { return }
                guard ok else {
                    self.debugLog.log("микрофон: нет доступа")
                    self.model.addError(Self.micDenied)
                    self.waitMicAccess(id, me: me)
                    return
                }
                self.launchMic(id, me: me)
            }
        }
    }

    private func launchMic(_ id: Int, me: ChannelPipeline) {
        let meLevel = levels[.me]
        let m = MicCapture { meLevel?.feed($0); me.feed($0) }
        m.onRestart = { [weak self] in self?.debugLog.log("микрофон: устройство сменилось, перезапущен") }
        m.onError = { [weak self] e in
            self?.debugLog.log("микрофон пропал: \(e.localizedDescription)")
            self?.addError("Микрофон пропал: \(e.localizedDescription)", id)
        }
        do {
            try m.start()
            mic = m
            debugLog.log("микрофон: захват идёт")
        } catch {
            debugLog.log("микрофон не запустился: \(error.localizedDescription)")
            model.addError("Микрофон: \(error.localizedDescription)")
        }
    }

    /// Пользователь включил микрофон в настройках посреди сессии — подхватываем без перезапуска.
    private func waitMicAccess(_ id: Int, me: ChannelPipeline) {
        micAccessTimer?.invalidate()
        micAccessTimer = Timer.scheduledTimer(withTimeInterval: Self.permissionPoll, repeats: true) { [weak self] t in
            guard let self, self.isCurrent(id) else { t.invalidate(); return }
            guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { return }
            t.invalidate()
            self.micAccessTimer = nil
            self.model.errors.removeAll { $0 == Self.micDenied }
            self.debugLog.log("микрофон: доступ выдан посреди сессии")
            self.launchMic(id, me: me)
        }
    }

    /// Без разрешения ScreenCaptureKit только выдаст ещё одно системное окно — работаем на микрофоне.
    private func startSystem(_ id: Int, they: ChannelPipeline) {
        guard CGPreflightScreenCaptureAccess() else {
            debugLog.log("звук системы: нет доступа, только микрофон")
            return
        }
        systemBudget = RetryBudget(max: Self.systemRetries, stableAfter: Self.systemStableAfter)
        startSystemAudio(id, they: they)
    }

    /// Звук системы. Поток SCK может оборваться посреди созвона (подключили/отключили дисплей,
    /// система сбросила захват) — поднимаем заново несколько раз, потом сдаёмся с ошибкой в панели.
    private func startSystemAudio(_ id: Int, they: ChannelPipeline) {
        let theyLevel = levels[.they]
        let sys = SystemAudioCapture(onSamples: { theyLevel?.feed($0); they.feed($0) }, onError: { [weak self] e in
            DispatchQueue.main.async { self?.systemAudioFailed(id, they: they, error: e) }
        })
        Task { @MainActor in
            do {
                try await sys.start()
                if self.isCurrent(id) {
                    self.system = sys
                    self.systemBudget.started(at: Date())
                    self.debugLog.log("звук системы: захват идёт")
                } else {
                    sys.stopInBackground()
                }
            } catch {
                self.systemAudioFailed(id, they: they, error: error)
            }
        }
    }

    private func systemAudioFailed(_ id: Int, they: ChannelPipeline, error: Error) {
        debugLog.log("звук системы: ошибка \(error.localizedDescription)")
        guard isCurrent(id) else { return }
        system?.stopInBackground()
        system = nil
        guard systemBudget.failed(at: Date()), CGPreflightScreenCaptureAccess() else {
            model.addError("Звук системы остановился: \(error.localizedDescription)")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.systemRetryDelay) { [weak self] in
            guard let self, self.isCurrent(id) else { return }
            self.debugLog.log("звук системы: перезапуск, осталось попыток \(self.systemBudget.left)")
            self.startSystemAudio(id, they: they)
        }
    }

    /// Сон и пробуждение, второй экземпляр с `--start-session`.
    private func installObservers() {
        let ws = NSWorkspace.shared.notificationCenter
        observers.append((ws, ws.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.debugLog.log("мак засыпает")
        }))
        observers.append((ws, ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.didWake()
        }))
        let dn = DistributedNotificationCenter.default()
        observers.append((dn, dn.addObserver(forName: Self.startNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.debugLog.log("второй запуск просит начать сессию")
            // Уже идёт — ничего: повторный запуск не должен гасить сессию, как ⌃⌥⌘.
            if self.model.phase == .sleeping { self.startSession() }
        }))
    }

    /// После сна AVAudioEngine и SCK часто живы только на вид. Мягко пересоздаём оба захвата;
    /// транскрипт, whisper и мозг не трогаем — сессия продолжается.
    private func didWake() {
        guard model.phase == .listening else { return }
        let id = sessionID
        debugLog.log("мак проснулся: перезапуск микрофона и звука системы")
        if let m = mic, let me = pipelines[.me] {
            m.stop()
            mic = nil
            launchMic(id, me: me)
        }
        system?.stopInBackground()
        system = nil
        if let they = pipelines[.they] { startSystem(id, they: they) }
    }

    // MARK: - Отладочный журнал

    private func logPermissions() {
        guard debugLog.enabled else { return }
        let mic: String
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: mic = "есть"
        case .denied: mic = "запрещён"
        case .restricted: mic = "ограничен"
        case .notDetermined: mic = "не спрашивали"
        @unknown default: mic = "?"
        }
        debugLog.log("доступы: микрофон \(mic), звук системы \(CGPreflightScreenCaptureAccess() ? "есть" : "нет"), универсальный доступ \(ChordMonitor.trusted ? "есть" : "нет")")
    }

    /// Уровни звука раз в 5 с: по журналу видно, что оба канала реально идут и это не тишина.
    /// Только при включённом журнале — иначе и счётчики не нужны.
    private func startLevels() {
        guard debugLog.enabled else { levels = [:]; return }
        let they = LevelMeter(), me = LevelMeter()
        levels = [.they: they, .me: me]
        levelsTimer?.invalidate()
        levelsTimer = Timer.scheduledTimer(withTimeInterval: Self.levelsInterval, repeats: true) { [weak self] _ in
            self?.debugLog.log("уровни: они \(LevelMeter.describe(they.take())); я \(LevelMeter.describe(me.take()))")
        }
    }

    private func stopLevels() {
        levelsTimer?.invalidate()
        levelsTimer = nil
        levels = [:]
    }

    // MARK: - Доступы

    static let micDenied = "Нет доступа к микрофону — включи Suflyor в настройках «Микрофон»"
    static let screenNotice = "Включи Suflyor в открывшемся окне — я перезапущусь сам"

    /// Доступы спрашиваем сами в начале сессии — пользователь только жмёт «Разрешить».
    /// Звук системы macOS выдаёт только после перезапуска процесса, поэтому, как только
    /// разрешение появилось, перезапускаемся и продолжаем сессию.
    private func requestPermissions(_ id: Int) {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            MicCapture.requestAccess { _ in }
        }
        guard !CGPreflightScreenCaptureAccess() else { return }
        model.setSystemAudioOff(true)
        if !screenAsked {
            screenAsked = true
            CGRequestScreenCaptureAccess()
            Permissions.openScreenCapturePane()
        }
        model.setNotice(Self.screenNotice)
        screenTimer?.invalidate()
        screenTimer = Timer.scheduledTimer(withTimeInterval: Self.permissionPoll, repeats: true) { [weak self] _ in
            guard let self, self.sessionID == id, CGPreflightScreenCaptureAccess() else { return }
            self.screenTimer?.invalidate()
            self.screenTimer = nil
            self.relaunchAndResume()
        }
    }

    private func relaunchAndResume() {
        // Из .build (не из .app) перезапускать нечего — просим перезапустить руками.
        guard Bundle.main.bundlePath.hasSuffix(".app") else {
            model.setNotice("Доступ к звуку есть — перезапусти Суфлёр")
            return
        }
        appLog.info("Доступ к звуку системы получен, перезапуск")
        defaults.set(Date().timeIntervalSince1970, forKey: Self.resumeKey)
        // exit(0) сразу следом: без synchronize запись в cfprefsd может не успеть, и новый процесс
        // не узнает, что надо продолжить сессию.
        defaults.synchronize()
        debugLog.log("доступ к звуку системы получен, перезапуск")
        debugLog.flush()
        shutdown()
        Permissions.relaunch()
        exit(0)
    }

    /// Флаг одноразовый: снимаем сразу. Старый (перезапуск не удался, запустили руками позже) не в счёт.
    private func resumeAfterRelaunch() {
        guard defaults.object(forKey: Self.resumeKey) != nil else { return }
        let at = defaults.double(forKey: Self.resumeKey)
        defaults.removeObject(forKey: Self.resumeKey)
        guard Date().timeIntervalSince1970 - at < Self.resumeWindow else { return }
        appLog.info("Продолжаю сессию после перезапуска")
        startSession(fresh: false)
    }

    // MARK: - Календарь

    /// Встреча идёт сейчас или через ≤3 мин — её название и участники становятся темой,
    /// шпаргалка по ней готовится сразу, параллельно со слушанием. Нет доступа или встречи — молча,
    /// тема определится по разговору.
    private func topicFromCalendar(_ id: Int) {
        guard model.calendarEnabled else { return }
        let src = calendarSource ?? EventKitSource()
        calendarSource = src
        src.requestIfNeeded { [weak self] ok in
            guard let self, ok, self.isCurrent(id), let p = self.prompter, p.topic.isEmpty,
                  let e = CalendarWatcher.current(src, now: Date()) else { return }
            appLog.info("Тема из календаря")
            self.debugLog.log("тема из календаря")
            p.useTopic(e.topic)
        }
    }

    private func toggleCalendar() {
        if model.calendarEnabled {
            model.calendarEnabled = false
            saveSettings(calendar: false)
            return
        }
        let src = calendarSource ?? EventKitSource()
        calendarSource = src
        src.requestIfNeeded { [weak self] ok in
            guard let self else { return }
            guard ok else {
                self.model.showFlash("нет доступа к календарю")
                return
            }
            self.model.calendarEnabled = true
            self.saveSettings(calendar: true)
        }
    }

    // MARK: - Выход

    /// Гасим всё при любом выходе: висящий whisper держит ~0.5 ГБ памяти и порт,
    /// висящий мозг — сетевое соединение.
    public func shutdown() {
        guard !stopped else { return }
        stopped = true
        savePlacement()
        prompter?.stop(wait: true)
        prompter = nil
        mic?.stop()
        // SCK и whisper гасим параллельно с фоновых очередей: main здесь ждёт, и Task
        // на нём не стартовал бы — раньше выход и перезапуск после доступа теряли на этом 2 с.
        let group = DispatchGroup()
        if let sys = system {
            DispatchQueue.global(qos: .userInitiated).async(group: group) { sys.stopBlocking(timeout: 1.5) }
        }
        if let srv = server {
            DispatchQueue.global(qos: .userInitiated).async(group: group) { srv.stop() }
        }
        _ = group.wait(timeout: .now() + 2.5)
        debugLog.flush()
    }

    private func installSignalHandlers() {
        for sig in [SIGINT, SIGTERM, SIGHUP] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler { [weak self] in
                self?.shutdown()
                exit(0)
            }
            src.resume()
            signalSources.append(src)
        }
    }

    /// Обычный запуск приложения. `configure` — место для подписок (store, onAnswerRequest,
    /// onSessionEnd) до первой сессии.
    public static func runApp(configure: ((SuflyorApp) -> Void)? = nil) {
        enforceSingleInstance()
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = SuflyorApp()
        configure?(delegate)
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }

    // MARK: - Один экземпляр

    enum LaunchDecision: Equatable {
        case run
        /// Попросить работающий экземпляр начать сессию и выйти.
        case forwardStart
        case quit
    }

    /// Второй Suflyor рядом с работающим: два захвата микрофона, два whisper и два мозга на одном созвоне.
    static func launchDecision(args: [String], otherRunning: Bool) -> LaunchDecision {
        guard otherRunning else { return .run }
        return wantsAutoStart(args) ? .forwardStart : .quit
    }

    /// Из .build (без bundle id) проверять нечего. Перезапуск после выдачи доступа (`open -n`)
    /// может стартовать, пока старый процесс ещё гасит whisper, — даём ему время уйти.
    private static func enforceSingleInstance() {
        guard let bid = Bundle.main.bundleIdentifier else { return }
        let me = ProcessInfo.processInfo.processIdentifier
        func others() -> Bool {
            NSRunningApplication.runningApplications(withBundleIdentifier: bid)
                .contains { $0.processIdentifier != me && !$0.isTerminated }
        }
        var running = others()
        let d = UserDefaults.standard
        if running, d.object(forKey: resumeKey) != nil,
           Date().timeIntervalSince1970 - d.double(forKey: resumeKey) < resumeWindow {
            let deadline = Date().addingTimeInterval(relaunchOverlap)
            while running && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.1)
                running = others()
            }
        }
        switch launchDecision(args: CommandLine.arguments, otherRunning: running) {
        case .run:
            return
        case .forwardStart:
            DistributedNotificationCenter.default().postNotificationName(startNotification, object: nil,
                                                                         userInfo: nil, deliverImmediately: true)
            exit(0)
        case .quit:
            exit(0)
        }
    }
}
