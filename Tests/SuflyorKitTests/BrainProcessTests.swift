import Foundation
import Testing
@testable import SuflyorKit

/// Фейковый бинарь мозга: bash-скрипт, который говорит на stream-json.
/// Настоящий процесс в тестах не запускаем — тесты не должны ходить в сеть и тратить лимиты.
private final class FakeBrain {
    let dir: URL
    let binary: URL

    /// `delay` — пауза перед ответом (чтобы успеть наслать вопросов, пока идёт ответ);
    /// `crashOnStart` — процесс умирает сразу после старта.
    init(delay: Double = 0, crashOnStart: Bool = false) throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("suflyor-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        binary = dir.appendingPathComponent("fake-brain")
        let d = dir.path
        let script = """
        #!/bin/bash
        pwd -P > "\(d)/cwd.txt"
        printf '%s\\n' "$@" > "\(d)/args.txt"
        echo launch >> "\(d)/launches.txt"
        \(crashOnStart ? "exit 7" : "")
        echo '{"type":"system","subtype":"init","session_id":"fake"}'
        while IFS= read -r line; do
          printf '%s\\n' "$line" >> "\(d)/received.txt"
          case "$line" in
            *CRASHONCE*) if [ ! -f "\(d)/crashed" ]; then touch "\(d)/crashed"; exit 3; fi ;;
            *CRASH*) exit 3 ;;
            *SLOW*) sleep 1.4 ;;
            *ERRLIMIT*) echo '{"type":"result","subtype":"success","is_error":true,"result":"usage limit reached"}'; continue ;;
            *"Определи тему"*) echo '{"type":"result","subtype":"success","is_error":false,"result":"ТЕМА: Переезд на новые машины\\nС КЕМ: Анна"}'; continue ;;
          esac
          tag=$(printf '%s' "$line" | grep -o 'TAG[0-9]*' | head -1)
          [ -z "$tag" ] && tag=WARM
          sleep \(delay)
          for part in "$tag" "-" "ok"; do
            echo "{\\"type\\":\\"stream_event\\",\\"event\\":{\\"type\\":\\"content_block_delta\\",\\"index\\":0,\\"delta\\":{\\"type\\":\\"text_delta\\",\\"text\\":\\"$part\\"}}}"
          done
          echo 'garbage line'
          echo "{\\"type\\":\\"result\\",\\"subtype\\":\\"success\\",\\"is_error\\":false,\\"result\\":\\"$tag-ok\\"}"
        done
        """
        try script.write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
    }

    func read(_ name: String) -> String {
        (try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)) ?? ""
    }

    var launches: Int { read("launches.txt").split(separator: "\n").count }
    var received: [String] { read("received.txt").split(separator: "\n").map(String.init) }

    func remove() { try? FileManager.default.removeItem(at: dir) }
}

/// Всё, что мозг сообщил наружу; колбэки приходят на своей очереди.
private final class Events: @unchecked Sendable {
    let queue = DispatchQueue(label: "test.brain.events")
    private var _statuses: [Brain.Status] = []
    private var _deltas: [String] = []
    private var _starts: [String] = []
    private var _ends: [(String, String)] = []
    private var _failed: [(String, String)] = []

    func attach(_ b: Brain) {
        b.onStatus = { self._statuses.append($0) }
        b.onDelta = { _, s in self._deltas.append(s) }
        b.onAnswerFailed = { r, why in self._failed.append((r.label, why)) }
        b.onAnswerStart = { self._starts.append($0.label) }
        b.onAnswerEnd = { r, text, _ in self._ends.append((r.label, text)) }
    }

    var statuses: [Brain.Status] { queue.sync { _statuses } }
    var deltas: [String] { queue.sync { _deltas } }
    var starts: [String] { queue.sync { _starts } }
    var ends: [(String, String)] { queue.sync { _ends } }
    var failed: [(String, String)] { queue.sync { _failed } }
}

private func waitFor(_ timeout: Double = 10, _ cond: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if cond() { return true }
        Thread.sleep(forTimeInterval: 0.02)
    }
    return cond()
}

private func makeBrain(_ fake: FakeBrain, brief: Bool = true, tune: (inout Brain.Config) -> Void = { _ in }) -> (Brain, Events) {
    let sys = fake.dir.appendingPathComponent("system.md")
    try? "sys".write(to: sys, atomically: true, encoding: .utf8)
    let ev = Events()
    var cfg = Brain.Config(systemPromptFile: sys,
                           briefFile: brief ? fake.dir.appendingPathComponent("brief.md") : nil,
                           brainBinary: fake.binary.path)
    tune(&cfg)
    let b = Brain(config: cfg, callbackQueue: ev.queue)
    ev.attach(b)
    return (b, ev)
}

@Suite struct BrainProcessTests {
    @Test func warmupIsHiddenAndAnswerStreams() throws {
        let fake = try FakeBrain()
        defer { fake.remove() }
        let (b, ev) = makeBrain(fake)
        b.start()
        #expect(waitFor { ev.statuses.last == .ready })
        #expect(ev.statuses.first == .warming)
        #expect(ev.deltas.isEmpty)          // ответ на прогрев в подсказку не попадает
        #expect(ev.starts.isEmpty)
        #expect(fake.received.first?.contains("Сессия началась. Ответь одним словом: готов") == true)

        b.ask("вопрос TAG1", label: "сколько стоит?")
        #expect(waitFor { ev.ends.count == 1 })
        #expect(ev.starts == ["сколько стоит?"])
        #expect(ev.deltas == ["TAG1", "-", "ok"])
        #expect(ev.ends.first?.0 == "сколько стоит?")
        #expect(ev.ends.first?.1 == "TAG1-ok")
        b.stop(wait: true)
    }

    @Test func argsCwdAndCleanup() throws {
        let fake = try FakeBrain()
        defer { fake.remove() }
        let (b, ev) = makeBrain(fake)
        b.start()
        #expect(waitFor { ev.statuses.last == .ready })
        let args = fake.read("args.txt").components(separatedBy: "\n")
        #expect(args.contains("--strict-mcp-config") && args.contains("--no-session-persistence"))
        let cwd = fake.read("cwd.txt").trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(URL(fileURLWithPath: cwd).lastPathComponent.hasPrefix("suflyor-brain-"))
        #expect(FileManager.default.fileExists(atPath: cwd))
        b.stop(wait: true)
        #expect(!FileManager.default.fileExists(atPath: cwd))   // временная папка мозга удалена
    }

    @Test func noParallelAndNewestWaitingWins() throws {
        let fake = try FakeBrain(delay: 0.4)
        defer { fake.remove() }
        let (b, ev) = makeBrain(fake)
        b.start()
        #expect(waitFor { ev.statuses.last == .ready })
        b.ask("TAG1", label: "1")
        b.ask("TAG2", label: "2")
        b.ask("TAG3", label: "3")
        #expect(waitFor { ev.ends.count == 2 })
        Thread.sleep(forTimeInterval: 0.6)
        #expect(ev.ends.map(\.0) == ["1", "3"])
        // Второй так и не ушёл в процесс; третий отправлен только после конца первого.
        let got = fake.received.dropFirst()
        #expect(got.count == 2)
        #expect(got.first?.contains("TAG1") == true && got.last?.contains("TAG3") == true)
        b.stop(wait: true)
    }

    @Test func oneAutoRestartResendsCrashedQuestionOnce() throws {
        let fake = try FakeBrain()
        defer { fake.remove() }
        let (b, ev) = makeBrain(fake)
        b.start()
        #expect(waitFor { ev.statuses.last == .ready })
        b.ask("CRASHONCE TAG4", label: "упал на нём")
        #expect(waitFor { ev.ends.count == 1 })
        #expect(fake.launches == 2)
        // Тот же вопрос ушёл второй раз — уже в новый процесс, после его прогрева.
        #expect(fake.received.filter { $0.contains("CRASHONCE") }.count == 2)
        #expect(fake.received.filter { $0.contains("Сессия началась") }.count == 2)
        #expect(ev.ends.first?.0 == "упал на нём")
        #expect(ev.ends.first?.1 == "TAG4-ok")
        #expect(ev.statuses.last == .ready)
        b.stop(wait: true)
    }

    @Test func questionThatAlwaysCrashesIsResentOnlyOnce() throws {
        let fake = try FakeBrain()
        defer { fake.remove() }
        let (b, ev) = makeBrain(fake)
        b.start()
        #expect(waitFor { ev.statuses.last == .ready })
        b.ask("CRASH", label: "x")
        #expect(waitFor {
            if case .unavailable(let why)? = ev.statuses.last { return why.contains("код 3") }
            return false
        })
        Thread.sleep(forTimeInterval: 0.3)
        #expect(fake.launches == 2)
        #expect(fake.received.filter { $0.contains("CRASH") }.count == 2)
        #expect(ev.failed.map(\.0) == ["x"])
        b.stop(wait: true)
    }

    /// Зависший ответ: процесс убит и заменён свежим, вопрос не переотправлен, ждущий ушёл в новый процесс.
    @Test func timeoutReplacesProcessAndKeepsWaiting() throws {
        let fake = try FakeBrain()
        defer { fake.remove() }
        let (b, ev) = makeBrain(fake) { $0.answerTimeout = 1.0 }
        b.start()
        #expect(waitFor { ev.statuses.last == .ready })
        b.ask("SLOW TAG1", label: "медленный")
        b.ask("TAG2", label: "следующий")
        #expect(waitFor { ev.statuses.contains(.timedOut) })
        #expect(ev.failed.map(\.0) == ["медленный"])
        #expect(waitFor { ev.ends.count == 1 })
        Thread.sleep(forTimeInterval: 0.3)
        #expect(ev.ends.map(\.0) == ["следующий"])
        #expect(ev.ends.first?.1 == "TAG2-ok")
        #expect(!ev.deltas.contains("TAG1"))
        #expect(ev.statuses.last == .ready)
        #expect(fake.launches == 2)
        // Медленный вопрос в новый процесс не ушёл: он уже устарел.
        #expect(fake.received.filter { $0.contains("SLOW") }.count == 1)
        b.stop(wait: true)
    }

    @Test func prepGoesToBackgroundProcess() throws {
        let fake = try FakeBrain()
        defer { fake.remove() }
        let (b, ev) = makeBrain(fake)
        b.start()
        b.prepare("ПОДГОТОВКА TAG7", label: "шпаргалка")
        #expect(waitFor { ev.ends.count == 1 })
        #expect(ev.ends.first?.0 == "шпаргалка")
        #expect(ev.ends.first?.1 == "TAG7-ok")
        #expect(waitFor { fake.launches == 2 })
        b.stop(wait: true)
    }

    /// Вопрос не ждёт ни шпаргалку, ни тему: они в другом процессе.
    @Test func questionDoesNotWaitForBackground() throws {
        let fake = try FakeBrain(delay: 0.4)
        defer { fake.remove() }
        let (b, ev) = makeBrain(fake)
        b.start()
        #expect(waitFor { ev.statuses.last == .ready })
        b.prepare("ПОДГОТОВКА TAG7", label: "шпаргалка")
        b.detectTopic("тема TAG8")
        Thread.sleep(forTimeInterval: 0.1)
        b.ask("TAG1", label: "1")
        #expect(waitFor { ev.ends.count == 3 })
        // Вопрос ответил одновременно со шпаргалкой (оба по 0.4 с), тема — после шпаргалки.
        #expect(ev.ends.map(\.0).filter { $0 != "1" } == ["шпаргалка", "тема"])
        b.stop(wait: true)
    }

    @Test func secondDeathIsFinal() throws {
        let fake = try FakeBrain(crashOnStart: true)
        defer { fake.remove() }
        let (b, ev) = makeBrain(fake)
        b.start()
        #expect(waitFor {
            if case .unavailable(let why)? = ev.statuses.last { return why.contains("код 7") }
            return false
        })
        Thread.sleep(forTimeInterval: 0.3)
        #expect(fake.launches == 2)   // старт + один авто-перезапуск, дальше — только вручную
        b.ask("TAG1", label: "1")
        Thread.sleep(forTimeInterval: 0.2)
        #expect(fake.launches == 2)
        #expect(ev.starts.isEmpty)
        b.stop(wait: true)
    }

    @Test func errorResultMarksUnavailableButProcessKeepsWorking() throws {
        let fake = try FakeBrain()
        defer { fake.remove() }
        let (b, ev) = makeBrain(fake, brief: false)
        b.start()
        #expect(waitFor { ev.statuses.last == .ready })
        #expect(!fake.read("args.txt").contains("--append-system-prompt-file"))
        b.ask("ERRLIMIT", label: "1")
        #expect(waitFor { ev.statuses.last == .unavailable("usage limit reached") })
        b.ask("TAG2", label: "2")
        #expect(waitFor { ev.ends.count == 1 })
        #expect(ev.statuses.last == .ready)
        #expect(fake.launches == 1)
        b.stop(wait: true)
    }

    @Test func missingBinary() {
        let ev = Events()
        let b = Brain(config: .init(systemPromptFile: URL(fileURLWithPath: "/nonexistent/system.md"), briefFile: nil,
                                    brainBinary: "/nonexistent/brain"), callbackQueue: ev.queue)
        ev.attach(b)
        b.start()
        #expect(waitFor {
            if case .unavailable(let why)? = ev.statuses.last { return why.contains("не найден") }
            return false
        })
        b.stop(wait: true)
    }

    /// Сквозной прогон `--e2e-call` на фейковых whisper и мозге: реплики по порядку, вопросы — мозгу.
    @Test func e2eCallWithFakes() throws {
        let fake = try FakeBrain()
        defer { fake.remove() }
        let (root, sys) = try makeRoot(in: fake.dir)
        let cfg = Brain.Config(systemPromptFile: sys, briefFile: nil, brainBinary: fake.binary.path)

        func sil(_ s: Double) -> [Float] { [Float](repeating: 0, count: Int(s * 16_000)) }
        func tone(_ s: Double) -> [Float] {
            (0..<Int(s * 16_000)).map { Float(0.3 * sin(2 * Double.pi * 440 * Double($0) / 16_000)) }
        }
        // «Они»: вопрос (1.5 с), утверждение (2.5 с), второй вопрос (3.5 с). «Я» — между ними.
        let they = sil(0.5) + tone(1.5) + sil(4) + tone(2.5) + sil(4) + tone(3.5) + sil(2)
        let me = sil(3) + tone(2.5) + sil(13)
        // Фейковый whisper узнаёт фразу по длине куска (VAD добавляет ~0.4 с запаса).
        let transcribe: (Data) -> String? = { wav in
            let sec = Double((wav.count - 44) / 2) / 16_000
            if sec < 2.2 { return "А сколько стоит подключение для нас?" }
            if sec < 3.2 { return "Хорошо, понятно, спасибо большое" }
            return "Когда будет готов переезд на новые машины?"
        }
        // ×10: паузы 4 с по звуку = 0.4 с по часам, дебаунс 0.1 с не склеивает разные вопросы.
        let lines = LockedLines()
        let s = E2ECall.runCore(they: they, me: me, topic: CallTopic(topic: "Статус"), speed: 10,
                                transcribe: transcribe, brainConfig: cfg, projectRoot: root, debounce: 0.1, quietWait: 3,
                                log: { lines.add($0) })
        #expect(s.utterances == 4)
        #expect(s.asked == 2)
        #expect(s.answered == 2)
        #expect(s.firstWord.count == 2)
        let all = lines.all
        #expect(all.contains { $0.contains("шпаргалка: готова") })
        let order = all.filter { $0.hasPrefix("[") }.map { $0.components(separatedBy: "] ").last ?? "" }
        #expect(order == ["ОНИ: А сколько стоит подключение для нас?", "Я: Хорошо, понятно, спасибо большое",
                          "ОНИ: Хорошо, понятно, спасибо большое", "ОНИ: Когда будет готов переезд на новые машины?"])
        // В мозг ушла тема первой строкой.
        #expect(fake.received.contains { $0.contains("ТЕМА: Статус") && $0.contains("переезд") })
    }
}

private final class LockedLines: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func add(_ s: String) { lock.lock(); items.append(s); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return items }
}

/// Prompter на фейковом мозге: своя очередь вместо main, реплики — прямо в store.
/// Своя папка с prompts/system.md: без неё Prompter ищет prompts/ по запасному пути
/// и тест зависел бы от того, что лежит на конкретном маке.
private func makeRoot(in dir: URL) throws -> (root: URL, sys: URL) {
    let root = dir.appendingPathComponent("root")
    try FileManager.default.createDirectory(at: root.appendingPathComponent("prompts"), withIntermediateDirectories: true)
    let sys = root.appendingPathComponent("prompts/system.md")
    try "sys".write(to: sys, atomically: true, encoding: .utf8)
    return (root, sys)
}

private final class PrompterRig {
    let fake: FakeBrain
    let q = DispatchQueue(label: "test.prompter")
    let store = TranscriptStore()
    let model = PanelModel()
    let p: Prompter
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    init() throws {
        fake = try FakeBrain()
        let (root, sys) = try makeRoot(in: fake.dir)
        p = Prompter(mode: .product, store: store, model: model, queue: q)
        p.projectRoot = root
        p.brainConfig = Brain.Config(systemPromptFile: sys, briefFile: nil, brainBinary: fake.binary.path)
        p.debounceDelay = 0.05
        q.sync {
            p.start()
            p.listening = true
        }
    }

    func ready() -> Bool { waitFor { self.q.sync { self.model.brainState == .ready } } }

    /// Реплика на `at` секунде созвона.
    func say(_ c: Channel, _ text: String, at: TimeInterval) {
        let t = store.reserve(c)
        store.fulfill(t, text: text, start: t0.addingTimeInterval(at), end: t0.addingTimeInterval(at + 2))
    }

    func finish() {
        q.sync { p.stop(wait: true) }
        fake.remove()
    }
}

/// Хвост сообщения мозгу после заголовка вопроса: то, на что просят ответить (без контекста).
private func askedPart(_ sent: String) -> String {
    sent.components(separatedBy: "на которую нужен ответ:").dropFirst().joined()
}

@Suite struct PrompterVoiceAndTopicTests {
    @Test func voiceCommandAsksOnTheirLastLine() throws {
        let r = try PrompterRig()
        defer { r.finish() }
        #expect(r.ready())
        var voiced: [Utterance?] = []
        r.q.sync { r.p.onVoiceAsk = { voiced.append($0) } }
        // Не вопрос по эвристике — сам мозг не спросили бы.
        r.say(.they, "Ну вот такие у нас дела с переездом TAG5", at: 0)
        r.say(.me, "Суфлёр, подскажи", at: 3)
        #expect(waitFor { r.fake.received.count == 2 })
        let sent = r.fake.received.last ?? ""
        #expect(sent.contains("TAG5"))
        // Команда — не реплика созвона: ни вопросом, ни в контексте.
        #expect(!sent.lowercased().contains("подскажи"))
        #expect(r.q.sync { voiced.count == 1 && voiced.first??.text.contains("TAG5") == true })
    }

    @Test func voiceCommandWithOwnQuestionAsksIt() throws {
        let r = try PrompterRig()
        defer { r.finish() }
        #expect(r.ready())
        r.say(.they, "Ну вот такие у нас дела с переездом", at: 0)
        r.say(.me, "Суфлёр, какие последние изменения были в релизе?", at: 3)
        #expect(waitFor { r.fake.received.count == 2 })
        let sent = r.fake.received.last ?? ""
        // Вопрос из команды — вопросом, без слова-триггера; реплика собеседника — только контекст.
        #expect(askedPart(sent).contains("Я: какие последние изменения были в релизе"))
        #expect(!sent.lowercased().contains("суфл"))
        #expect(!askedPart(sent).contains("переездом"))
    }

    @Test func voiceCommandFallsBackToMyQuestion() throws {
        let r = try PrompterRig()
        defer { r.finish() }
        #expect(r.ready())
        r.say(.me, "Какие изменения в тарифах TAG7?", at: 0)
        r.say(.me, "Суфлёр, подскажи", at: 3)
        #expect(waitFor { r.fake.received.count == 2 })
        let sent = r.fake.received.last ?? ""
        #expect(askedPart(sent).contains("Я: Какие изменения в тарифах TAG7?"))
        #expect(!sent.lowercased().contains("подскажи"))
    }

    @Test func voiceCommandPrefersFreshTheirs() throws {
        let r = try PrompterRig()
        defer { r.finish() }
        #expect(r.ready())
        r.say(.me, "Какие изменения в тарифах TAG7?", at: 0)
        r.say(.they, "Ну вот такие у нас дела с переездом TAG8", at: 4)
        r.say(.me, "Суфлёр, подскажи", at: 8)
        #expect(waitFor { r.fake.received.count == 2 })
        let sent = r.fake.received.last ?? ""
        #expect(askedPart(sent).contains("ОНИ: Ну вот такие у нас дела с переездом TAG8"))
        #expect(!askedPart(sent).contains("TAG7"))
    }

    @Test func voiceCommandSkipsStaleTheirs() throws {
        let r = try PrompterRig()
        defer { r.finish() }
        #expect(r.ready())
        r.say(.they, "Ну вот такие у нас дела с переездом TAG8", at: 0)
        r.say(.me, "Какие изменения в тарифах TAG7?", at: 100)
        r.say(.me, "Суфлёр, подскажи", at: 103)
        #expect(waitFor { r.fake.received.count == 2 })
        let sent = r.fake.received.last ?? ""
        #expect(askedPart(sent).contains("Я: Какие изменения в тарифах TAG7?"))
        #expect(!askedPart(sent).contains("TAG8"))
    }

    @Test func voiceCommandShowsFlash() throws {
        let r = try PrompterRig()
        defer { r.finish() }
        #expect(r.ready())
        r.say(.me, "Софлер, какие последние изменения были в релизе TAG9", at: 0)
        #expect(waitFor { r.fake.received.count == 2 })
        #expect(r.q.sync { r.model.flash } == "подсказываю…")
        #expect(askedPart(r.fake.received.last ?? "").contains("Я: какие последние изменения были в релизе TAG9"))
    }

    @Test func bareVoiceCommandAsksNothing() throws {
        let r = try PrompterRig()
        defer { r.finish() }
        #expect(r.ready())
        r.say(.me, "Суфлёр, подскажи", at: 0)
        #expect(waitFor { r.q.sync { r.model.flash == "не слышу вопроса" } })
        Thread.sleep(forTimeInterval: 0.3)
        #expect(r.fake.received.count == 1)   // только прогрев
    }

    @Test func plainMeLineAsksNothing() throws {
        let r = try PrompterRig()
        defer { r.finish() }
        #expect(r.ready())
        r.say(.they, "Ну вот такие у нас дела с переездом TAG5", at: 0)
        r.say(.me, "Да, понял, спасибо за информацию", at: 3)
        Thread.sleep(forTimeInterval: 0.4)
        #expect(r.fake.received.count == 1)   // только прогрев
    }

    @Test func topicFromConversationAfterAMinute() throws {
        let r = try PrompterRig()
        defer { r.finish() }
        r.q.sync { r.p.autoTopic = true }
        #expect(r.ready())
        r.say(.they, "Привет, давай начнём с машин", at: 0)
        r.say(.me, "Да, давай про серверы", at: 30)
        Thread.sleep(forTimeInterval: 0.3)
        // Меньше минуты разговора — тему ещё не спрашиваем.
        #expect(!r.fake.received.contains { $0.contains("Определи тему") })
        r.say(.they, "Ну и сроки по переезду обсудим", at: 59)
        #expect(waitFor { r.q.sync { !r.model.topic.isEmpty } })
        #expect(r.q.sync { r.model.topic } == CallTopic(topic: "Переезд на новые машины", with: "Анна"))
        // Шпаргалка по найденной теме пошла в фон, тема — в каждый следующий вопрос.
        #expect(waitFor { r.fake.received.contains { $0.contains("ПОДГОТОВКА К СОЗВОНУ. Тема: Переезд на новые машины") } })
        r.say(.they, "А сколько стоит переезд для нас TAG3?", at: 70)
        #expect(waitFor { r.fake.received.contains { $0.contains("TAG3") } })
        #expect(r.fake.received.last { $0.contains("TAG3") }?.contains("ТЕМА: Переезд на новые машины · С КЕМ: Анна") == true)
        // Одна попытка: тема есть — больше не спрашиваем.
        #expect(r.fake.received.filter { $0.contains("Определи тему") }.count == 1)
    }

    @Test func noAutoTopicWhenGiven() throws {
        let r = try PrompterRig()
        defer { r.finish() }
        r.q.sync {
            r.p.autoTopic = true
            r.p.topic = CallTopic(topic: "Планёрка")
        }
        #expect(r.ready())
        r.say(.they, "Привет, давай начнём с машин", at: 0)
        r.say(.they, "Ну и сроки по переезду обсудим", at: 70)
        Thread.sleep(forTimeInterval: 0.4)
        #expect(!r.fake.received.contains { $0.contains("Определи тему") })
    }
}

@Suite struct PrompterEchoAndDebugLogTests {
    @Test func echoedTriggerIsNotACommand() throws {
        let r = try PrompterRig()
        defer { r.finish() }
        #expect(r.ready())
        var voiced = 0
        r.q.sync { r.p.onVoiceAsk = { _ in voiced += 1 } }
        // Собеседник сам сказал «суфлёр» (не вопрос), микрофон с динамиков повторил.
        r.say(.they, "Ну и суфлёр у вас тут работает TAG3", at: 0)
        r.say(.me, "ну и суфлёр у вас тут работает", at: 0.3)
        Thread.sleep(forTimeInterval: 0.8)
        #expect(r.fake.received.count == 1)
        #expect(r.q.sync { voiced } == 0)
    }

    @Test func echoIsNotInContext() throws {
        let r = try PrompterRig()
        defer { r.finish() }
        #expect(r.ready())
        r.say(.they, "Сколько стоит подключение нового клиента TAG4?", at: 0)
        r.say(.me, "сколько стоит подключение нового клиента", at: 0.3)
        #expect(waitFor { r.fake.received.count == 2 })
        let sent = r.fake.received.last ?? ""
        #expect(sent.contains("ОНИ: Сколько стоит подключение нового клиента TAG4?"))
        // Слова собеседника из динамиков — не слова пользователя.
        #expect(!sent.contains("Я: сколько стоит"))
    }

    @Test func debugLogRecordsSessionFlow() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("suflyor-dbg-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("debug.log")
        let r = try PrompterRig()
        defer { r.finish() }
        let log = DebugLog(enabled: true, url: url)
        r.q.sync { r.p.debugLog = log }
        #expect(r.ready())
        r.say(.they, "Сколько стоит подключение TAG6?", at: 0)
        #expect(waitFor { r.q.sync { r.model.hintSeconds != nil } })
        r.say(.me, "Суфлёр, подскажи", at: 5)
        #expect(waitFor { r.fake.received.count == 3 })
        #expect(waitFor { r.q.sync { r.model.hintSeconds != nil } })
        log.flush()
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        #expect(text.contains("они: Сколько стоит подключение TAG6?"))
        #expect(text.contains("я: Суфлёр, подскажи"))
        #expect(text.contains("вопрос мозгу: Сколько стоит подключение TAG6?"))
        #expect(text.contains("голосом «подскажи», выбран вопрос: Сколько стоит подключение TAG6?"))
        #expect(text.contains("первое слово за"))
        #expect(text.contains("подсказка за"))
        #expect(text.contains("TAG6-ok"))
    }

    @Test func debugLogOffByDefaultInRig() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("suflyor-dbg-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("debug.log")
        let r = try PrompterRig()
        defer { r.finish() }
        r.q.sync { r.p.debugLog = DebugLog(enabled: false, url: url) }
        #expect(r.ready())
        r.say(.they, "Сколько стоит подключение TAG6?", at: 0)
        #expect(waitFor { r.q.sync { r.model.hintSeconds != nil } })
        #expect(!FileManager.default.fileExists(atPath: dir.path))
    }
}
