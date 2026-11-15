import Foundation
import Testing
@testable import SuflyorKit

/// Фейковый мозг с журналом по процессам: каждая строка входа помечена pid, аргументы и окружение —
/// в файл на процесс. Перед каждым result проверяет, не лежит ли в stdin уже следующий запрос:
/// так видно, писали ли в процесс второй вопрос до конца первого. Смотрим число байт в пайпе (FIONREAD),
/// а не готовность к чтению: закрытый stdin тоже «готов», но запроса в нём нет.
private final class PidFake {
    let dir: URL
    let binary: URL

    init(delay: Double = 0) throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("suflyor-rel-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        binary = dir.appendingPathComponent("fake-brain")
        let d = dir.path
        let script = """
        #!/bin/bash
        me=$$
        printf '%s\\n' "$@" > "\(d)/args-$me.txt"
        env > "\(d)/env-$me.txt"
        echo "$me" >> "\(d)/launches.txt"
        avail() { /usr/bin/perl -e '$b=pack(q(L),0); ioctl(STDIN, 0x4004667f, $b) or exit 1; exit(unpack(q(L),$b) > 0 ? 0 : 1)'; }
        echo '{"type":"system","subtype":"init","session_id":"fake"}'
        while IFS= read -r line; do
          printf '%s %s\\n' "$me" "$line" >> "\(d)/received.txt"
          case "$line" in
            *CRASH_A*) if [ ! -f "\(d)/crashed_a" ]; then touch "\(d)/crashed_a"; exit 3; fi ;;
            *CRASH_B*) if [ ! -f "\(d)/crashed_b" ]; then touch "\(d)/crashed_b"; exit 3; fi ;;
            *SLOW*) sleep 1.4 ;;
            *ПОДГОТОВКА*) sleep 2 ;;
            *DASH*) echo '{"type":"result","subtype":"success","is_error":false,"result":"-"}'; continue ;;
          esac
          tag=$(printf '%s' "$line" | grep -o 'TAG[0-9]*' | head -1)
          [ -z "$tag" ] && tag=WARM
          sleep \(delay)
          usage='{"input_tokens":12,"cache_read_input_tokens":3400,"cache_creation_input_tokens":56,"output_tokens":7}'
          case "$line" in *BIGCTX*) usage='{"input_tokens":12,"cache_read_input_tokens":160000,"cache_creation_input_tokens":0,"output_tokens":7}' ;; esac
          for part in "$tag" "-" "ok"; do
            echo "{\\"type\\":\\"stream_event\\",\\"event\\":{\\"type\\":\\"content_block_delta\\",\\"index\\":0,\\"delta\\":{\\"type\\":\\"text_delta\\",\\"text\\":\\"$part\\"}}}"
          done
          if avail; then echo "$me" >> "\(d)/overlap.txt"; fi
          echo "{\\"type\\":\\"result\\",\\"subtype\\":\\"success\\",\\"is_error\\":false,\\"result\\":\\"$tag-ok\\",\\"usage\\":$usage}"
        done
        """
        try script.write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
    }

    func read(_ name: String) -> String {
        (try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)) ?? ""
    }

    var launches: [String] { read("launches.txt").split(separator: "\n").map(String.init) }
    /// (pid, строка входа)
    var received: [(String, String)] {
        read("received.txt").split(separator: "\n").map { l in
            let parts = l.split(separator: " ", maxSplits: 1).map(String.init)
            return (parts[0], parts.count > 1 ? parts[1] : "")
        }
    }
    func pid(of marker: String) -> String? { received.first { $0.1.contains(marker) }?.0 }
    var overlaps: Int { read("overlap.txt").split(separator: "\n").count }
    func args(_ pid: String) -> [String] { read("args-\(pid).txt").components(separatedBy: "\n") }

    func remove() { try? FileManager.default.removeItem(at: dir) }
}

private final class Ev: @unchecked Sendable {
    let queue = DispatchQueue(label: "test.rel.events")
    private var _statuses: [Brain.Status] = []
    private var _ends: [(String, String)] = []
    private var _failed: [(String, String)] = []
    private var _logs: [String] = []

    func attach(_ b: Brain) {
        b.onStatus = { self._statuses.append($0) }
        b.onAnswerFailed = { r, why in self._failed.append((r.label, why)) }
        b.onAnswerEnd = { r, text, _ in self._ends.append((r.label, text)) }
        b.onLog = { self._logs.append($0) }
    }

    var statuses: [Brain.Status] { queue.sync { _statuses } }
    var ends: [(String, String)] { queue.sync { _ends } }
    var failed: [(String, String)] { queue.sync { _failed } }
    var logs: [String] { queue.sync { _logs } }
}

private func waitFor(_ timeout: Double = 10, _ cond: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if cond() { return true }
        Thread.sleep(forTimeInterval: 0.02)
    }
    return cond()
}

private func alive(_ pid: String?) -> Bool {
    guard let pid, let n = Int32(pid) else { return false }
    return kill(n, 0) == 0
}

private func makeBrain(_ fake: PidFake, tune: (inout Brain.Config) -> Void = { _ in }) -> (Brain, Ev) {
    let sys = fake.dir.appendingPathComponent("system.md")
    try? "sys".write(to: sys, atomically: true, encoding: .utf8)
    var cfg = Brain.Config(systemPromptFile: sys, briefFile: nil, brainBinary: fake.binary.path)
    cfg.model = "smart"
    cfg.effort = "low"
    tune(&cfg)
    let ev = Ev()
    let b = Brain(config: cfg, callbackQueue: ev.queue)
    ev.attach(b)
    return (b, ev)
}

@Suite struct BrainTimeoutTests {
    /// Таймаут: зависший процесс убит, поднят новый, устаревший вопрос в него не ушёл, ждущий — ушёл;
    /// в зависший процесс второй запрос не писали.
    @Test func hungProcessIsKilledAndReplaced() throws {
        let fake = try PidFake()
        defer { fake.remove() }
        let (b, ev) = makeBrain(fake) { $0.answerTimeout = 0.5 }
        b.start()
        #expect(waitFor { ev.statuses.last == .ready })
        b.ask("SLOW TAG1", label: "медленный")
        b.ask("TAG2", label: "следующий")
        #expect(waitFor { ev.ends.count == 1 })
        #expect(ev.failed.map(\.0) == ["медленный"])
        #expect(ev.failed.first?.1 == "мозг не ответил")
        #expect(ev.ends.first?.1 == "TAG2-ok")
        let old = fake.pid(of: "SLOW")
        let new = fake.pid(of: "TAG2")
        #expect(old != nil && new != nil && old != new)
        #expect(fake.launches.count == 2)
        #expect(waitFor { !alive(old) })
        #expect(fake.received.filter { $0.1.contains("SLOW") }.count == 1)
        // «Мозг не ответил» держится до готовности замены, без мигания «прогрев…».
        let afterTimeout = ev.statuses.drop { $0 != .timedOut }
        #expect(Array(afterTimeout) == [.timedOut, .ready])
        Thread.sleep(forTimeInterval: 1.2)
        #expect(fake.overlaps == 0)
        b.stop(wait: true)
    }

    /// Строго один запрос в полёте: пока нет result, следующий в stdin не пишется.
    @Test func neverTwoRequestsInFlight() throws {
        let fake = try PidFake(delay: 0.3)
        defer { fake.remove() }
        let (b, ev) = makeBrain(fake)
        b.start()
        b.prepare("ПОДГОТОВКА TAG7")
        for i in 1...6 {
            b.ask("TAG\(i)", label: "\(i)")
            Thread.sleep(forTimeInterval: 0.1)
        }
        #expect(waitFor { ev.ends.contains { $0.0 == "6" } && ev.ends.contains { $0.0 == "шпаргалка" } })
        Thread.sleep(forTimeInterval: 0.3)
        #expect(fake.overlaps == 0)
        b.stop(wait: true)
    }
}

@Suite struct RestartBudgetTests {
    @Test func budgetIsSpentAndReturned() {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        var b = RestartBudget(max: 1, resetAfter: 300, resetAnswers: 3)
        /// Процесс, запущенный на `launched` секунде, упал на `now`.
        func allow(_ launched: Double, _ now: Double) -> Bool {
            b.allow(launchedAt: t0.addingTimeInterval(launched), now: t0.addingTimeInterval(now))
        }
        var got = [allow(0, 1), allow(1, 2)]   // второе падение подряд — уже нет
        // Процесс проработал 5 минут — бюджет вернулся; следующий упал сразу — снова нет.
        got += [allow(2, 302), allow(302, 303)]
        // Три ответа подряд — тоже возвращают.
        b.success(); b.success()
        got.append(allow(303, 304))
        b.success()
        got.append(allow(304, 305))
        #expect(got == [true, false, true, false, false, true])
    }

    /// Упал, ответил три раза, упал снова — снова поднят, а не «мозг недоступен».
    @Test func crashAfterThreeAnswersIsRestartedAgain() throws {
        let fake = try PidFake()
        defer { fake.remove() }
        let (b, ev) = makeBrain(fake)
        b.start()
        #expect(waitFor { ev.statuses.last == .ready })
        b.ask("CRASH_A TAG1", label: "1")
        #expect(waitFor { ev.ends.count == 1 })
        for i in 2...3 {
            b.ask("TAG\(i)", label: "\(i)")
            #expect(waitFor { ev.ends.count == i })
        }
        b.ask("CRASH_B TAG4", label: "4")
        #expect(waitFor { ev.ends.count == 4 })
        #expect(ev.ends.map(\.0) == ["1", "2", "3", "4"])
        #expect(fake.launches.count == 3)
        #expect(!ev.statuses.contains { if case .unavailable = $0 { return true } else { return false } })
        b.stop(wait: true)
    }
}

@Suite struct BrainIsolationTests {
    @Test func argumentsHaveSafeModeEffortAndFallback() {
        let sys = URL(fileURLWithPath: "/x/prompts/system.md")
        let a = BrainLaunch.arguments(model: "smart", effort: "low", fallbackModel: "fast", systemPromptFile: sys, briefFile: nil)
        func value(_ flag: String) -> String? { a.firstIndex(of: flag).map { a[$0 + 1] } }
        #expect(a.contains("--safe-mode"))
        #expect(value("--effort") == "low")
        #expect(value("--fallback-model") == "fast")
        // Запасная модель совпадает с основной — флаг не нужен.
        let bg = BrainLaunch.arguments(model: "fast", effort: nil, fallbackModel: "fast", systemPromptFile: sys, briefFile: nil)
        #expect(!bg.contains("--fallback-model") && !bg.contains("--effort") && bg.contains("--safe-mode"))
    }

    @Test func modelAndEffortFromEnv() {
        #expect(BrainLaunch.model(env: [:]) == "smart")
        #expect(BrainLaunch.model(env: ["SUFLYOR_BRAIN_MODEL": "fast"]) == "fast")
        #expect(BrainLaunch.effort(env: [:]) == "low")
        #expect(BrainLaunch.effort(env: ["SUFLYOR_BRAIN_EFFORT": "high"]) == "high")
        #expect(BrainLaunch.effort(env: ["SUFLYOR_BRAIN_EFFORT": ""]) == nil)
        #expect(BrainLaunch.effort(env: ["SUFLYOR_BRAIN_EFFORT": "default"]) == nil)
    }

    @Test func environmentIsWhitelisted() throws {
        let fake = try PidFake()
        defer { fake.remove() }
        let host = ProcessInfo.processInfo.environment
        let (b, ev) = makeBrain(fake) {
            $0.environment = ["HOME": host["HOME"] ?? "/tmp", "PATH": host["PATH"] ?? "/usr/bin:/bin", "LANG": "ru_RU.UTF-8",
                              "LLM_API_KEY": "nope", "LLM_CONFIG_DIR": "/nope", "LLM_SESSION": "1",
                              "OTHER_APP_SETTING": "nope"]
        }
        b.start()
        #expect(waitFor { ev.statuses.last == .ready })
        let pid = try #require(fake.launches.first)
        let env = fake.read("env-\(pid).txt")
        #expect(env.contains("HOME=") && env.contains("PATH=") && env.contains("LANG=ru_RU.UTF-8"))
        #expect(!env.contains("LLM_") && !env.contains("OTHER_APP_SETTING"))
        let args = fake.args(pid)
        #expect(args.contains("--safe-mode") && args.contains("--effort") && args.contains("--fallback-model"))
        b.stop(wait: true)
    }
}

@Suite struct BrainTwoProcessTests {
    /// Шпаргалка в отдельном процессе на быстрой модели: вопрос во время неё отвечает сразу.
    @Test func questionNeverWaitsForCheatSheet() throws {
        let fake = try PidFake()
        defer { fake.remove() }
        let (b, ev) = makeBrain(fake)
        b.start()
        #expect(waitFor { ev.statuses.last == .ready })
        #expect(fake.launches.count == 1)   // фоновый — только при первой фоновой задаче
        b.prepare("ПОДГОТОВКА TAG7")
        #expect(waitFor { fake.pid(of: "ПОДГОТОВКА") != nil })
        let t = Date()
        b.ask("TAG1", label: "1")
        #expect(waitFor { ev.ends.count >= 1 })
        #expect(ev.ends.first?.0 == "1")
        #expect(Date().timeIntervalSince(t) < 1.5)   // шпаргалка спит 2 с
        #expect(waitFor { ev.ends.count == 2 })
        let main = try #require(fake.pid(of: "TAG1"))
        let bg = try #require(fake.pid(of: "ПОДГОТОВКА"))
        #expect(main != bg)
        func value(_ a: [String], _ flag: String) -> String? { a.firstIndex(of: flag).map { a[$0 + 1] } }
        #expect(value(fake.args(main), "--model") == "smart")
        #expect(value(fake.args(bg), "--model") == "fast")
        #expect(fake.args(bg).contains("--safe-mode"))
        // Фоновый процесс прогревом не тратится: первая же строка — задача.
        #expect(fake.received.first { $0.0 == bg }?.1.contains("ПОДГОТОВКА") == true)
        let pids = (b.pid, b.backgroundPid)
        b.stop(wait: true)
        #expect(!alive(pids.0.map { String($0) }) && !alive(pids.1.map { String($0) }))
    }
}

@Suite struct BrainReplacementTests {
    /// После N ответов — тёплая замена: прогрелась, следующий вопрос уже в новом процессе, старый погашен.
    @Test func replacedAfterAnswers() throws {
        let fake = try PidFake()
        defer { fake.remove() }
        let (b, ev) = makeBrain(fake) { $0.replaceAfterAnswers = 2 }
        b.start()
        #expect(waitFor { ev.statuses.last == .ready })
        b.ask("TAG1", label: "1")
        #expect(waitFor { ev.ends.count == 1 })
        b.ask("TAG2", label: "2")
        #expect(waitFor { ev.ends.count == 2 })
        #expect(waitFor { fake.launches.count == 2 })
        #expect(waitFor { ev.logs.contains { $0.contains("заменён") } })
        b.ask("TAG3", label: "3")
        #expect(waitFor { ev.ends.count == 3 })
        let old = fake.pid(of: "TAG1")
        #expect(fake.pid(of: "TAG2") == old)
        #expect(fake.pid(of: "TAG3") != old)
        #expect(waitFor { !alive(old) })
        // Статус в панели замена не трогает: ни «прогрев…», ни ошибок.
        #expect(ev.statuses == [.warming, .ready])
        b.stop(wait: true)
    }

    /// Большой контекст (с кэшем) — тоже повод заменить; usage с кэшем уходит в журнал.
    @Test func replacedAfterBigContextAndUsageIsLogged() throws {
        let fake = try PidFake()
        defer { fake.remove() }
        let (b, ev) = makeBrain(fake)
        b.start()
        #expect(waitFor { ev.statuses.last == .ready })
        b.ask("TAG1", label: "1")
        #expect(waitFor { ev.ends.count == 1 })
        Thread.sleep(forTimeInterval: 0.2)
        #expect(fake.launches.count == 1)   // маленький контекст — не меняем
        #expect(ev.logs.contains { $0.contains("cache_read 3400") && $0.contains("cache_creation 56") })
        b.ask("BIGCTX TAG2", label: "2")
        #expect(waitFor { ev.ends.count == 2 })
        #expect(waitFor { fake.launches.count == 2 })
        // Переключаемся, только когда замена прогрелась.
        #expect(waitFor { ev.logs.contains { $0.contains("заменён") } })
        b.ask("TAG3", label: "3")
        #expect(waitFor { ev.ends.count == 3 })
        #expect(fake.pid(of: "TAG3") != fake.pid(of: "TAG2"))
        b.stop(wait: true)
    }
}

@Suite struct HintKeepTests {
    @Test func oldHintStaysUntilNewHasText() {
        let m = PanelModel()
        m.beginAnswer(question: "первый")
        m.appendHint("СКАЖИ: Да, 5 штук")
        m.finishAnswer(question: "первый", text: "СКАЖИ: Да, 5 штук", seconds: 2)
        let id = m.answerID
        m.beginAnswer(question: "второй")
        #expect(m.hint == "СКАЖИ: Да, 5 штук")
        #expect(m.hintQuestion == "первый")
        #expect(m.waitingAnswer)
        m.appendHint("СКА")
        m.appendHint("ЖИ: ")
        #expect(m.hint == "СКАЖИ: Да, 5 штук")   // метка без текста — ещё не ответ
        m.appendHint("Не")
        #expect(m.hint == "СКАЖИ: Не")
        #expect(m.hintQuestion == "второй")
        #expect(m.answerID == id + 1)
        m.appendHint("т, позже")
        #expect(m.hint == "СКАЖИ: Нет, позже")
        m.finishAnswer(question: "второй", text: "СКАЖИ: Нет, позже", seconds: 3)
        #expect(m.hintSeconds == 3 && !m.waitingAnswer)
    }

    @Test func dashAnswerKeepsOldHint() {
        let m = PanelModel()
        m.setHint("СКАЖИ: старое")
        m.setHintMeta(question: "старый", seconds: 1)
        m.beginAnswer(question: "новый")
        m.appendHint("-")
        m.finishAnswer(question: "новый", text: "-", seconds: 1.5)
        #expect(m.hint == "СКАЖИ: старое")
        #expect(m.hintQuestion == "старый" && m.hintSeconds == 1)
        #expect(!m.waitingAnswer)
        m.beginAnswer(question: "третий")
        m.appendHint("—")
        m.answerFailed()
        #expect(m.hint == "СКАЖИ: старое" && !m.waitingAnswer)
    }

    /// Ответ без потока (весь текст только в result) всё равно показывается.
    @Test func textOnlyAtEndIsShown() {
        let m = PanelModel()
        m.setHint("СКАЖИ: старое")
        m.beginAnswer(question: "новый")
        m.finishAnswer(question: "новый", text: "СКАЖИ: новое", seconds: 2)
        #expect(m.hint == "СКАЖИ: новое" && m.hintQuestion == "новый")
    }

    /// Через Prompter: «-» от мозга не стирает прошлую подсказку.
    @Test func prompterKeepsHintOnDash() throws {
        let r = try RelRig()
        defer { r.finish() }
        #expect(r.ready())
        r.say(.they, "Сколько стоит подключение TAG1?", at: 0)
        #expect(waitFor { r.q.sync { r.model.hint == "TAG1-ok" && r.model.hintSeconds != nil } })
        r.say(.they, "А вот это DASH к вам вообще относится?", at: 10)
        #expect(waitFor { r.fake.received.contains { $0.1.contains("DASH") } })
        Thread.sleep(forTimeInterval: 0.3)
        #expect(r.q.sync { r.model.hint } == "TAG1-ok")
        #expect(r.q.sync { !r.model.waitingAnswer })
    }
}

@Suite struct QuestionTimingTests {
    @Test func questionMarkAnywhere() {
        // Ни вопросительного слова в начале, ни просьбы: вопрос виден только по «?» в середине.
        #expect(QuestionDetector.isQuestion("Нам к пятнице надо, это реально? Или сдвигаем"))
        #expect(!QuestionDetector.isQuestion("Сколько? Ок"))   // короче 4 слов — как и раньше
    }

    private func u(_ seq: Int, _ text: String) -> Utterance {
        let t = Date(timeIntervalSince1970: 1_000)
        return Utterance(seq: seq, channel: .they, text: text, start: t, end: t)
    }

    @Test func adaptiveDelay() {
        let t0 = Date(timeIntervalSince1970: 5_000)
        let g = QuestionGate()
        let a = u(1, "А сколько стоит подключение для нас?")
        #expect(g.feed(a, now: t0))
        #expect(g.delay(after: a, now: t0) == 0.4)
        let b = u(2, "и ещё для второго бренда")
        #expect(g.feed(b, now: t0.addingTimeInterval(0.3)))
        #expect(g.delay(after: b, now: t0.addingTimeInterval(0.3)) == 1.2)
        // Копится 2.5 с — ждать осталось не больше 0.5 с.
        #expect(abs(g.delay(after: b, now: t0.addingTimeInterval(2.5)) - 0.5) < 0.001)
        #expect(g.delay(after: b, now: t0.addingTimeInterval(3.5)) == 0)
        // Третий кусок — сразу.
        let c = u(3, "и для третьего")
        #expect(g.feed(c, now: t0.addingTimeInterval(0.5)))
        #expect(g.delay(after: c, now: t0.addingTimeInterval(0.5)) == 0)
        #expect(g.fire()?.seqs == [1, 2, 3])
        // Новый вопрос — часы заново.
        #expect(g.feed(u(4, "Когда будет готов переезд на новые машины"), now: t0.addingTimeInterval(10)))
        #expect(g.delay(after: u(4, "Когда будет готов переезд на новые машины"), now: t0.addingTimeInterval(10)) == 1.2)
    }
}

@Suite struct LinkSafetyTests {
    let w = LinkWhitelist(urls: ["https://acme.example.com/pricing?plan=team", "https://jira.example.org/browse/TICKET-1"])

    @Test func rootIsNotDeepened() {
        #expect(w.resolve("https://acme.example.com/") == .rejected)
        #expect(w.resolve("https://acme.example.com") == .rejected)
        #expect(w.resolve("https://acme.example.com/p") == .rejected)
        // Явно оборванная — восстанавливаем.
        #expect(w.resolve("https://acme.example.com/p…") == .allowed("https://acme.example.com/pricing?plan=team"))
        #expect(w.resolve("https://jira.example.org/browse/TICKET") == .allowed("https://jira.example.org/browse/TICKET-1"))
    }

    @Test func allBlocksAreSanitized() {
        let text = """
        СКАЖИ: Гляньте https://evil.example.com/x и https://jira.example.org/browse/TICKET-1.
        ФАКТЫ: отчёт https://acme.example.com/ · 5 чатов
        ЕСЛИ ДОЖМУТ: всё в https://made.up/page
        ССЫЛКА: https://jira.example.org/browse/TICKET-1
        """
        let p = HintParts.parse(text).sanitized(by: w)
        #expect(p.say == "Гляньте ссылка не из брифа и https://jira.example.org/browse/TICKET-1.")
        #expect(p.facts == "отчёт ссылка не из брифа · 5 чатов")
        #expect(p.ifPushed == "всё в ссылка не из брифа")
        #expect(p.url == "https://jira.example.org/browse/TICKET-1")

        let sheet = CheatSheet.parse("""
        ГЛАВНОЕ:
        · дашборд https://evil.example.com/d
        СПРОСЯТ:
        где отчёт? → тут https://made.up/r
        """).sanitized(by: w)
        #expect(sheet.main == ["дашборд ссылка не из брифа"])
        #expect(sheet.asks.first?.answer == "тут ссылка не из брифа")
        #expect(CheatSheet.parse("просто текст https://made.up/x").sanitized(by: w).raw == "просто текст ссылка не из брифа")
        #expect(LinkWhitelist.empty.sanitize("без ссылок") == "без ссылок")
    }
}

@Suite struct ProjectPathsTests {
    @Test func order() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("suflyor-paths-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: base) }
        let res = base.appendingPathComponent("App.app/Contents/Resources")
        let exe = base.appendingPathComponent("App.app/Contents/MacOS/Suflyor")
        let project = base
        for d in [res, project] {
            try fm.createDirectory(at: d.appendingPathComponent("prompts"), withIntermediateDirectories: true)
            try "x".write(to: d.appendingPathComponent("prompts/system.md"), atomically: true, encoding: .utf8)
        }
        try fm.createDirectory(at: exe.deletingLastPathComponent(), withIntermediateDirectories: true)
        let home = base.appendingPathComponent("home")
        #expect(ProjectPaths.root(env: ["SUFLYOR_HOME": home.path], resources: res, executable: exe).path == home.path)
        #expect(ProjectPaths.root(env: [:], resources: res, executable: exe).path == res.path)
        // В ресурсах нет prompts — ищем вверх от бинаря.
        let empty = base.appendingPathComponent("Other.app/Contents/Resources")
        try fm.createDirectory(at: empty, withIntermediateDirectories: true)
        #expect(ProjectPaths.root(env: [:], resources: empty, executable: exe).resolvingSymlinksInPath().path
                == project.resolvingSymlinksInPath().path)
    }
}

/// Prompter на фейковом мозге: своя очередь, свой корень с prompts/ и briefs/.
private final class RelRig {
    let fake: PidFake
    let q = DispatchQueue(label: "test.rel.prompter")
    let store = TranscriptStore()
    let model = PanelModel()
    let p: Prompter
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    init(brief: String? = "бриф https://acme.example.com/pricing?plan=team", unreadableBrief: Bool = false,
         tune: (inout Brain.Config) -> Void = { _ in }, echoWait: TimeInterval = 0.4) throws {
        fake = try PidFake()
        let root = fake.dir.appendingPathComponent("root")
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent("prompts"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("briefs"), withIntermediateDirectories: true)
        let sys = root.appendingPathComponent("prompts/system.md")
        try "sys".write(to: sys, atomically: true, encoding: .utf8)
        if let brief {
            let b = root.appendingPathComponent("briefs/product.md")
            try brief.write(to: b, atomically: true, encoding: .utf8)
            if unreadableBrief { try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: b.path) }
        }
        p = Prompter(mode: .product, store: store, model: model, queue: q)
        p.projectRoot = root
        var cfg = Brain.Config(systemPromptFile: sys, briefFile: nil, brainBinary: fake.binary.path)
        tune(&cfg)
        p.brainConfig = cfg
        p.debounceDelay = 0.05
        p.echoWait = echoWait
        q.sync {
            p.start()
            p.listening = true
        }
    }

    func ready() -> Bool { waitFor { self.q.sync { self.model.brainState == .ready } } }

    func say(_ c: Channel, _ text: String, at: TimeInterval) {
        let t = store.reserve(c)
        store.fulfill(t, text: text, start: t0.addingTimeInterval(at), end: t0.addingTimeInterval(at + 2))
    }

    func finish() {
        q.sync { p.stop(wait: true) }
        let b = fake.dir.appendingPathComponent("root/briefs/product.md")
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: b.path)
        fake.remove()
    }
}

@Suite struct PrompterReliabilityTests {
    /// Перезапуск мозга по таймауту не трогает транскрипт, тему и шпаргалку.
    @Test func restartKeepsSessionState() throws {
        let r = try RelRig(tune: { $0.answerTimeout = 0.5 })
        defer { r.finish() }
        #expect(r.ready())
        r.q.sync {
            r.p.useTopic(CallTopic(topic: "Переезд", with: "Анна"))
        }
        #expect(waitFor { r.q.sync { r.model.cheatState == .ready } })
        var failed: [String] = []
        r.q.sync { r.p.onEvent = { if case .failed(_, let why) = $0 { failed.append(why) } } }
        r.say(.they, "Сколько стоит SLOW подключение TAG1?", at: 0)
        // «Мозг не ответил» держится, пока свежий процесс прогревается (у фейка — миг), поэтому ждём по факту.
        #expect(waitFor { r.q.sync { failed } == ["мозг не ответил"] })
        #expect(waitFor { r.fake.launches.count == 3 })   // основной, фоновый, замена основного
        #expect(waitFor { r.q.sync { r.model.brainState == .ready } })
        #expect(r.q.sync { r.model.topic.topic } == "Переезд")
        #expect(r.q.sync { r.model.cheatState } == .ready)
        #expect(r.q.sync { !r.model.cheatText.isEmpty })
        #expect(r.store.utterances.count == 1)
        // Следующий вопрос идёт в новый процесс с темой (через 3 мин: медленный уже не в контексте).
        r.say(.they, "А когда будет готов переезд TAG2?", at: 200)
        #expect(waitFor { r.q.sync { r.model.hint == "TAG2-ok" } })
        #expect(r.fake.received.last { $0.1.contains("TAG2") }?.1.contains("ТЕМА: Переезд") == true)
    }

    /// «Подскажи» в микрофоне раньше, чем та же фраза пришла от собеседника: это эхо, не команда.
    @Test func lateTheirLineTurnsCommandIntoEcho() throws {
        let r = try RelRig()
        defer { r.finish() }
        #expect(r.ready())
        var voiced = 0
        r.q.sync { r.p.onVoiceAsk = { _ in voiced += 1 } }
        r.say(.me, "ну подскажи как у вас тут с отчётами", at: 0)
        Thread.sleep(forTimeInterval: 0.15)
        // Пока не ясно, эхо ли это, — «слышу…».
        #expect(r.q.sync { r.model.flash } == "слышу…")
        r.say(.they, "Ну подскажи, как у вас тут с отчётами TAG3?", at: 0.2)
        // Вопрос собеседника уходит обычным порядком, один раз.
        #expect(waitFor { r.fake.received.contains { $0.1.contains("TAG3") } })
        Thread.sleep(forTimeInterval: 0.8)
        #expect(r.q.sync { voiced } == 0)
        #expect(r.fake.received.filter { $0.1.contains("TAG3") }.count == 1)
        #expect(r.q.sync { r.model.flash } != "подсказываю…")
        // Эхо — «слышу…» снимается сразу, а не висит до таймера надписи.
        #expect(r.q.sync { r.model.flash } == nil)
    }

    /// Команда «подскажи»: сразу «слышу…», после проверки на эхо — «подсказываю…».
    @Test func voiceCommandFlashesHearingThenAnswering() throws {
        let r = try RelRig(echoWait: 0.6)
        defer { r.finish() }
        #expect(r.ready())
        r.say(.me, "Суфлёр, сколько стоит подключение TAG5", at: 0)
        #expect(waitFor { r.q.sync { r.model.flash == "слышу…" } })
        #expect(!r.fake.received.contains { $0.1.contains("TAG5") })
        #expect(waitFor { r.q.sync { r.model.flash == "подсказываю…" } })
        #expect(waitFor { r.fake.received.contains { $0.1.contains("TAG5") } })
    }

    /// Нечитаемый бриф: ошибка в панели, мозгу его не отдаём.
    @Test func unreadableBriefIsShown() throws {
        let r = try RelRig(unreadableBrief: true)
        defer { r.finish() }
        #expect(r.ready())
        #expect(r.q.sync { r.model.errors.contains { $0.contains("не читается") } })
        let pid = try #require(r.fake.launches.first)
        #expect(!r.fake.args(pid).contains("--append-system-prompt-file"))
    }
}
