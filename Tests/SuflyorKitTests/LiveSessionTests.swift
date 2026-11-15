import AVFoundation
import Foundation
import Testing
@testable import SuflyorKit

/// Временный каталог теста; удаляется в конце (временные файлы за собой не оставляем).
private func tempDir() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("suflyor-live-\(UUID().uuidString)")
}

private func perms(_ url: URL) -> Int? {
    (try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue
}

@Suite struct DebugLogTests {
    @Test func disabledWritesNothing() {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("Logs/debug.log")
        let log = DebugLog(enabled: false, url: url)
        log.log("они: секретный разговор")
        log.flush()
        // Ни файла, ни каталога: по умолчанию на диск не уходит ни слова.
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(!FileManager.default.fileExists(atPath: dir.path))
    }

    @Test func enabledAppendsWithPrivatePermissions() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("Logs/debug.log")
        let log = DebugLog(enabled: true, url: url)
        log.log("я: первая")
        log.log("они: вторая")
        log.flush()
        let text = try String(contentsOf: url, encoding: .utf8)
        let lines = text.split(separator: "\n")
        #expect(lines.count == 2)
        #expect(lines[0].hasSuffix("я: первая"))
        #expect(lines[1].hasSuffix("они: вторая"))
        // Время в начале строки: «2026-10-27 12:00:00.123 …».
        #expect(lines[0].range(of: #"^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3} "#, options: .regularExpression) != nil)
        #expect(perms(url) == 0o600)
        #expect(perms(url.deletingLastPathComponent()) == 0o700)

        // Второй журнал на тот же файл дописывает, а не затирает (перезапуск после выдачи доступа).
        let again = DebugLog(enabled: true, url: url)
        again.log("я: третья")
        again.flush()
        #expect(try String(contentsOf: url, encoding: .utf8).split(separator: "\n").count == 3)
    }

    @Test func defaultPathIsUserLogs() {
        #expect(DebugLog.defaultURL.path.hasSuffix("/Library/Logs/Suflyor/debug.log"))
    }
}

@Suite struct LevelMeterTests {
    @Test func rmsInDbfsAndReset() {
        let m = LevelMeter()
        m.feed([Float](repeating: 0.5, count: 160))
        m.feed([Float](repeating: -0.5, count: 160))
        let s = m.take()
        #expect(s.buffers == 2)
        // RMS 0.5 → 20·log10(0.5) ≈ −6.02 dBFS.
        #expect(abs((s.dbfs ?? 0) + 6.0206) < 0.01)
        #expect(LevelMeter.describe(s) == "-6.0 dBFS, 2 буф")
        // Окно обнулилось: буферов нет — так и пишем, это и есть «звук не идёт».
        let empty = m.take()
        #expect(empty.dbfs == nil && empty.buffers == 0)
        #expect(LevelMeter.describe(empty) == "нет звука, 0 буф")
    }

    @Test func digitalSilence() {
        let m = LevelMeter()
        m.feed([Float](repeating: 0, count: 320))
        #expect(LevelMeter.describe(m.take()) == "тишина 0, 1 буф")
    }
}

@Suite struct EchoTests {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func u(_ seq: Int, _ c: Channel, _ text: String, at: TimeInterval, len: TimeInterval = 2) -> Utterance {
        Utterance(seq: seq, channel: c, text: text, start: t0.addingTimeInterval(at), end: t0.addingTimeInterval(at + len))
    }

    @Test func micRepeatingSpeakerIsEcho() {
        let they = u(0, .they, "Сколько стоит подключение нового клиента?", at: 0)
        // Тихое эхо whisper пишет хуже: другие окончания, потерянное слово.
        let echo = u(1, .me, "сколько стоят подключения клиента", at: 0.4)
        #expect(Echo.isEcho(echo, in: [they, echo]))
    }

    @Test func ownWordsAreNotEcho() {
        let they = u(0, .they, "Сколько стоит подключение нового клиента?", at: 0)
        let mine = u(1, .me, "Двадцать тысяч в месяц, без комиссии", at: 2.5)
        #expect(!Echo.isEcho(mine, in: [they, mine]))
    }

    @Test func repeatingQuestionLaterIsNotEcho() {
        // Пользователь переспросил своими словами через полминуты — это его реплика.
        let they = u(0, .they, "Сколько стоит подключение нового клиента?", at: 0)
        let mine = u(1, .me, "Сколько стоит подключение нового клиента?", at: 30)
        #expect(!Echo.isEcho(mine, in: [they, mine]))
    }

    @Test func theyChannelIsNeverEcho() {
        let they = u(0, .they, "Сколько стоит подключение?", at: 0)
        #expect(!Echo.isEcho(they, in: [they]))
    }
}

/// Фейковый микрофон: ничего не слышит, только считает запуски и позволяет «сменить устройство».
private final class FakeMic: MicSource {
    var onConfigurationChange: (() -> Void)?
    private(set) var started = false
    private(set) var stopped = false
    let fail: Bool
    init(fail: Bool) { self.fail = fail }
    func start(onBuffer: @escaping (AVAudioPCMBuffer) -> Void) throws {
        if fail { throw CaptureError.other("нет устройства") }
        started = true
    }
    func stop() { stopped = true }
}

/// Раздаёт фейки по порядку; `failures` — сколько следующих запусков упадут (устройство ещё не появилось).
private final class MicFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var made: [FakeMic] = []
    var failures = 0
    func make() -> MicSource {
        lock.lock(); defer { lock.unlock() }
        let fail = failures > 0
        if fail { failures -= 1 }
        let m = FakeMic(fail: fail)
        made.append(m)
        return m
    }
    var all: [FakeMic] { lock.lock(); defer { lock.unlock() }; return made }
    var live: [FakeMic] { all.filter { $0.started && !$0.stopped } }
}

private func waitUntil(_ timeout: Double = 5, _ cond: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if cond() { return true }
        Thread.sleep(forTimeInterval: 0.01)
    }
    return cond()
}

@Suite struct MicRestartTests {
    @Test func deviceChangeRecreatesSource() throws {
        let f = MicFactory()
        let mic = MicCapture(onSamples: { _ in }, makeSource: f.make)
        var restarts = 0
        let lock = NSLock()
        mic.onRestart = { lock.lock(); restarts += 1; lock.unlock() }
        try mic.start()
        #expect(f.all.count == 1)
        // Надели AirPods: AVAudioEngine прислал configurationChange и замолчал.
        f.all[0].onConfigurationChange?()
        #expect(waitUntil { f.all.count == 2 && f.live.count == 1 })
        #expect(f.all[0].stopped)
        #expect(f.live.first === f.all[1])
        #expect(waitUntil { lock.withLock { restarts == 1 } })
        // Повторное уведомление от старого источника — не повод пересоздавать ещё раз.
        f.all[0].onConfigurationChange?()
        Thread.sleep(forTimeInterval: 0.1)
        #expect(f.all.count == 2)
        mic.stop()
        #expect(f.live.isEmpty)
    }

    @Test func retriesUntilDeviceAppears() throws {
        let f = MicFactory()
        let mic = MicCapture(onSamples: { _ in }, makeSource: f.make)
        mic.retryDelay = 0.02
        try mic.start()
        f.failures = 2
        f.all[0].onConfigurationChange?()
        // Две неудачные попытки, третья — живая.
        #expect(waitUntil { f.all.count == 4 && f.live.count == 1 })
        mic.stop()
    }

    @Test func givesUpWithError() throws {
        let f = MicFactory()
        let mic = MicCapture(onSamples: { _ in }, makeSource: f.make)
        mic.retryDelay = 0.01
        let lock = NSLock()
        var errors = 0
        mic.onError = { _ in lock.lock(); errors += 1; lock.unlock() }
        try mic.start()
        f.failures = 100
        f.all[0].onConfigurationChange?()
        #expect(waitUntil { lock.withLock { errors == 1 } })
        #expect(f.all.count == 1 + 1 + MicCapture.maxRetries)
        mic.stop()
    }

    @Test func stopCancelsPendingRetry() throws {
        let f = MicFactory()
        let mic = MicCapture(onSamples: { _ in }, makeSource: f.make)
        mic.retryDelay = 0.2
        try mic.start()
        f.failures = 1
        f.all[0].onConfigurationChange?()
        #expect(waitUntil { f.all.count == 2 })
        // Сессию закрыли, пока ждали устройство: микрофон не должен ожить сам.
        mic.stop()
        Thread.sleep(forTimeInterval: 0.4)
        #expect(f.all.count == 2)
        #expect(f.live.isEmpty)
    }

    @Test func restartLoopStops() throws {
        let f = MicFactory()
        let mic = MicCapture(onSamples: { _ in }, makeSource: f.make)
        let lock = NSLock()
        var errors = 0
        mic.onError = { _ in lock.lock(); errors += 1; lock.unlock() }
        try mic.start()
        for _ in 0...MicCapture.maxRestarts {
            let current = f.live.last
            current?.onConfigurationChange?()
            _ = waitUntil { f.live.last !== current || lock.withLock { errors > 0 } }
        }
        #expect(waitUntil { lock.withLock { errors == 1 } })
        #expect(f.live.isEmpty)
        mic.stop()
    }

    @Test func firstStartFailureThrows() {
        let f = MicFactory()
        f.failures = 1
        let mic = MicCapture(onSamples: { _ in }, makeSource: f.make)
        #expect(throws: CaptureError.self) { try mic.start() }
    }
}

@Suite struct AutoStartArgTests {
    @Test func onlyWithFlag() {
        #expect(SuflyorApp.wantsAutoStart(["/x/Suflyor", "--start-session"]))
        #expect(!SuflyorApp.wantsAutoStart(["/x/Suflyor"]))
        #expect(!SuflyorApp.wantsAutoStart(["/x/Suflyor", "--selftest-capture"]))
    }
}
