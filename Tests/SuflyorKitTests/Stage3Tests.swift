import Foundation
import Testing
@testable import SuflyorKit

@Suite struct CallTopicTests {
    @Test func headerGoesFirstInEveryQuestion() {
        let t = CallTopic(topic: "  Демо Acme CRM ", with: "Анна")
        #expect(t.header == "ТЕМА: Демо Acme CRM · С КЕМ: Анна")
        let u = Utterance(seq: 1, channel: .they, text: "А что с ценой?", start: Date(), end: Date())
        let msg = BrainPrompt.build(log: [u], question: PendingQuestion(u), topic: t)
        #expect(msg.components(separatedBy: "\n").first == "ТЕМА: Демо Acme CRM · С КЕМ: Анна")
        #expect(CallTopic(topic: "Планёрка").header == "ТЕМА: Планёрка")
        // Без темы строки нет — формат этапа 2 не меняется.
        #expect(!BrainPrompt.build(log: [u], question: PendingQuestion(u)).hasPrefix("ТЕМА"))
    }

    @Test func prepMessageFormat() {
        let m = CallTopic(topic: "Демо Acme CRM").prepMessage
        #expect(m.hasPrefix("ПОДГОТОВКА К СОЗВОНУ. Тема: Демо Acme CRM. С кем: не указано. Дай шпаргалку строго в формате:"))
        #expect(m.contains("ГЛАВНОЕ: 5–7 фактов"))
        #expect(m.contains("СПРОСЯТ: 3–5 строк «вопрос → короткий ответ»"))
        #expect(m.contains("ССЫЛКИ: до 3 ссылок из брифа"))
        #expect(m.hasSuffix("Ничего не выдумывай: только бриф."))
        #expect(CallTopic(topic: "x", with: "Олег").prepMessage.contains("С кем: Олег."))
    }
}

@Suite struct CheatSheetTests {
    @Test func fullFormat() {
        let s = CheatSheet.parse("""
        Вот шпаргалка:
        ГЛАВНОЕ:
        · Пилот на 30 дней бесплатно
        · Интеграция с почтой из коробки
        **СПРОСЯТ:**
        Когда интеграция с почтой? → с 1 ноября
        А пилот на 20 мест -> да, бесплатно
        Без стрелки вопрос
        ССЫЛКИ:
        Страница тарифов — https://acme.example.com/pricing?plan=team
        Jira — https://jira.example.org/browse/TICKET-1.
        """)
        #expect(s.main == ["Пилот на 30 дней бесплатно", "Интеграция с почтой из коробки"])
        #expect(s.asks == [.init(question: "Когда интеграция с почтой?", answer: "с 1 ноября"),
                           .init(question: "А пилот на 20 мест", answer: "да, бесплатно"),
                           .init(question: "Без стрелки вопрос", answer: "")])
        #expect(s.links == [.init(title: "Страница тарифов", url: "https://acme.example.com/pricing?plan=team"),
                            .init(title: "Jira", url: "https://jira.example.org/browse/TICKET-1")])
        #expect(s.raw.isEmpty)   // вступление до меток выбрасываем
        #expect(s.summary == "Пилот на 30 дней бесплатно")
    }

    @Test func noSectionsKeepsRawText() {
        let s = CheatSheet.parse("По брифу ничего нет по этой теме.\nСпроси коллегу.")
        #expect(s.main.isEmpty && s.asks.isEmpty && s.links.isEmpty)
        #expect(s.raw == "По брифу ничего нет по этой теме.\nСпроси коллегу.")
        #expect(s.summary == "По брифу ничего нет по этой теме.")
        #expect(CheatSheet.parse("").isEmpty)
    }

    @Test func brokenLinks() {
        let s = CheatSheet.parse("""
        ГЛАВНОЕ: · один факт в строке с меткой
        ССЫЛКИ:
        Дашборд — (ссылки в брифе нет)
        https://wiki.example.org/Отдел/Изменения?стр=2
        Документ: <https://docs.example.org/d/abc>
        """)
        #expect(s.main == ["один факт в строке с меткой"])
        #expect(s.links == [
            .init(title: "https://wiki.example.org/Отдел/Изменения?стр=2", url: "https://wiki.example.org/Отдел/Изменения?стр=2"),
            .init(title: "Документ", url: "https://docs.example.org/d/abc"),
        ])
    }
}

@Suite struct PlacementTests {
    private let builtin = PanelPlacement.Screen(id: "B", isBuiltin: true, isMain: false,
                                                visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 944))
    private let external = PanelPlacement.Screen(id: "E", isBuiltin: false, isMain: true,
                                                 visibleFrame: CGRect(x: 1512, y: 0, width: 2560, height: 1415))

    @Test func builtinTopRightByDefault() {
        let r = PanelPlacement.place(screens: [external, builtin], saved: nil)
        #expect(r.screenID == "B")
        #expect(!r.warning)
        #expect(r.frame == CGRect(x: 1512 - 420 - 20, y: 944 - 560 - 20, width: 420, height: 560))
    }

    @Test func noBuiltinGoesToMainWithWarning() {
        let r = PanelPlacement.place(screens: [external], saved: nil)
        #expect(r.screenID == "E")
        #expect(r.warning)
        #expect(r.frame.maxX == external.visibleFrame.maxX - 20)
    }

    @Test func savedRestoredOnlyIfDisplayConnected() {
        let saved = PanelPlacement.Saved(screenID: "E", frame: CGRect(x: 2000, y: 300, width: 500, height: 600))
        let r = PanelPlacement.place(screens: [external, builtin], saved: saved)
        #expect(r.screenID == "E" && r.frame == saved.frame && !r.warning)
        // Внешний отключили — правило по умолчанию.
        #expect(PanelPlacement.place(screens: [builtin], saved: saved).screenID == "B")
        // Окно уехало за край после смены разрешения — возвращаем внутрь.
        let off = PanelPlacement.Saved(screenID: "B", frame: CGRect(x: 1400, y: 800, width: 420, height: 560))
        let c = PanelPlacement.place(screens: [builtin], saved: off).frame
        #expect(builtin.visibleFrame.contains(c))
    }

    @Test func savedRoundTrip() {
        let suite = "suflyor.test.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        defer { d.removePersistentDomain(forName: suite) }
        #expect(PanelPlacement.load(d) == nil)
        let s = PanelPlacement.Saved(screenID: "X-1", frame: CGRect(x: 10, y: 20, width: 300, height: 400))
        PanelPlacement.save(s, d)
        #expect(PanelPlacement.load(d) == s)

        #expect(PanelSettings.load(d) == .defaults)
        PanelSettings(opacity: 0.7, hintFontSize: 22, calendarEnabled: false).save(d)
        #expect(PanelSettings.load(d) == PanelSettings(opacity: 0.7, hintFontSize: 22, calendarEnabled: false))
    }

    /// Подсказка по умолчанию крупная, подложка не прозрачнее 0.6: старое 0.5 поднимается.
    @Test func readableDefaultsAndOpacityFloor() {
        #expect(PanelSettings.defaults.hintFontSize == 22)
        #expect(PanelSettings.opacityChoices.min() == PanelSettings.minOpacity)
        #expect(PanelSettings.minOpacity == 0.6)
        let suite = "suflyor.test.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        defer { d.removePersistentDomain(forName: suite) }
        d.set(0.5, forKey: PanelSettings.keys.opacity)
        #expect(PanelSettings.load(d).opacity == 0.6)
    }
}

@Suite struct IndicatorTests {
    @Test func dotFollowsState() {
        let m = PanelModel()
        #expect(m.indicator == .sleep)
        #expect(m.statusText == "Сплю · ⌃⌥⌘ — включить")
        m.setPhase(.listening)
        m.setBrainState(.warming)
        #expect(m.indicator == .preparing)
        #expect(m.statusText == "Слушаю · Продукт · прогрев…")
        m.setBrainState(.ready)
        #expect(m.indicator == .listening)
        #expect(m.statusText == "Слушаю · Продукт")
        m.beginAnswer(question: "сколько стоит?")
        #expect(m.indicator == .thinking)
        m.finishAnswer(question: "сколько стоит?", text: "СКАЖИ: 5 долларов", seconds: 3.24)
        #expect(m.indicator == .ready)
        #expect(m.statusText == "Слушаю · Продукт · ответ 3.2 с")
        m.setBrainState(.timedOut)
        #expect(m.indicator == .error)
        #expect(m.statusText.contains("мозг не ответил"))
        m.setBrainState(.limit("usage limit reached"))
        #expect(m.indicator == .limit)
        m.setScreenWarning(true)
        #expect(m.statusText.hasSuffix("⚠ на показываемом экране"))
    }

    @Test func cheatStartsCollapsedAndOpensOnlyByClick() {
        let m = PanelModel()
        m.setCheat("ГЛАВНОЕ: · факт", state: .ready)
        #expect(!m.cheatExpanded)
        m.toggleCheat()
        #expect(m.cheatExpanded)
        m.beginAnswer(question: "первый")
        #expect(m.cheatExpanded)   // развернул руками — подсказка не сворачивает
        m.reset()
        #expect(!m.cheatExpanded)
    }

    @Test func noSystemAudioInStatus() {
        let m = PanelModel()
        m.setPhase(.listening)
        m.setBrainState(.ready)
        m.setSystemAudioOff(true)
        #expect(m.statusText == "Слушаю · Продукт · собеседника не слышу — нет доступа к звуку системы")
        m.reset()
        #expect(!m.systemAudioOff && m.notice == nil)
    }

    @Test func fontIsClamped() {
        let m = PanelModel()
        for _ in 0..<20 { m.changeFont(by: 2) }
        #expect(m.hintFontSize == PanelModel.fontRange.upperBound)
        for _ in 0..<20 { m.changeFont(by: -2) }
        #expect(m.hintFontSize == PanelModel.fontRange.lowerBound)
    }
}
