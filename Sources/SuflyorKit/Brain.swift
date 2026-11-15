import Foundation

/// Мозг на одну сессию: долгоживущие процессы CLI, вопросы идут в stdin, ответ читается потоком.
///
/// Процессы держим живыми всю сессию, а не запускаем на каждый вопрос: холодный старт
/// стоит секунды, а подсказка нужна, пока собеседник ещё ждёт ответа.
///
/// Процессов два. Основной отвечает только на вопросы: шпаргалка длинная, и вопрос, вставший
/// за ней в очередь одного процесса, ждал бы её десятки секунд. Фоновый (шпаргалка, тема)
/// поднимается лениво, при первой фоновой задаче, на модели попроще.
///
/// В каждый процесс в полёте строго один запрос: следующий пишем в stdin только после result
/// предыдущего. Иначе ответы разъезжаются по вопросам, а зависший ответ держит всё за собой.
/// Зависший процесс (нет ответа за `answerTimeout`) убиваем и поднимаем свежий — ждать его бесполезно.
///
/// Всё состояние — на своей последовательной очереди, колбэки — на `callbackQueue`.
public final class Brain: @unchecked Sendable {
    public struct Config {
        /// nil — ищем сами (`BrainLaunch.findBrainBinary`).
        public var brainBinary: String?
        public var model = BrainLaunch.model()
        public var backgroundModel = BrainLaunch.backgroundModel
        public var fallbackModel: String? = BrainLaunch.fallbackModel
        /// nil — без флага `--effort`.
        public var effort: String? = BrainLaunch.effort()
        public var systemPromptFile: URL
        public var briefFile: URL?
        public var warmupMessage = "Сессия началась. Ответь одним словом: готов"
        /// Сколько раз подряд поднимаем упавший процесс сами; дальше чинит человек (⌃⌥⌘ дважды).
        public var maxAutoRestarts = 1
        /// Бюджет перезапусков возвращается, если процесс проработал столько без падений…
        public var restartBudgetResetAfter: TimeInterval = 300
        /// …или столько раз подряд ответил.
        public var restartBudgetResetAnswers = 3
        /// Сколько ждать конца ответа. Дольше подсказка уже бесполезна, а процесс, видимо, завис.
        public var answerTimeout: TimeInterval = 25
        /// Шпаргалка длинная и прогрев с холодным стартом — им больше.
        public var prepTimeout: TimeInterval = 60
        /// Контекст основного процесса растёт с каждым вопросом, а с ним время до первого слова.
        /// После стольких ответов или такого входа одного хода процесс заменяем свежим.
        public var replaceAfterAnswers = 25
        public var replaceAfterInputTokens = 150_000
        /// Окружение, из которого берём белый список; nil — окружение приложения.
        public var environment: [String: String]?

        public init(systemPromptFile: URL, briefFile: URL?, brainBinary: String? = nil) {
            self.systemPromptFile = systemPromptFile
            self.briefFile = briefFile
            self.brainBinary = brainBinary
        }
    }

    public enum Status: Equatable {
        case warming
        case ready
        /// Последний вопрос остался без ответа за отведённое время; процесс заменён свежим.
        case timedOut
        case unavailable(String)
    }

    public struct Request {
        public enum Kind {
            case warmup, answer, prep, topic
            /// Фоновая работа (шпаргалка, определение темы) идёт в свой процесс и вопросы не держит.
            var isBackground: Bool { self == .prep || self == .topic }
        }

        public let id: Int
        public let content: String
        /// Что показать над подсказкой: на какую реплику отвечаем.
        public let label: String
        public let kind: Kind
        /// Уже переотправлен после падения процесса: второй раз не шлём.
        var resent = false
    }

    public var onStatus: ((Status) -> Void)?
    /// Колбэки ответа — для вопросов и шпаргалки; ответ на прогрев никому не показываем.
    public var onAnswerStart: ((Request) -> Void)?
    public var onDelta: ((Request, String) -> Void)?
    /// Полный текст и секунды от отправки вопроса до конца ответа.
    public var onAnswerEnd: ((Request, String, TimeInterval) -> Void)?
    /// Ответа не будет: ошибка, лимит или таймаут.
    public var onAnswerFailed: ((Request, String) -> Void)?
    /// Служебные строки для отладочного журнала (перезапуски, usage). Без текста разговора.
    public var onLog: ((String) -> Void)?

    public let config: Config
    private let callbackQueue: DispatchQueue
    private let q = DispatchQueue(label: "suflyor.brain")

    /// Один процесс CLI и то, что в нём сейчас происходит.
    private final class Worker {
        enum Role { case main, standby, background }
        var role: Role
        /// По номеру события из пайпов находят свой процесс; от убитого — уже никого не находят.
        let token: Int
        let process: Process
        let stdin: FileHandle
        let dir: URL
        let launchedAt = Date()
        /// Запрос, записанный в stdin и ещё без result. Больше одного не бывает.
        var inFlight: Request?
        var sentAt = Date()
        var warmed = false
        var answers = 0
        var answer = BrainAnswerAccumulator()
        var lineBuffer = Data()
        var stderrTail = Data()

        init(role: Role, token: Int, process: Process, stdin: FileHandle, dir: URL) {
            self.role = role
            self.token = token
            self.process = process
            self.stdin = stdin
            self.dir = dir
        }
    }

    /// Основной процесс: вопросы.
    private var main: Worker?
    /// Тёплая замена основного: прогревается, пока основной ещё отвечает, и встаёт на его место между вопросами.
    private var standby: Worker?
    /// Фоновый процесс: шпаргалка и тема.
    private var bg: Worker?
    /// Ждущий вопрос: один, более свежий вытесняет — отвечать на устаревший уже поздно.
    private var waiting: Request?
    /// Погашенные, но ещё не вышедшие процессы: при выходе из приложения дожидаемся и их,
    /// иначе их временные папки пережили бы нас.
    private var retiring: [Int: Worker] = [:]
    /// Фоновые задачи по порядку: друг друга не вытесняют.
    private var bgQueue: [Request] = []
    private var mainBudget: RestartBudget
    private var bgBudget: RestartBudget
    private var nextToken = 0
    private var nextID = 0
    /// Основной процесс больше не поднимаем: вопросы не принимаются.
    private var dead = false
    /// Фоновый процесс больше не поднимаем: фоновые задачи сразу проваливаются.
    private var bgDead = false
    private var stopped = false
    private var lastStatus: Status?

    public init(config: Config, callbackQueue: DispatchQueue = .main) {
        self.config = config
        self.callbackQueue = callbackQueue
        mainBudget = RestartBudget(max: config.maxAutoRestarts, resetAfter: config.restartBudgetResetAfter,
                                   resetAnswers: config.restartBudgetResetAnswers)
        bgBudget = mainBudget
        // Запись в stdin умершего процесса иначе убивает всё приложение сигналом SIGPIPE;
        // с игнором запись просто бросает ошибку, а смерть процесса ловит terminationHandler.
        signal(SIGPIPE, SIG_IGN)
    }

    public func start() {
        q.async { self.launchMain(announce: true) }
    }

    /// Вопрос мозгу. Пока идёт ответ, новый ждёт; ждущий вытесняется следующим.
    public func ask(_ content: String, label: String) {
        q.async {
            guard !self.stopped, !self.dead else { return }
            let r = self.request(content, label: label, kind: .answer)
            self.waiting = r
            self.pumpMain()
        }
    }

    /// Подготовка шпаргалки: ответ идёт не в подсказку; делается в фоновом процессе.
    public func prepare(_ content: String, label: String = "шпаргалка") {
        enqueueBackground(content, label: label, kind: .prep)
    }

    /// Определение темы по расшифровке — тоже фоновое.
    public func detectTopic(_ content: String) {
        enqueueBackground(content, label: "тема", kind: .topic)
    }

    private func request(_ content: String, label: String, kind: Request.Kind) -> Request {
        nextID += 1
        return Request(id: nextID, content: content, label: label, kind: kind)
    }

    private func enqueueBackground(_ content: String, label: String, kind: Request.Kind) {
        q.async {
            guard !self.stopped else { return }
            let r = self.request(content, label: label, kind: kind)
            guard !self.bgDead else {
                self.callback { $0.onAnswerFailed?(r, "фоновый мозг недоступен") }
                return
            }
            self.bgQueue.append(r)
            self.pumpBackground()
        }
    }

    /// Остановка всех процессов и удаление их временных папок. По умолчанию не блокирует
    /// вызывающего; `wait: true` — для выхода из приложения, иначе процесс мог бы пережить нас.
    public func stop(wait: Bool = false) {
        let work = {
            guard !self.stopped else { return }
            self.stopped = true
            self.waiting = nil
            self.bgQueue = []
            for w in [self.main, self.standby, self.bg].compactMap({ $0 }) + Array(self.retiring.values) {
                self.retire(w, wait: wait)
            }
            self.main = nil
            self.standby = nil
            self.bg = nil
        }
        if wait { q.sync(execute: work) } else { q.async(execute: work) }
    }

    /// pid основного процесса (для тестов и логов).
    public var pid: pid_t? { q.sync { main?.process.processIdentifier } }
    /// pid фонового процесса; nil — фоновой работы ещё не было.
    public var backgroundPid: pid_t? { q.sync { bg?.process.processIdentifier } }

    // MARK: - Очереди

    /// Основной процесс свободен: сначала, если готова, — тёплая замена, потом ждущий вопрос.
    private func pumpMain() {
        swapIfReady()
        guard let m = main, m.inFlight == nil, let r = waiting else { return }
        waiting = nil
        send(r, to: m)
    }

    private func pumpBackground() {
        guard !stopped, !bgQueue.isEmpty else { return }
        if bg == nil {
            guard let w = spawn(.background, model: config.backgroundModel) else {
                bgDead = true
                failBackgroundQueue("фоновый мозг не запустился")
                return
            }
            bg = w
        }
        guard let w = bg, w.inFlight == nil else { return }
        send(bgQueue.removeFirst(), to: w)
    }

    private func failBackgroundQueue(_ why: String) {
        let failed = bgQueue
        bgQueue = []
        for r in failed { callback { $0.onAnswerFailed?(r, why) } }
    }

    /// Замена прогрелась и основной процесс между вопросами — переключаемся, старый гасим.
    private func swapIfReady() {
        guard let s = standby, s.warmed, let m = main, m.inFlight == nil else { return }
        log("мозг: основной процесс заменён свежим после \(m.answers) ответов")
        promoteStandby(replacing: m)
    }

    private func promoteStandby(replacing old: Worker?) {
        guard let s = standby else { return }
        if let old { retire(old) }
        standby = nil
        s.role = .main
        main = s
    }

    /// Пора ли держать тёплую замену: контекст основного процесса вырос.
    private func maybePrepareReplacement(_ m: Worker, usage: BrainStream.Usage?) {
        guard standby == nil, !stopped else { return }
        let big = (usage?.totalInput ?? 0) > config.replaceAfterInputTokens
        guard m.answers >= config.replaceAfterAnswers || big else { return }
        guard let s = spawn(.standby, model: config.model) else { return }
        log("мозг: готовлю замену основному процессу (ответов \(m.answers), вход \(usage?.totalInput ?? 0))")
        standby = s
        send(request(config.warmupMessage, label: "", kind: .warmup), to: s)
    }

    // MARK: - Процесс

    /// Новый основной процесс с прогревом. `announce` — показать «прогрев…»; после таймаута
    /// не показываем: в панели пусть остаётся «мозг не ответил», пока замена не готова.
    private func launchMain(announce: Bool) {
        guard !stopped else { return }
        guard let w = spawn(.main, model: config.model) else { return }
        main = w
        if announce { emit(.warming) }
        send(request(config.warmupMessage, label: "", kind: .warmup), to: w)
    }

    /// Ошибка запуска основного процесса — «мозг недоступен»; фонового — проваленные задачи.
    private func spawn(_ role: Worker.Role, model: String) -> Worker? {
        let fail: (String) -> Void = { why in
            guard role == .main else { self.log("мозг (\(role)): \(why)"); return }
            self.dead = true
            self.emit(.unavailable(why))
        }
        guard let bin = config.brainBinary ?? BrainLaunch.findBrainBinary() else {
            fail("не найден бинарь мозга")
            return nil
        }
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: bin) else {
            fail("не найден бинарь мозга: \(bin)")
            return nil
        }
        // Пустая свежая папка: процесс не увидит ни файлов проекта, ни чужих настроек рядом.
        let dir = fm.temporaryDirectory.appendingPathComponent("suflyor-brain-\(UUID().uuidString)")
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            fail("не создать временную папку: \(error.localizedDescription)")
            return nil
        }

        nextToken += 1
        let token = nextToken
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = BrainLaunch.arguments(model: model, effort: config.effort, fallbackModel: config.fallbackModel,
                                            systemPromptFile: config.systemPromptFile, briefFile: config.briefFile)
        p.environment = BrainLaunch.environment(from: config.environment ?? ProcessInfo.processInfo.environment)
        p.currentDirectoryURL = dir
        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = errPipe
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; return }
            self?.q.async { if let w = self?.worker(token) { self?.consume(d, w) } }
        }
        errPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; return }
            self?.q.async {
                guard let w = self?.worker(token) else { return }
                // Хвоста хватает, чтобы показать причину смерти процесса.
                w.stderrTail.append(d)
                if w.stderrTail.count > 600 { w.stderrTail = w.stderrTail.suffix(600) }
            }
        }
        p.terminationHandler = { [weak self] proc in
            let code = proc.terminationStatus
            self?.q.async { self?.exited(token: token, code: code, dir: dir) }
        }
        do {
            try p.run()
        } catch {
            try? fm.removeItem(at: dir)
            fail("не запустился: \(error.localizedDescription)")
            return nil
        }
        appLog.info("мозг pid=\(p.processIdentifier)")
        log("мозг (\(role), \(model)): запущен pid \(p.processIdentifier)")
        return Worker(role: role, token: token, process: p, stdin: inPipe.fileHandleForWriting, dir: dir)
    }

    private func worker(_ token: Int) -> Worker? {
        [main, standby, bg].compactMap { $0 }.first { $0.token == token }
    }

    private func send(_ r: Request, to w: Worker) {
        // Строго один запрос в полёте: иначе result пришлось бы угадывать, к какому вопросу он.
        // В сборке для созвона не падаем, а отказываем запросу: лучше без подсказки, чем без суфлёра.
        guard w.inFlight == nil else {
            assertionFailure("мозг: второй запрос в процесс до конца первого")
            if r.kind != .warmup { callback { $0.onAnswerFailed?(r, "мозг занят") } }
            return
        }
        w.inFlight = r
        w.sentAt = Date()
        w.answer = BrainAnswerAccumulator()
        if r.kind != .warmup { callback { $0.onAnswerStart?(r) } }
        do {
            try w.stdin.write(contentsOf: BrainLaunch.userMessage(r.content))
        } catch {
            // Процесс уже умер: дальше разберётся exited().
            appLog.error("мозг: запись в stdin не удалась: \(error.localizedDescription)")
        }
        // Прогрев включает холодный старт процесса, поэтому ему тот же запас, что шпаргалке.
        let limit = r.kind == .answer ? config.answerTimeout : config.prepTimeout
        let token = w.token
        q.asyncAfter(deadline: .now() + limit) { [weak self] in self?.timedOut(r, token: token) }
    }

    /// Ответа нет слишком долго: процесс, скорее всего, завис. Убиваем и поднимаем свежий;
    /// сам вопрос не переотправляем — пока новый процесс прогреется, он уже устарел.
    private func timedOut(_ r: Request, token: Int) {
        guard !stopped, let w = worker(token), w.inFlight?.id == r.id else { return }
        appLog.error("мозг не ответил за отведённое время, вопрос \(r.id)")
        log("мозг (\(w.role)): нет ответа за отведённое время, процесс заменён")
        switch w.role {
        case .standby:
            retire(w)
            standby = nil
        case .background:
            callback { $0.onAnswerFailed?(r, "мозг не ответил") }
            retire(w)
            bg = nil
            pumpBackground()
        case .main:
            retire(w)
            main = nil
            if r.kind == .warmup {
                // Не прогрелся: считаем как падение, иначе без сети он перезапускался бы бесконечно.
                guard mainBudget.allow(launchedAt: w.launchedAt) else {
                    dead = true
                    waiting = nil
                    emit(.unavailable("мозг не прогрелся"))
                    return
                }
                launchMain(announce: true)
                return
            }
            callback { $0.onAnswerFailed?(r, "мозг не ответил") }
            emit(.timedOut)
            // Тёплая замена (если уже есть) встаёт сразу, без холодного старта.
            if standby != nil {
                promoteStandby(replacing: nil)
                pumpMain()
            } else {
                launchMain(announce: false)
            }
        }
    }

    private func consume(_ d: Data, _ w: Worker) {
        w.lineBuffer.append(d)
        while let nl = w.lineBuffer.firstIndex(of: 0x0A) {
            let lineData = w.lineBuffer[w.lineBuffer.startIndex..<nl]
            w.lineBuffer.removeSubrange(w.lineBuffer.startIndex...nl)
            if let line = String(data: lineData, encoding: .utf8) { handle(line, w) }
            // Строка могла заменить или погасить процесс: остаток буфера ему уже не принадлежит.
            guard worker(w.token) === w else { return }
        }
    }

    private func handle(_ line: String, _ w: Worker) {
        guard let r = w.inFlight, let out = w.answer.feed(line) else { return }
        switch out {
        case .delta(let s):
            if r.kind != .warmup { callback { $0.onDelta?(r, s) } }
        case .finished(let text):
            w.inFlight = nil
            let usage = BrainStream.usage(line)
            if let u = usage {
                log("мозг (\(w.role)): usage вход \(u.input), cache_read \(u.cacheRead), cache_creation \(u.cacheCreation), выход \(u.output)")
            }
            let secs = Date().timeIntervalSince(w.sentAt)
            if r.kind == .warmup {
                w.warmed = true
            } else {
                callback { $0.onAnswerEnd?(r, text, secs) }
            }
            finished(w, request: r, usage: usage)
        case .failed(let msg):
            w.inFlight = nil
            if r.kind == .warmup {
                // Прогрев не прошёл (например, лимит), но процесс жив: вопросы всё равно попробуем.
                w.warmed = true
            } else {
                callback { $0.onAnswerFailed?(r, msg) }
            }
            switch w.role {
            case .main:
                emit(.unavailable(msg))
                pumpMain()
            case .standby:
                // Замена не нужна, если не может ответить: основной пока живёт дальше.
                retire(w)
                standby = nil
            case .background:
                pumpBackground()
            }
        }
    }

    private func finished(_ w: Worker, request r: Request, usage: BrainStream.Usage?) {
        switch w.role {
        case .main:
            emit(.ready)
            if r.kind == .answer {
                w.answers += 1
                mainBudget.success()
                maybePrepareReplacement(w, usage: usage)
            }
            pumpMain()
        case .standby:
            pumpMain()
        case .background:
            bgBudget.success()
            pumpBackground()
        }
    }

    private func exited(token: Int, code: Int32, dir: URL) {
        try? FileManager.default.removeItem(at: dir)
        retiring[token] = nil
        guard !stopped, let w = worker(token) else { return }
        let why = String(data: w.stderrTail, encoding: .utf8).map(BrainStream.short) ?? ""
        appLog.error("мозг завершился, код \(code)")
        log("мозг (\(w.role)): процесс завершился, код \(code)")
        let crashed = w.inFlight
        w.inFlight = nil
        switch w.role {
        case .standby:
            standby = nil
        case .background:
            bg = nil
            let allowed = bgBudget.allow(launchedAt: w.launchedAt)
            if let c = crashed {
                // Фоновая задача после перезапуска встаёт обратно в начало очереди, но только один раз.
                if allowed && !c.resent {
                    var again = c
                    again.resent = true
                    bgQueue.insert(again, at: 0)
                } else {
                    callback { $0.onAnswerFailed?(c, "процесс завершился") }
                }
            }
            // Новый фоновый процесс поднимется сам, когда в очереди будет задача.
            if allowed { pumpBackground() } else {
                bgDead = true
                failBackgroundQueue("процесс завершился")
            }
        case .main:
            main = nil
            guard mainBudget.allow(launchedAt: w.launchedAt) else {
                dead = true
                if let r = crashed, r.kind != .warmup { callback { $0.onAnswerFailed?(r, "процесс завершился") } }
                waiting = nil
                if let s = standby { retire(s); standby = nil }
                emit(.unavailable("процесс завершился (код \(code))" + (why.isEmpty ? "" : ": \(why)")))
                return
            }
            // Вопрос, на котором процесс упал, переотправляем один раз: возможно, упал не из-за него.
            // Более свежий ждущий вопрос, как и везде, вытесняет переотправку.
            if let c = crashed, c.kind == .answer {
                if c.resent || waiting != nil {
                    callback { $0.onAnswerFailed?(c, "процесс завершился") }
                } else {
                    var again = c
                    again.resent = true
                    waiting = again
                }
            }
            if standby != nil {
                promoteStandby(replacing: nil)
                pumpMain()
            } else {
                launchMain(announce: true)
            }
        }
    }

    /// Погасить процесс: он больше ничей, его события никто не ждёт.
    private func retire(_ w: Worker, wait: Bool = false) {
        let p = w.process
        let dir = w.dir
        w.inFlight = nil
        if p.isRunning { retiring[w.token] = w }
        try? w.stdin.close()
        // Закрытый stdin — штатный сигнал «вопросов больше не будет»; terminate — если не понял.
        let finish = {
            let deadline = Date().addingTimeInterval(1)
            while p.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
            if p.isRunning { p.terminate() }
            let hard = Date().addingTimeInterval(2)
            while p.isRunning && Date() < hard { Thread.sleep(forTimeInterval: 0.05) }
            if p.isRunning { kill(p.processIdentifier, SIGKILL) }
            try? FileManager.default.removeItem(at: dir)
        }
        // Обычно ждём выхода не на своей очереди: состояние мозга не должно стоять до 3 с.
        if wait { finish() } else { DispatchQueue.global(qos: .utility).async(execute: finish) }
    }

    private func emit(_ s: Status) {
        guard s != lastStatus else { return }
        lastStatus = s
        callback { $0.onStatus?(s) }
    }

    private func log(_ line: String) {
        callback { $0.onLog?(line) }
    }

    private func callback(_ f: @escaping (Brain) -> Void) {
        callbackQueue.async { f(self) }
    }
}

/// Сколько раз подряд можно самим поднять упавший процесс. Подряд — значит без передышки:
/// процесс, проработавший `resetAfter` или ответивший `resetAnswers` раз, возвращает бюджет целиком,
/// иначе одно падение утром оставило бы мозг без перезапуска до вечера.
struct RestartBudget {
    let max: Int
    let resetAfter: TimeInterval
    let resetAnswers: Int
    private(set) var used = 0
    private var answersSinceRestart = 0

    init(max: Int, resetAfter: TimeInterval, resetAnswers: Int) {
        self.max = max
        self.resetAfter = resetAfter
        self.resetAnswers = resetAnswers
    }

    /// Процесс, запущенный в `launchedAt`, упал: поднимать ли новый (и списать попытку).
    mutating func allow(launchedAt: Date, now: Date = Date()) -> Bool {
        if now.timeIntervalSince(launchedAt) >= resetAfter { used = 0 }
        guard used < max else { return false }
        used += 1
        answersSinceRestart = 0
        return true
    }

    mutating func success() {
        answersSinceRestart += 1
        if answersSinceRestart >= resetAnswers { used = 0 }
    }
}
