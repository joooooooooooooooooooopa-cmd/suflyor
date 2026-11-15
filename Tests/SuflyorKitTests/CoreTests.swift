import Foundation
import Testing
@testable import SuflyorKit

// Синтетика: тишина — нули, «речь» — тон 440 Гц с амплитудой 0.3 (RMS ≈ 0.21, далеко над порогом).
private let sr = 16_000
private func silence(_ sec: Double) -> [Float] { [Float](repeating: 0, count: Int(sec * Double(sr))) }
private func tone(_ sec: Double) -> [Float] {
    (0..<Int(sec * Double(sr))).map { Float(0.3 * sin(2 * Double.pi * 440 * Double($0) / Double(sr))) }
}

/// Прогон сигнала через VAD кусками по `chunk` сэмплов, как приходит из захвата звука.
private func segments(_ signal: [Float], chunk: Int = 1_600, flush: Bool = true) -> [SpeechSegment] {
    let vad = EnergyVAD()
    var out: [SpeechSegment] = []
    var i = 0
    while i < signal.count {
        out += vad.process(Array(signal[i..<min(i + chunk, signal.count)]))
        i += chunk
    }
    if flush, let s = vad.flush() { out.append(s) }
    return out
}

@Suite struct VADTests {
    @Test func silenceToneSilenceGivesOneSegment() {
        let segs = segments(silence(1) + tone(2) + silence(1), flush: false)
        #expect(segs.count == 1)
        let s = try! #require(segs.first)
        // Начало — за preroll 0.2 с до тона, конец — тон + оставленные 0.2 с хвоста.
        #expect(abs(s.startTime - 0.8) < 0.03)
        #expect(abs(s.endTime - 3.2) < 0.05)
        #expect(s.samples.count == Int((s.endTime - s.startTime) * Double(sr)))
    }

    @Test func longSpeechIsCutAt12Seconds() {
        let segs = segments(tone(30) + silence(1), flush: false)
        #expect(segs.count == 3)
        for s in segs { #expect(s.duration <= 12.0 + 0.001) }
        #expect(abs(segs[0].duration - 12) < 0.05)
        #expect(abs(segs[1].duration - 12) < 0.05)
        // Без дублей и дыр: следующий фрагмент начинается там, где кончился предыдущий.
        #expect(abs(segs[1].startTime - segs[0].endTime) < 0.001)
        #expect(abs(segs[2].startTime - segs[1].endTime) < 0.001)
    }

    @Test func shortPauseDoesNotSplitLongPauseDoes() {
        #expect(segments(tone(1) + silence(0.3) + tone(1) + silence(1), flush: false).count == 1)
        #expect(segments(tone(1) + silence(1) + tone(1) + silence(1), flush: false).count == 2)
    }

    @Test func clickShorterThanMinSpeechIsDropped() {
        #expect(segments(silence(0.5) + tone(0.1) + silence(1)).isEmpty)
    }

    @Test func pureSilenceGivesNothing() {
        #expect(segments(silence(5)).isEmpty)
    }

    @Test func chunkSizeDoesNotChangeResult() {
        let sig = silence(0.7) + tone(1.5) + silence(0.9) + tone(2) + silence(1)
        let a = segments(sig, chunk: 1_600)
        let b = segments(sig, chunk: 333)
        #expect(a == b)
        #expect(a.count == 2)
    }

    @Test func flushClosesUnfinishedPhrase() {
        let segs = segments(silence(0.5) + tone(2), flush: true)
        #expect(segs.count == 1)
    }
}

@Suite struct JunkFilterTests {
    @Test(arguments: [
        "", "   ", "[музыка]", "[Музыка]", "(смех)", "*аплодисменты*", "♪♪", "Музыка.",
        "Продолжение следует...", "ПРОДОЛЖЕНИЕ СЛЕДУЕТ…",
        "Субтитры сделал DimaTorzok", "Субтитры создавал DimaTorzok", "Субтитры: Иванов",
        "Редактор субтитров А.Семкин Корректор А.Егорова", "Корректор А.Кулакова",
        "Спасибо за просмотр!", "Подписывайтесь на канал", "Субтитры подготовлены сообществом Amara.org",
        "[BLANK_AUDIO]", "...", "!?",
    ])
    func junkIsDropped(_ s: String) {
        #expect(JunkFilter.clean(s) == nil)
    }

    @Test(arguments: [
        "Давай обсудим бюджет на следующий квартал",
        "Включи, пожалуйста, субтитры",
        "Да",
        "Музыка у вас играет на фоне",
    ])
    func normalSpeechIsKept(_ s: String) {
        #expect(JunkFilter.clean(s) == s)
    }

    @Test func soundTagsAreStrippedFromRealPhrase() {
        #expect(JunkFilter.clean("[музыка] Привет, слышно меня?") == "Привет, слышно меня?")
    }

    @Test func repeatOfPreviousIsDropped() {
        #expect(JunkFilter.clean("Хорошо, договорились.", previous: "хорошо договорились") == nil)
        #expect(JunkFilter.clean("Хорошо, договорились.", previous: "Созвонимся завтра") != nil)
    }

    @Test func loopInsideOneAnswerIsCollapsed() {
        #expect(JunkFilter.clean("Спасибо. Спасибо. Спасибо.") == "Спасибо.")
        #expect(JunkFilter.clean("Ну... давай так") == "Ну... давай так")
    }
}

@Suite struct WAVTests {
    private func u32(_ d: Data, _ o: Int) -> UInt32 { d[o..<o + 4].reversed().reduce(0) { $0 << 8 | UInt32($1) } }
    private func u16(_ d: Data, _ o: Int) -> UInt16 { UInt16(d[o]) | UInt16(d[o + 1]) << 8 }

    @Test func headerIsValidPCM16Mono16k() {
        let samples: [Float] = [0, 1, -1, 0.5, 2, -2]
        let d = WAV.encode(samples: samples)
        #expect(d.count == 44 + samples.count * 2)
        #expect(String(decoding: d[0..<4], as: UTF8.self) == "RIFF")
        #expect(u32(d, 4) == UInt32(36 + samples.count * 2))
        #expect(String(decoding: d[8..<12], as: UTF8.self) == "WAVE")
        #expect(String(decoding: d[12..<16], as: UTF8.self) == "fmt ")
        #expect(u32(d, 16) == 16)
        #expect(u16(d, 20) == 1)        // PCM
        #expect(u16(d, 22) == 1)        // моно
        #expect(u32(d, 24) == 16_000)
        #expect(u32(d, 28) == 32_000)   // byte rate
        #expect(u16(d, 32) == 2)        // block align
        #expect(u16(d, 34) == 16)
        #expect(String(decoding: d[36..<40], as: UTF8.self) == "data")
        #expect(u32(d, 40) == UInt32(samples.count * 2))
        // Сэмплы: 1 → 32767, -1 → -32767, выход за ±1 обрезается.
        #expect(Int16(bitPattern: u16(d, 46)) == 32_767)
        #expect(Int16(bitPattern: u16(d, 48)) == -32_767)
        #expect(Int16(bitPattern: u16(d, 52)) == 32_767)
        #expect(Int16(bitPattern: u16(d, 54)) == -32_767)
    }

    @Test func multipartHasFileAndFields() {
        var mp = Multipart(boundary: "B")
        mp.addFile("file", filename: "a.wav", mime: "audio/wav", data: Data([1, 2, 3]))
        mp.addField("response_format", "json")
        let body = String(decoding: mp.finalized(), as: UTF8.self)
        #expect(mp.contentType == "multipart/form-data; boundary=B")
        #expect(body.contains("name=\"file\"; filename=\"a.wav\"\r\nContent-Type: audio/wav\r\n\r\n\u{1}\u{2}\u{3}\r\n"))
        #expect(body.contains("name=\"response_format\"\r\n\r\njson\r\n"))
        #expect(body.hasSuffix("--B--\r\n"))
    }

    @Test func clientRefusesNonLoopback() {
        #expect(LoopbackHTTP.isLoopback(URL(string: "http://127.0.0.1:1234")!))
        #expect(!LoopbackHTTP.isLoopback(URL(string: "http://localhost:1234")!))
        #expect(!LoopbackHTTP.isLoopback(URL(string: "https://example.com")!))
    }

    @Test func freePortIsUsable() throws {
        let p = try WhisperServer.freeLoopbackPort()
        #expect(p > 0 && p < 65_536)
    }
}

/// Потокобезопасный сборщик для колбэков.
private final class Collector: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [Utterance] = []
    func add(_ u: Utterance) { lock.lock(); items.append(u); lock.unlock() }
    var all: [Utterance] { lock.lock(); defer { lock.unlock() }; return items }
}

@Suite struct TranscriptStoreTests {
    private let t0 = Date(timeIntervalSince1970: 1_000)

    @Test func outOfOrderResultsArePublishedInOrderPerChannel() {
        let store = TranscriptStore()
        let got = Collector()
        store.subscribe { got.add($0) }
        let a = store.reserve(.they), b = store.reserve(.me), c = store.reserve(.they)
        store.fulfill(c, text: "третья", start: t0, end: t0)
        #expect(got.all.isEmpty)  // первая «они» ещё не готова — третью не публикуем
        // «я» не ждёт канал «они»: длинная фраза собеседника в whisper не задерживает мою.
        store.fulfill(b, text: "вторая", start: t0, end: t0)
        #expect(got.all.map(\.text) == ["вторая"])
        store.fulfill(a, text: "первая", start: t0, end: t0)
        #expect(got.all.map(\.text) == ["вторая", "первая", "третья"])
        #expect(store.utterances.map(\.text) == ["вторая", "первая", "третья"])
        #expect(store.utterances.filter { $0.channel == .they }.map(\.seq) == [0, 2])
    }

    @Test func failedAndJunkResultsDoNotBlockQueue() {
        let store = TranscriptStore()
        let a = store.reserve(.they), b = store.reserve(.they), c = store.reserve(.they)
        store.fulfill(b, text: "[музыка]", start: t0, end: t0)
        store.fulfill(c, text: "дальше", start: t0, end: t0)
        store.fulfill(a, text: nil, start: t0, end: t0)  // ошибка расшифровки
        #expect(store.utterances.map(\.text) == ["дальше"])
    }

    @Test func repeatsAreCheckedPerChannel() {
        let store = TranscriptStore()
        for (ch, text) in [(Channel.they, "Привет"), (.me, "Привет"), (.they, "Привет"), (.they, "Как дела")] {
            store.fulfill(store.reserve(ch), text: text, start: t0, end: t0)
        }
        #expect(store.utterances.map(\.text) == ["Привет", "Привет", "Как дела"])
        #expect(store.last(.me)?.text == "Привет")
        #expect(store.last(.they)?.text == "Как дела")
    }

    @Test func unsubscribeStopsCallbacks() {
        let store = TranscriptStore()
        let got = Collector()
        let id = store.subscribe { got.add($0) }
        store.unsubscribe(id)
        store.fulfill(store.reserve(.me), text: "раз", start: t0, end: t0)
        #expect(got.all.isEmpty)
    }

    @Test func transcriberKeepsOrderWithParallelRequests() {
        let store = TranscriptStore()
        let got = Collector()
        store.subscribe { got.add($0) }
        let lock = NSLock()
        var inFlight = 0, maxInFlight = 0, n = 0
        // Первые запросы «думают» дольше последующих — ответы приходят вразнобой.
        let tr = Transcriber(store: store) { _ in
            lock.lock(); inFlight += 1; maxInFlight = max(maxInFlight, inFlight); n += 1; let my = n; lock.unlock()
            Thread.sleep(forTimeInterval: Double(10 - my) * 0.01)
            lock.lock(); inFlight -= 1; lock.unlock()
            return "реплика \(my)"
        }
        for i in 0..<8 {
            let seg = SpeechSegment(samples: [Float](repeating: 0.1, count: 100), startTime: Double(i), endTime: Double(i) + 0.5)
            tr.submit(seg, channel: i % 2 == 0 ? .they : .me, streamStart: t0)
        }
        tr.waitUntilIdle()
        #expect(maxInFlight <= 2)
        #expect(got.all.count == 8)
        // Порядок держится внутри канала; каналы между собой не ждут друг друга.
        #expect(got.all.filter { $0.channel == .they }.map(\.seq) == [0, 2, 4, 6])
        #expect(got.all.filter { $0.channel == .me }.map(\.seq) == [1, 3, 5, 7])
        #expect(got.all.filter { $0.channel == .they }.map(\.start) == [0, 2, 4, 6].map { t0.addingTimeInterval(Double($0)) })
    }
}
