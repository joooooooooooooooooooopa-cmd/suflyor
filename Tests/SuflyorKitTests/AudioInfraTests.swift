import AVFoundation
import Foundation
import Testing
@testable import SuflyorKit

/// Надёжность звука и whisper на живом созвоне: часы каналов, буфер до готовности whisper,
/// перезапуск whisper, микрофон после AirPods, сироты прошлых запусков. Без GUI и без настоящего звука.

private func waitFor(_ timeout: Double = 5, _ cond: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if cond() { return true }
        Thread.sleep(forTimeInterval: 0.01)
    }
    return cond()
}

private final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var v: T
    init(_ v: T) { self.v = v }
    var value: T { lock.lock(); defer { lock.unlock() }; return v }
    func update(_ f: (inout T) -> Void) { lock.lock(); f(&v); lock.unlock() }
}

private let sr = 16_000.0

/// Тон 300 Гц: VAD видит речь, whisper в тестах фейковый.
private func tone(_ seconds: Double) -> [Float] {
    (0..<Int(seconds * sr)).map { Float(0.3 * sin(2 * Double.pi * 300 * Double($0) / sr)) }
}

private func silence(_ seconds: Double) -> [Float] { [Float](repeating: 0, count: Int(seconds * sr)) }

/// Фейковый whisper: отдаёт разные фразы по порядку (одинаковые JunkFilter счёл бы повтором).
private func fakeWhisper(_ calls: Box<Int>) -> (Data) -> String? {
    let words = ["первая фраза", "вторая реплика", "третий вопрос", "четвёртый ответ", "пятая мысль"]
    return { _ in
        var n = 0
        calls.update { $0 += 1; n = $0 }
        return words[(n - 1) % words.count]
    }
}

@Suite struct ChannelClockTests {
    private let t0 = Date(timeIntervalSince1970: 2_000_000)

    @Test func gapInStreamDoesNotShiftTime() {
        let store = TranscriptStore()
        let calls = Box(0)
        let tr = Transcriber(store: store, maxConcurrent: 1, transcribe: fakeWhisper(calls))
        let pipe = ChannelPipeline(channel: .they, transcriber: tr)
        let burst = silence(0.5) + tone(1) + silence(1)   // 2.5 с; фраза ≈ 0.3…1.7 с от начала пачки
        pipe.feed(burst, at: t0.addingTimeInterval(2.5))
        // Разрыв 100 с: мак спал / SCK перезапускался — сэмплов за это время не было.
        pipe.feed(burst, at: t0.addingTimeInterval(102.5))
        pipe.flush()
        tr.waitUntilIdle()

        let u = store.utterances
        #expect(u.count == 2)
        guard u.count == 2 else { return }
        #expect(abs(u[0].end.timeIntervalSince(t0) - 1.7) < 0.1, "конец первой: \(u[0].end.timeIntervalSince(t0))")
        // По счёту сэмплов вышло бы ≈ 4.2 с — каналы разъехались бы на 100 с.
        #expect(abs(u[1].end.timeIntervalSince(t0) - 101.7) < 0.1, "конец второй: \(u[1].end.timeIntervalSince(t0))")
        #expect(abs(u[1].end.timeIntervalSince(u[1].start) - 1.4) < 0.1)
    }

    @Test func soundIsHeldUntilWhisperIsReadyAndCappedAt10s() {
        let store = TranscriptStore()
        let calls = Box(0)
        let tr = Transcriber(store: store, maxConcurrent: 1, transcribe: fakeWhisper(calls))
        let pipe = ChannelPipeline(channel: .me, transcriber: tr, open: false)
        // 15 с по 0.5 с: речь в самом начале (её буфер вытеснит) и в конце (её дождёмся).
        let audio = tone(1) + silence(12) + tone(1) + silence(1)
        let chunk = Int(0.5 * sr)
        var i = 0
        while i < audio.count {
            let end = min(i + chunk, audio.count)
            pipe.feed(Array(audio[i..<end]), at: t0.addingTimeInterval(Double(end) / sr))
            i = end
        }
        pipe.flush()  // заодно барьер: всё поданное уже разложено
        tr.waitUntilIdle()
        #expect(calls.value == 0)  // whisper не готов — в расшифровку ничего не ушло

        pipe.open()
        pipe.flush()
        tr.waitUntilIdle()
        #expect(calls.value == 1)
        let u = store.utterances
        #expect(u.count == 1)
        // Это поздняя фраза (13…14 с), и время у неё своё, а не «с момента открытия».
        if let last = u.last { #expect(abs(last.end.timeIntervalSince(t0) - 14.2) < 0.1) }
    }

    @Test func pauseHoldsSoundUntilReopen() {
        let store = TranscriptStore()
        let calls = Box(0)
        let tr = Transcriber(store: store, maxConcurrent: 1, transcribe: fakeWhisper(calls))
        let pipe = ChannelPipeline(channel: .they, transcriber: tr)
        pipe.pause()
        pipe.feed(tone(1) + silence(1), at: t0)
        pipe.flush()
        tr.waitUntilIdle()
        #expect(calls.value == 0)
        pipe.open()
        pipe.flush()
        tr.waitUntilIdle()
        #expect(calls.value == 1)
    }
}

@Suite struct TranscriberBackendTests {
    private let t0 = Date(timeIntervalSince1970: 1_000)

    private func seg(_ n: Int = 100) -> SpeechSegment {
        SpeechSegment(samples: [Float](repeating: 0.1, count: n), startTime: 0, endTime: 0.5)
    }

    @Test func threeFailuresInRowReportOnce() {
        let store = TranscriptStore()
        let tr = Transcriber(store: store, maxConcurrent: 1) { _ in nil }
        let reports = Box(0)
        tr.onBackendFailure = { reports.update { $0 += 1 } }
        for _ in 0..<2 { tr.submit(seg(), channel: .they, streamStart: t0) }
        tr.waitUntilIdle()
        #expect(reports.value == 0)
        for _ in 0..<4 { tr.submit(seg(), channel: .they, streamStart: t0) }
        tr.waitUntilIdle()
        #expect(reports.value == 1)  // один сигнал, а не на каждый следующий провал
        // Перезапустили whisper — новый бэкенд со своим счётом.
        tr.setBackend { _ in nil }
        for _ in 0..<3 { tr.submit(seg(), channel: .me, streamStart: t0) }
        tr.waitUntilIdle()
        #expect(reports.value == 2)
    }

    @Test func successResetsCounterAndNoBackendIsNotFailure() {
        let store = TranscriptStore()
        let answers = Box([String?]([nil, nil, "есть ответ", nil, nil]))
        let tr = Transcriber(store: store, maxConcurrent: 1) { _ in
            var a: String?
            answers.update { a = $0.removeFirst() }
            return a
        }
        let reports = Box(0)
        tr.onBackendFailure = { reports.update { $0 += 1 } }
        for _ in 0..<5 { tr.submit(seg(), channel: .they, streamStart: t0) }
        tr.waitUntilIdle()
        #expect(reports.value == 0)
        // whisper снят (перезапуск): фразы освобождают брони, но сбоем не считаются.
        tr.setBackend(nil)
        for _ in 0..<5 { tr.submit(seg(), channel: .they, streamStart: t0) }
        tr.waitUntilIdle()
        #expect(reports.value == 0)
    }

    @Test func theyChannelGoesFirst() {
        let store = TranscriptStore()
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let order = Box([Int]())
        let tr = Transcriber(store: store, maxConcurrent: 1) { wav in
            order.update { $0.append(wav.count) }
            if order.value.count == 1 { started.signal(); release.wait() }
            return "текст \(wav.count)"
        }
        // Размер WAV различает запросы: длины больше минимальной, без добивки тишиной.
        let base = Transcriber.minSamples
        tr.submit(seg(base + 10), channel: .me, streamStart: t0)
        started.wait()
        tr.submit(seg(base + 20), channel: .me, streamStart: t0)
        tr.submit(seg(base + 30), channel: .me, streamStart: t0)
        tr.submit(seg(base + 40), channel: .they, streamStart: t0)
        release.signal()
        tr.waitUntilIdle()
        let size = { (n: Int) in WAV.encode(samples: [Float](repeating: 0, count: n)).count }
        #expect(order.value.count == 4)
        // Монолог «я» в очереди не задерживает вопрос собеседника.
        #expect(order.value.dropFirst().first == size(base + 40))
    }
}

/// Фейковый вход: первые `notReady` запусков — формат 0 Гц (AirPods ещё поднимаются).
private final class SettlingMic: MicSource {
    var onConfigurationChange: (() -> Void)?
    private(set) var started = false
    private(set) var stopped = false
    let notReady: Bool
    init(notReady: Bool) { self.notReady = notReady }
    func start(onBuffer: @escaping (AVAudioPCMBuffer) -> Void) throws {
        if notReady { throw CaptureError.micNotReady }
        started = true
    }
    func stop() { stopped = true }
}

private final class SettlingFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var made: [SettlingMic] = []
    var notReady = 0
    func make() -> MicSource {
        lock.lock(); defer { lock.unlock() }
        let nr = notReady > 0
        if nr { notReady -= 1 }
        let m = SettlingMic(notReady: nr)
        made.append(m)
        return m
    }
    var all: [SettlingMic] { lock.lock(); defer { lock.unlock() }; return made }
    var live: [SettlingMic] { all.filter { $0.started && !$0.stopped } }
}

@Suite struct MicSettleTests {
    @Test func burstOfChangesRestartsOnceAfterSettle() throws {
        let f = SettlingFactory()
        let mic = MicCapture(onSamples: { _ in }, makeSource: f.make)
        mic.settleDelay = 0.3
        try mic.start()
        // AirPods: несколько смен конфигурации подряд.
        for _ in 0..<3 {
            f.all[0].onConfigurationChange?()
            Thread.sleep(forTimeInterval: 0.05)
        }
        // Пока устройство не успокоилось — старый источник не трогаем и новый не создаём.
        #expect(f.all.count == 1)
        #expect(waitFor { f.all.count == 2 && f.live.count == 1 })
        Thread.sleep(forTimeInterval: 0.4)
        #expect(f.all.count == 2)
        mic.stop()
        #expect(f.live.isEmpty)
    }

    @Test func notReadyFormatIsRetriedNotThrown() throws {
        let f = SettlingFactory()
        f.notReady = 2
        let mic = MicCapture(onSamples: { _ in }, makeSource: f.make)
        mic.retryDelay = 0.02
        try mic.start()  // 0 Гц на старте — не ошибка, а «подожди»
        #expect(waitFor { f.all.count == 3 && f.live.count == 1 })
        mic.stop()
    }

    @Test func stopCancelsPendingSettle() throws {
        let f = SettlingFactory()
        let mic = MicCapture(onSamples: { _ in }, makeSource: f.make)
        mic.settleDelay = 0.2
        try mic.start()
        f.all[0].onConfigurationChange?()
        Thread.sleep(forTimeInterval: 0.05)
        mic.stop()
        Thread.sleep(forTimeInterval: 0.4)
        #expect(f.all.count == 1)
    }
}

@Suite struct RetryBudgetTests {
    private let t0 = Date(timeIntervalSince1970: 0)

    @Test func runsOutOnQuickFailures() {
        var b = RetryBudget(max: 3, stableAfter: 60)
        for i in 0..<3 {
            b.started(at: t0.addingTimeInterval(Double(i) * 10))
            let ok = b.failed(at: t0.addingTimeInterval(Double(i) * 10 + 5))
            #expect(ok)
        }
        b.started(at: t0.addingTimeInterval(40))
        let ok = b.failed(at: t0.addingTimeInterval(45))
        #expect(!ok)
    }

    @Test func refillsAfterMinuteOfStableStream() {
        var b = RetryBudget(max: 3, stableAfter: 60)
        for i in 0..<3 {
            b.started(at: t0.addingTimeInterval(Double(i) * 10))
            _ = b.failed(at: t0.addingTimeInterval(Double(i) * 10 + 5))
        }
        #expect(b.left == 0)
        // Последний перезапуск прожил минуту — обрыв через час снова можно чинить.
        b.started(at: t0.addingTimeInterval(100))
        let ok = b.failed(at: t0.addingTimeInterval(3_700))
        #expect(ok)
        #expect(b.left == 2)
    }
}

@Suite struct ChordPointerTests {
    private typealias M = ChordDetector.Mods

    @Test func clickWithChordHeldSpoilsIt() {
        var d = ChordDetector()
        let t = Date()
        _ = d.flags([.control], at: t)
        _ = d.flags(M.chord, at: t)
        d.pointer()  // ⌃⌥⌘+клик/перетаскивание окна
        let fired = d.flags([], at: t.addingTimeInterval(0.3))
        #expect(!fired)
        // Следующий чистый аккорд снова работает.
        _ = d.flags(M.chord, at: t.addingTimeInterval(1))
        let again = d.flags([], at: t.addingTimeInterval(1.2))
        #expect(again)
    }

    @Test func clickWithoutModifiersIsHarmless() {
        var d = ChordDetector()
        let t = Date()
        d.pointer()
        _ = d.flags(M.chord, at: t)
        let fired = d.flags([], at: t.addingTimeInterval(0.2))
        #expect(fired)
    }
}

@Suite struct SingleInstanceTests {
    @Test func secondLaunchForwardsOrQuits() {
        #expect(SuflyorApp.launchDecision(args: ["/x/Suflyor"], otherRunning: false) == .run)
        #expect(SuflyorApp.launchDecision(args: ["/x/Suflyor", "--start-session"], otherRunning: false) == .run)
        #expect(SuflyorApp.launchDecision(args: ["/x/Suflyor", "--start-session"], otherRunning: true) == .forwardStart)
        #expect(SuflyorApp.launchDecision(args: ["/x/Suflyor"], otherRunning: true) == .quit)
    }
}

@Suite struct DebugLogSessionTests {
    @Test func startOverEmptiesFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("suflyor-infra-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("debug.log")
        let log = DebugLog(enabled: true, url: url)
        log.log("прошлый созвон")
        log.flush()
        log.startOver()
        log.log("новая сессия")
        log.flush()
        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
        #expect(lines.count == 1)
        #expect(lines.first?.hasSuffix("новая сессия") == true)
        #expect((try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    /// Флаг журнала читается на сессию, а не на процесс: включил между созвонами — пишет, выключил — молчит.
    @Test func reloadTogglesBetweenSessions() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("suflyor-infra-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: dir) }
        let url = dir.appendingPathComponent("debug.log")
        let log = DebugLog(enabled: false, url: url)
        log.log("до включения")
        log.flush()
        #expect(!fm.fileExists(atPath: url.path))
        log.reload(enabled: true)
        log.startOver()
        log.log("сессия с журналом")
        log.flush()
        log.reload(enabled: false)
        log.log("сессия без журнала")
        log.flush()
        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
        #expect(lines.count == 1)
        #expect(lines.first?.hasSuffix("сессия с журналом") == true)
        // Заглушку для тестов и --e2e-call включить нельзя.
        DebugLog.off.reload(enabled: true)
        #expect(!DebugLog.off.enabled)
    }
}

@Suite struct StartupCleanupTests {
    private let model = "/Users/user/Library/Application Support/Suflyor/ggml-small.bin"

    @Test func onlyOurOrphanedWhisperIsPicked() {
        let ps = """
          101     1 /opt/homebrew/bin/whisper-server --model \(model) --host 127.0.0.1 --port 5555 --language ru
          102   500 /opt/homebrew/bin/whisper-server --model \(model) --host 127.0.0.1 --port 5556
          103     1 /opt/homebrew/bin/whisper-server --model /other/model.bin --host 127.0.0.1 --port 5557
          104     1 /opt/homebrew/bin/whisper-server --model \(model) --host 0.0.0.0 --port 5558
          105     1 /usr/bin/python3 /tmp/x.py whisper-server --model \(model) --host 127.0.0.1
          106     1 /opt/homebrew/bin/whisper-server --model \(model).bak --host 127.0.0.1 --port 5559
          107     1 /opt/homebrew/bin/whisper-server --host 127.0.0.1 --model \(model)
        """
        #expect(StartupCleanup.orphanWhisperPIDs(ps: ps, model: model) == [101, 107])
    }

    @Test func staleBrainDirsOnlyOldAndOurs() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("suflyor-infra-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let now = Date()
        let old = now.addingTimeInterval(-2 * 3_600)
        func dir(_ name: String, _ date: Date) throws {
            let u = root.appendingPathComponent(name)
            try fm.createDirectory(at: u, withIntermediateDirectories: true)
            try fm.setAttributes([.modificationDate: date], ofItemAtPath: u.path)
        }
        try dir("suflyor-brain-old", old)
        try dir("suflyor-brain-fresh", now)
        try dir("other-old", old)
        let file = root.appendingPathComponent("suflyor-brain-file")
        fm.createFile(atPath: file.path, contents: Data())
        try fm.setAttributes([.modificationDate: old], ofItemAtPath: file.path)
        let got = StartupCleanup.staleBrainDirs(in: root, now: now).map(\.lastPathComponent)
        #expect(got == ["suflyor-brain-old"])
    }
}

/// whisper-server подменён скриптом с python http.server: так проверяются запуск, гонка start/stop
/// и сигнал о падении без модели в 0.5 ГБ.
@Suite(.serialized) struct WhisperServerLifecycleTests {
    private struct Rig {
        let dir: URL
        let server: WhisperServer
        var pidFile: URL { dir.appendingPathComponent("pid") }
        var pid: pid_t? {
            (try? String(contentsOf: pidFile, encoding: .utf8)).flatMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        }
        func cleanup() {
            server.stop()
            if let p = pid { kill(p, SIGKILL) }
            try? FileManager.default.removeItem(at: dir)
        }
    }

    private func rig() throws -> Rig {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("suflyor-fakewhisper-\(UUID().uuidString)")
        try fm.createDirectory(at: dir.appendingPathComponent("www"), withIntermediateDirectories: true)
        let script = dir.appendingPathComponent("whisper-server")
        try """
        #!/bin/sh
        d="$(dirname "$0")"
        echo $$ > "$d/pid"
        port=""
        while [ $# -gt 0 ]; do [ "$1" = "--port" ] && port="$2"; shift; done
        exec /usr/bin/python3 -m http.server "$port" --bind 127.0.0.1 --directory "$d/www"
        """.write(to: script, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let model = dir.appendingPathComponent("model.bin")
        fm.createFile(atPath: model.path, contents: Data([0]))
        var c = WhisperServer.Config()
        c.binary = script.path
        c.model = model.path
        return Rig(dir: dir, server: WhisperServer(config: c))
    }

    private func alive(_ pid: pid_t?) -> Bool {
        guard let pid else { return false }
        return kill(pid, 0) == 0
    }

    @Test func argumentsDisableFallbackAndBestOf() throws {
        let args = WhisperServer().arguments(port: 1234)
        #expect(args.contains("-nf"))
        let i = try #require(args.firstIndex(of: "-bo"))
        #expect(args[i + 1] == "1")
        #expect(args.contains("127.0.0.1"))
    }

    @Test func crashIsReportedButOwnStopIsNot() throws {
        let r = try rig()
        defer { r.cleanup() }
        let exits = Box(0)
        r.server.onExit = { _ in exits.update { $0 += 1 } }
        try r.server.start()
        let pid = try #require(r.pid)
        kill(pid, SIGKILL)  // whisper упал посреди созвона
        #expect(waitFor { exits.value == 1 })

        let r2 = try rig()
        defer { r2.cleanup() }
        let exits2 = Box(0)
        r2.server.onExit = { _ in exits2.update { $0 += 1 } }
        try r2.server.start()
        let pid2 = r2.pid
        r2.server.stop()
        Thread.sleep(forTimeInterval: 0.3)
        #expect(exits2.value == 0)
        #expect(!alive(pid2))
    }

    @Test func stopBeforeStartLeavesNoProcess() throws {
        let r = try rig()
        defer { r.cleanup() }
        r.server.stop()  // сессию закрыли раньше, чем фоновый старт дошёл до run()
        #expect(throws: WhisperServer.Failure.self) { try r.server.start() }
        Thread.sleep(forTimeInterval: 0.3)
        #expect(r.pid == nil)
    }

    @Test func stopDuringStartLeavesNoProcess() throws {
        let r = try rig()
        defer { r.cleanup() }
        let threw = Box<Bool?>(nil)
        let t = Thread {
            do { try r.server.start(); threw.update { $0 = false } } catch { threw.update { $0 = true } }
        }
        t.start()
        _ = waitFor(2) { r.pid != nil }
        r.server.stop()
        #expect(waitFor(10) { threw.value != nil })
        #expect(threw.value == true)
        Thread.sleep(forTimeInterval: 0.3)
        #expect(!alive(r.pid))
    }
}
