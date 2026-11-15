import Foundation
import Testing
@testable import SuflyorKit

@Suite struct ChordDetectorTests {
    private typealias M = ChordDetector.Mods
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    /// Прогон последовательности (флаги, секунда); keyDown — `nil` вместо флагов. Вернёт номера срабатываний.
    private func run(_ steps: [(M?, Double)]) -> [Int] {
        var d = ChordDetector()
        var fired: [Int] = []
        for (i, s) in steps.enumerated() {
            if let m = s.0 {
                if d.flags(m, at: t0.addingTimeInterval(s.1)) { fired.append(i) }
            } else {
                d.keyDown()
            }
        }
        return fired
    }

    @Test func pressTogetherAndRelease() {
        #expect(run([([.control], 0), ([.control, .option], 0.05), (.chord, 0.1),
                     ([.control, .option], 0.3), ([.control], 0.35), ([], 0.4)]) == [5])
    }

    @Test func chordWithLetterIsSomeoneElses() {
        #expect(run([(.chord, 0), (nil, 0.1), ([], 0.2)]).isEmpty)
    }

    @Test func extraShiftOrFnSpoils() {
        #expect(run([(.chord, 0), ([.control, .option, .command, .shift], 0.1), (.chord, 0.2), ([], 0.3)]).isEmpty)
        #expect(run([([.shift], 0), ([.shift, .control, .option, .command], 0.1), (.chord, 0.2), ([], 0.3)]).isEmpty)
        #expect(run([([.control, .option, .command, .function], 0), ([], 0.1)]).isEmpty)
    }

    @Test func heldTooLong() {
        #expect(run([(.chord, 0), ([], 1.01)]).isEmpty)
        #expect(run([(.chord, 0), ([], 1.0)]) == [1])
    }

    @Test func notAllThree() {
        #expect(run([([.control, .option], 0), ([], 0.1)]).isEmpty)
        #expect(run([([.command], 0), ([], 0.1)]).isEmpty)
    }

    @Test func partialReleaseAndAgain() {
        // Отпустил ⌘ и снова зажал — это всё ещё одно нажатие, срабатывает при полном отпускании.
        #expect(run([(.chord, 0), ([.control, .option], 0.2), (.chord, 0.4), ([], 0.6)]) == [3])
        // Но секунда считается с первого «все три»: дожимание её не продлевает.
        #expect(run([(.chord, 0), ([.control, .option], 0.6), (.chord, 0.9), ([], 1.2)]).isEmpty)
    }

    @Test func recoversAfterSpoiledOrFired() {
        #expect(run([(.chord, 0), (nil, 0.1), ([], 0.2), (.chord, 1), ([], 1.2), (.chord, 2), ([], 2.1)]) == [4, 6])
    }

    @Test func plainTypingDoesNotSpoilNextChord() {
        #expect(run([(nil, 0), (nil, 0.1), (.chord, 0.2), ([], 0.3)]) == [3])
    }
}

@Suite struct VoiceCommandTests {
    @Test func triggers() {
        #expect(VoiceCommand.isAskTrigger("Суфлёр, подскажи"))
        #expect(VoiceCommand.isAskTrigger("суфлер"))
        #expect(VoiceCommand.isAskTrigger("Эй, суфлёру слово"))
        #expect(VoiceCommand.isAskTrigger("Подскажи."))
    }

    @Test func ordinarySpeechIsNotACommand() {
        #expect(!VoiceCommand.isAskTrigger("Да, давай обсудим сроки"))
        #expect(!VoiceCommand.isAskTrigger(""))
    }

    /// Как whisper (small, ru) записывает «суфлёр» и «подскажи» на живом созвоне.
    @Test(arguments: [
        "Софлер, какие последние изменения", "суфлер какие изменения", "Сюфлёр, что там", "суплер что там",
        "Суфер, что нового", "суфлёра спрошу", "Суфлёр,", "sufler what's new", "Soufleur, привет",
        "суфле что нового", "Суфлор, какие сроки", "Суфлиор, какие сроки",
        "Подскажите, что нового по тарифам", "подсказка по срокам", "Подскажи-ка, что там", "ПОДСКАЖИ",
    ])
    func whisperSpellingsTrigger(_ text: String) {
        #expect(VoiceCommand.isAskTrigger(text))
    }

    @Test(arguments: [
        "Сфера ответственности у нас общая", "В субботу созвонимся", "Другой подход к задаче нужен",
        "Супер, договорились", "Сфера", "суббота", "подход",
    ])
    func ordinaryWordsDoNotTrigger(_ text: String) {
        #expect(!VoiceCommand.isAskTrigger(text))
    }

    @Test func triggerOnlyAtEdgesOfPhrase() {
        // «подскажите» посреди длинной фразы — разговор с человеком.
        #expect(!VoiceCommand.isAskTrigger("Я хотел спросить, вы подскажите, пожалуйста, клиенту, что ответить по срокам переезда"))
        #expect(!VoiceCommand.isAskTrigger("Мы вчера с суфлером долго разбирались, что ответить клиенту по срокам"))
        // В начале и в конце — команда.
        #expect(VoiceCommand.isAskTrigger("Подскажите, пожалуйста, клиенту, что ответить по срокам переезда"))
        #expect(VoiceCommand.isAskTrigger("Что ответить клиенту по срокам переезда, суфлёр"))
    }

    @Test func questionAfterMisspelledTrigger() {
        #expect(VoiceCommand.question(in: "Софлер, какие последние изменения были в релизе")
                == "какие последние изменения были в релизе")
        #expect(VoiceCommand.question(in: "подскажите, что нового по тарифам") == "что нового по тарифам")
        #expect(VoiceCommand.question(in: "Сюфлёр, подскажи-ка, какие сроки по переезду?") == "какие сроки по переезду")
    }

    @Test func levenshtein() {
        #expect(VoiceCommand.levenshtein("суфлер", "суфлер") == 0)
        #expect(VoiceCommand.levenshtein("суфлор", "суфлер") == 1)
        #expect(VoiceCommand.levenshtein("сфера", "суфлер") == 3)
        #expect(VoiceCommand.levenshtein("", "суфлер") == 6)
    }

    @Test func questionInsideCommand() {
        #expect(VoiceCommand.question(in: "Суфлёр, какие последние изменения были в релизе?")
                == "какие последние изменения были в релизе")
        #expect(VoiceCommand.question(in: "Эй, суфлер, ну что там по интеграциям, пожалуйста")
                == "что там по интеграциям")
        // Триггер в конце тоже срезается.
        #expect(VoiceCommand.question(in: "Какие сроки по переезду, суфлёру подскажи") == "Какие сроки по переезду")
    }

    @Test func bareCommandHasNoQuestion() {
        #expect(VoiceCommand.question(in: "Суфлёр, подскажи") == nil)
        #expect(VoiceCommand.question(in: "Подскажи, пожалуйста") == nil)
        #expect(VoiceCommand.question(in: "Эй, суфлёр, подскажи мне") == nil)
        #expect(VoiceCommand.question(in: "суфлёр, а сроки?") == nil)
    }

    private static let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private func u(_ seq: Int, _ c: Channel, _ text: String, at: TimeInterval) -> Utterance {
        Utterance(seq: seq, channel: c, text: text, start: Self.t0.addingTimeInterval(at),
                  end: Self.t0.addingTimeInterval(at + 2))
    }

    @Test func pickOrder() {
        let they = u(1, .they, "Ну вот так у нас с переездом", at: 0)
        let mine = u(2, .me, "А какие изменения в тарифах?", at: 5)
        let cmd = u(3, .me, "Суфлёр, подскажи", at: 10)
        // Свежая реплика собеседника главнее своей.
        #expect(VoiceCommand.pick(command: cmd, log: [they, mine, cmd])?.text == they.text)
        // Собеседник молчал — своя реплика.
        #expect(VoiceCommand.pick(command: cmd, log: [mine, cmd])?.text == mine.text)
        // Вопрос в самой команде главнее всего, даже копившегося автовопроса.
        let asked = u(3, .me, "Суфлёр, какие изменения в релизе?", at: 10)
        let q = VoiceCommand.pick(command: asked, log: [they, mine, asked], pending: PendingQuestion(they))
        #expect(q?.text == "какие изменения в релизе")
        #expect(q?.channel == .me)
        // Без вопроса в команде копившийся автовопрос главнее последней реплики.
        let pend = PendingQuestion(u(9, .they, "А когда переезд?", at: 8))
        #expect(VoiceCommand.pick(command: cmd, log: [they, mine, cmd], pending: pend)?.text == "А когда переезд?")
        // Пусто — спрашивать нечего.
        #expect(VoiceCommand.pick(command: cmd, log: [cmd]) == nil)
    }

    @Test func pickSkipsStaleLinesAndCommands() {
        let oldThey = u(1, .they, "Ну вот так у нас с переездом", at: 0)
        let fresh = u(2, .me, "А какие изменения в тарифах?", at: 95)
        let cmd = u(3, .me, "Суфлёр, подскажи", at: 100)
        // Собеседник говорил 100 с назад — уже не про это.
        #expect(VoiceCommand.pick(command: cmd, log: [oldThey, fresh, cmd])?.text == fresh.text)
        #expect(VoiceCommand.pick(command: cmd, log: [oldThey, cmd]) == nil)
        // Прошлая команда — не своя реплика; реплики после команды к ней не относятся.
        let prevCmd = u(2, .me, "Подскажи", at: 95)
        let after = u(4, .they, "Позже скажу ещё вот что", at: 101)
        #expect(VoiceCommand.pick(command: cmd, log: [prevCmd, cmd, after]) == nil)
        // Граница — ровно 90 с от конца команды.
        let edge = u(1, .they, "Ровно на границе свежести", at: 100 - VoiceCommand.freshness)
        #expect(VoiceCommand.pick(command: cmd, log: [edge, cmd])?.text == edge.text)
    }
}

@Suite struct TopicDetectionTests {
    @Test func parsesTopicAndWho() {
        #expect(TopicDetection.parse("ТЕМА: Запуск пилота\nС КЕМ: Алекс") == CallTopic(topic: "Запуск пилота", with: "Алекс"))
        #expect(TopicDetection.parse("**ТЕМА:** Демо Acme CRM\n") == CallTopic(topic: "Демо Acme CRM"))
        #expect(TopicDetection.parse("Вот что я понял.\nТема: Пилот Acme CRM\nс кем: Анна, Олег")
                == CallTopic(topic: "Пилот Acme CRM", with: "Анна, Олег"))
    }

    @Test func unknownTopicIsNil() {
        #expect(TopicDetection.parse("—") == nil)
        #expect(TopicDetection.parse("ТЕМА: —") == nil)
        #expect(TopicDetection.parse("ТЕМА: -\nС КЕМ: Анна") == nil)
        #expect(TopicDetection.parse("СКАЖИ: не знаю") == nil)
    }

    @Test func messageHasRecentLinesOnly() {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let log = (0..<50).map { i in
            Utterance(seq: i, channel: i % 2 == 0 ? .they : .me, text: "реплика \(i)",
                      start: t0.addingTimeInterval(Double(i)), end: t0.addingTimeInterval(Double(i) + 1))
        }
        let m = TopicDetection.message(log: log)
        #expect(m.contains("ТЕМА: <"))
        #expect(m.contains("ОНИ: реплика 10") && m.contains("Я: реплика 49"))
        #expect(!m.contains("реплика 9\n"))
    }
}

/// Фейковый календарь: отдаёт все события, окно поиска фильтрует CalendarWatcher.
private final class FakeEvents: EventSource {
    let list: [CalendarEvent]
    init(_ list: [CalendarEvent]) { self.list = list }
    func events(from: Date, to: Date) -> [CalendarEvent] { list }
}

@Suite struct CalendarCurrentTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func ev(_ id: String, start: Double, end: Double, who: [String] = []) -> CalendarEvent {
        CalendarEvent(id: id, title: id, start: now.addingTimeInterval(start), end: now.addingTimeInterval(end), attendees: who)
    }

    @Test func runningMeetingBeatsUpcoming() {
        // Идущей встрече осталось больше 5 мин — пользователь сидит на ней, а не на той, что через 2 мин.
        let src = FakeEvents([
            ev("Идёт", start: -1_800, end: 1_200),
            ev("Созвон", start: 120, end: 1_800, who: ["Анна", "Олег"]),
        ])
        #expect(CalendarWatcher.current(src, now: now)?.id == "Идёт")
    }

    @Test func upcomingWinsWhenRunningIsEnding() {
        // Идущей осталось 4 мин — она дозаканчивается, тема у созвона, который вот-вот начнётся.
        let src = FakeEvents([
            ev("Кончается", start: -1_800, end: 240),
            ev("Созвон", start: 120, end: 1_800, who: ["Анна", "Олег"]),
        ])
        let e = CalendarWatcher.current(src, now: now)
        #expect(e?.id == "Созвон")
        #expect(e?.topic == CallTopic(topic: "Созвон", with: "Анна, Олег"))
        // Из двух предстоящих — ближайшая.
        let two = FakeEvents([ev("Через 3", start: 180, end: 1_800), ev("Через 1", start: 60, end: 1_800)])
        #expect(CalendarWatcher.current(two, now: now)?.id == "Через 1")
        // Ничего другого нет — затянувшаяся встреча лучше пустой темы.
        #expect(CalendarWatcher.current(FakeEvents([ev("Кончается", start: -1_800, end: 240)]), now: now)?.id == "Кончается")
    }

    @Test func runningMeetingCounts() {
        #expect(CalendarWatcher.current(FakeEvents([ev("Идёт", start: -600, end: 1_200)]), now: now)?.id == "Идёт")
        // Из двух идущих — начавшаяся позже.
        let two = FakeEvents([ev("Раньше", start: -1_800, end: 1_800), ev("Позже", start: -300, end: 900)])
        #expect(CalendarWatcher.current(two, now: now)?.id == "Позже")
    }

    @Test func outsideWindowIsIgnored() {
        #expect(CalendarWatcher.current(FakeEvents([ev("Через 5 мин", start: 300, end: 1_800)]), now: now) == nil)
        #expect(CalendarWatcher.current(FakeEvents([ev("Кончилась", start: -1_800, end: 0)]), now: now) == nil)
        #expect(CalendarWatcher.current(FakeEvents([ev("Ровно 3 мин", start: 180, end: 1_800)]), now: now)?.id == "Ровно 3 мин")
        #expect(CalendarWatcher.current(FakeEvents([]), now: now) == nil)
    }

    /// Рабочий блок длиннее 3 ч и событие на весь день — не созвоны: ни темой, ни помехой созвону.
    @Test func longBlocksAndAllDayAreSkipped() {
        #expect(CalendarWatcher.current(FakeEvents([ev("Работа", start: -3_600, end: 4 * 3_600)]), now: now) == nil)
        let allDay = CalendarEvent(id: "Офис", title: "Офис", start: now.addingTimeInterval(-3_600),
                                   end: now.addingTimeInterval(1_800), allDay: true)
        #expect(CalendarWatcher.current(FakeEvents([allDay]), now: now) == nil)
        // Блок начался позже созвона, но темой всё равно созвон.
        let src = FakeEvents([
            ev("Созвон", start: -1_800, end: 1_800),
            ev("Работа", start: -600, end: 4 * 3_600),
        ])
        #expect(CalendarWatcher.current(src, now: now)?.id == "Созвон")
        // Ровно 3 ч — ещё встреча.
        #expect(CalendarWatcher.current(FakeEvents([ev("Стратсессия", start: -600, end: 3 * 3_600 - 600)]), now: now)?.id == "Стратсессия")
    }
}

@Suite struct CalendarSettingTests {
    @Test func onByDefaultAndOldKeyIgnored() {
        let suite = "suflyor.test.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        defer { d.removePersistentDomain(forName: suite) }
        #expect(PanelSettings.defaults.calendarEnabled)
        // Старый ключ хранил выключенное «по умолчанию», а не выбор — на новую настройку не влияет.
        d.set(false, forKey: "suflyor.calendarEnabled")
        #expect(PanelSettings.load(d).calendarEnabled)
    }
}

@Suite struct TranscriptDebugTests {
    @Test func offByDefault() throws {
        let name = "suflyor.test.\(UUID().uuidString)"
        let d = try #require(UserDefaults(suiteName: name))
        defer { d.removePersistentDomain(forName: name) }
        #expect(!TranscriptDebug.enabled(env: [:], defaults: d))
        #expect(!TranscriptDebug.enabled(env: ["SUFLYOR_DEBUG": "0"], defaults: d))
        #expect(TranscriptDebug.enabled(env: ["SUFLYOR_DEBUG": "1"], defaults: d))
        d.set(true, forKey: TranscriptDebug.defaultsKey)
        #expect(TranscriptDebug.enabled(env: [:], defaults: d))
    }
}
