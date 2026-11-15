import AVFoundation
import Foundation
import Testing
@testable import SuflyorKit

/// Сквозная проверка с настоящим whisper-server: речь синтезирует `say`, дальше путь как в приложении
/// (ресемплинг → VAD → WAV в памяти → /inference на 127.0.0.1 → TranscriptStore).
/// Грузит модель ~0.5 ГБ и идёт ~10 с, поэтому только по SUFLYOR_E2E=1.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["SUFLYOR_E2E"] == "1"))
struct WhisperE2ETests {
    @Test func speechGoesThroughWhisperAndServerStops() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("suflyor-e2e-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        // Синтетическая речь, не запись пользователя; файл живёт только в своей temp-папке.
        let aiff = dir.appendingPathComponent("say.aiff")
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-v", "Milena", "-o", aiff.path, "Добрый день. Давайте обсудим бюджет проекта."]
        try say.run()
        say.waitUntilExit()
        try #require(say.terminationStatus == 0)

        let file = try AVAudioFile(forReading: aiff)
        let buf = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buf)
        let speech = MonoResampler().convert(buf)
        try #require(speech.count > 16_000)

        let server = WhisperServer()
        try server.start()
        let pid = try #require(server.pid)
        defer { server.stop() }

        let store = TranscriptStore()
        let client = WhisperClient(baseURL: server.baseURL, language: "ru")
        let tr = Transcriber(store: store) { client.transcribe(wav: $0) }
        let pipe = ChannelPipeline(channel: .they, transcriber: tr)
        let silence = [Float](repeating: 0, count: 16_000)
        pipe.feed(silence + speech + silence)
        pipe.flush()
        tr.waitUntilIdle()

        let text = store.utterances.map(\.text).joined(separator: " ").lowercased()
        #expect(text.contains("бюджет"), "расшифровка: \(text)")
        #expect(store.utterances.allSatisfy { $0.channel == .they })

        server.stop()
        // Сервер погашен: процесса с этим pid больше нет.
        #expect(kill(pid, 0) != 0)
    }
}
