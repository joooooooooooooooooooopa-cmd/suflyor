import Foundation
import Testing
@testable import SuflyorKit

private let t0 = Date(timeIntervalSince1970: 10_000)

private func utt(_ seq: Int, _ ch: Channel, _ text: String, at sec: Double) -> Utterance {
    Utterance(seq: seq, channel: ch, text: text, start: t0.addingTimeInterval(sec - 1), end: t0.addingTimeInterval(sec))
}

@Suite struct QuestionDetectorTests {
    @Test(arguments: [
        "А сколько стоит подключение для нас?",
        "Ну и когда вы это запустите",
        "Почему конверсия упала на прошлой неделе",
        "Расскажи как устроен этот процесс",
        "Объясните пожалуйста откуда эти цифры",
        "Можно ли ускорить продление подписки",
        "Есть ли у вас отчёт по продажам",
        "А если клиент не ответит вовремя",
        "Какие сроки по второму этапу",
        "Кто у вас отвечает за внедрение",
        "Вы уже смотрели вчерашний релиз?",
        "Покажи мне дашборд по обращениям",
        "Можете скинуть отчёт после созвона",   // просьба в любом месте
        "Слушай, а подскажи по срокам релиза",
        "Так когда будет готово всё это",       // вопросительное слово третьим
    ])
    func questions(_ text: String) {
        #expect(QuestionDetector.isQuestion(text))
    }

    @Test(arguments: [
        "Сколько стоит?",                       // вопрос, но короче 4 слов
        "Как дела",                             // короткий small talk
        "Хорошо, договорились, пишу в чат",
        "Мы вчера выкатили новую версию",
        "Да, отлично, спасибо большое",
        "Окей, тогда созвонимся в пятницу",
        "Я посмотрю отчёт и вернусь",
        "Если честно мне всё нравится",         // «если» без «а» перед ним
        "Есть у нас такая штука",               // «есть» без «ли»
        "Я думаю, что всё ок",                  // «что» — союз, не вопрос
        "Мы знаем, когда это будет готово",
        "Нам надо закрыть это до пятницы, потом посмотрим что дальше",  // «что» далеко от начала
        "",
    ])
    func notQuestions(_ text: String) {
        #expect(!QuestionDetector.isQuestion(text))
    }
}

@Suite struct QuestionGateTests {
    @Test func ignoresStatementsAndOwnSpeech() {
        let g = QuestionGate()
        #expect(!g.feed(utt(0, .they, "Мы вчера выкатили новую версию", at: 1)))
        #expect(!g.feed(utt(1, .me, "А сколько стоит подключение для нас?", at: 2)))
        #expect(g.fire() == nil)
    }

    @Test func continuationIsGluedUntilFire() {
        let g = QuestionGate()
        #expect(g.feed(utt(3, .they, "А сколько стоит подключение", at: 1)))
        #expect(!g.feed(utt(4, .me, "угу", at: 1.5)))          // моя реплика не продлевает и не приклеивается
        #expect(g.feed(utt(5, .they, "для второго бренда", at: 2)))  // продолжение продлевает таймер
        let q = try! #require(g.fire())
        #expect(q.text == "А сколько стоит подключение для второго бренда")
        #expect(q.seqs == [3, 5])
        #expect(q.end == t0.addingTimeInterval(2))
        #expect(g.fire() == nil)
    }
}

@Suite struct BrainPromptTests {
    @Test func exactFormat() {
        let log = [
            utt(0, .they, "Привет, Макс", at: 10),
            utt(1, .me, "Привет", at: 12),
            utt(2, .they, "А сколько стоит подключение?", at: 15),
        ]
        let q = PendingQuestion(log[2])
        #expect(BrainPrompt.build(log: log, question: q) == """
        КОНТЕКСТ (последние ~2 мин созвона):
        ОНИ: Привет, Макс
        Я: Привет
        ВОПРОС/РЕПЛИКА, на которую нужен ответ:
        ОНИ: А сколько стоит подключение?
        """)
    }

    @Test func windowIs12LinesAnd120Seconds() {
        // 30 реплик раз в 5 с: в 120 с влезает 24, срабатывает предел в 12 строк.
        let log = (0..<30).map { utt($0, $0 % 2 == 0 ? .they : .me, "реплика \($0)", at: Double($0 + 1) * 5) }
        var q = PendingQuestion(log[29])
        var lines = BrainPrompt.build(log: log, question: q).components(separatedBy: "\n")
        let ctx = lines[1..<(lines.count - 2)]
        #expect(ctx.count == 12)
        #expect(ctx.first == "Я: реплика 17")
        #expect(ctx.last == "ОНИ: реплика 28")
        #expect(lines.last == "Я: реплика 29")

        // Короткий созвон, но с давними репликами: старше 120 с от вопроса не берём.
        let sparse = [utt(0, .they, "давно", at: 0), utt(1, .me, "недавно", at: 100), utt(2, .they, "вопрос", at: 200)]
        q = PendingQuestion(sparse[2])
        lines = BrainPrompt.build(log: sparse, question: q).components(separatedBy: "\n")
        #expect(lines == ["КОНТЕКСТ (последние ~2 мин созвона):", "Я: недавно",
                          "ВОПРОС/РЕПЛИКА, на которую нужен ответ:", "ОНИ: вопрос"])
    }
}

/// Записанные строки stream-json: init, три куска текста, служебные события, итог.
let streamFixture = [
    #"{"type":"system","subtype":"init","session_id":"s1","model":"m","tools":[]}"#,
    #"{"type":"stream_event","event":{"type":"message_start","message":{"id":"m1"}}}"#,
    #"{"type":"stream_event","event":{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}}"#,
    #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"СКАЖИ: "}}}"#,
    #"мусор, не JSON"#,
    #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"скину цифру "}}}"#,
    #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{}"}}}"#,
    #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"после созвона"}}}"#,
    "",
    #"{"type":"assistant","message":{"content":[{"type":"text","text":"СКАЖИ: скину цифру после созвона"}]}}"#,
    #"[1,2,3]"#,
    #"{"type":"result","subtype":"success","is_error":false,"duration_ms":1234,"result":"СКАЖИ: скину цифру после созвона"}"#,
]

@Suite struct StreamParserTests {
    @Test func fixtureGivesTextAndEnd() {
        var acc = BrainAnswerAccumulator()
        let outs = streamFixture.compactMap { acc.feed($0) }
        #expect(outs == [
            .delta("СКАЖИ: "), .delta("скину цифру "), .delta("после созвона"),
            .finished("СКАЖИ: скину цифру после созвона"),
        ])
    }

    @Test func isErrorIsFailure() {
        var acc = BrainAnswerAccumulator()
        let out = acc.feed(#"{"type":"result","subtype":"success","is_error":true,"result":"API Error: 500 overloaded"}"#)
        #expect(out == .failed("API Error: 500 overloaded"))
        #expect(BrainStream.parse(#"{"type":"result","subtype":"error_during_execution","is_error":false}"#)
                == .result(text: "", error: "error_during_execution"))
    }

    /// Маркеры лимита — только в ошибке: успешный ответ со словами «rate limit» — это подсказка.
    @Test func limitMarkersOnlyInErrors() {
        var acc = BrainAnswerAccumulator()
        #expect(acc.feed(#"{"type":"result","subtype":"success","is_error":false,"result":"СКАЖИ: у API rate limit 100 в минуту"}"#)
                == .finished("СКАЖИ: у API rate limit 100 в минуту"))
        var err = BrainAnswerAccumulator()
        #expect(err.feed(#"{"type":"result","subtype":"success","is_error":true,"result":"You've hit your limit · resets 5pm"}"#)
                == .failed("You've hit your limit · resets 5pm"))
        var empty = BrainAnswerAccumulator()
        #expect(empty.feed(#"{"type":"result","subtype":"success","is_error":false,"result":""}"#) == .failed("пустой ответ"))
        var ok = BrainAnswerAccumulator()
        #expect(ok.feed(#"{"type":"result","subtype":"success","is_error":false,"result":"СКАЖИ: лимит по карте 5000"}"#)
                == .finished("СКАЖИ: лимит по карте 5000"))
    }
}

@Suite struct BrainLaunchTests {
    @Test func isolationFlagsArePresent() {
        let sys = URL(fileURLWithPath: "/x/prompts/system.md")
        let brief = URL(fileURLWithPath: "/x/briefs/product.md")
        let a = BrainLaunch.arguments(model: "smart", systemPromptFile: sys, briefFile: brief)
        func value(_ flag: String) -> String? { a.firstIndex(of: flag).map { a[$0 + 1] } }
        #expect(a.first == "-p")
        #expect(a.contains("--safe-mode"))
        #expect(value("--model") == "smart")
        #expect(value("--setting-sources") == "")
        #expect(value("--tools") == "")
        #expect(a.contains("--strict-mcp-config"))
        #expect(a.contains("--no-session-persistence"))
        #expect(value("--system-prompt-file") == "/x/prompts/system.md")
        #expect(value("--append-system-prompt-file") == "/x/briefs/product.md")
        #expect(value("--input-format") == "stream-json")
        #expect(value("--output-format") == "stream-json")
        #expect(a.contains("--include-partial-messages"))
        #expect(a.contains("--verbose"))

        let noBrief = BrainLaunch.arguments(model: "smart", systemPromptFile: sys, briefFile: nil)
        #expect(!noBrief.contains("--append-system-prompt-file"))
        #expect(noBrief.contains("--strict-mcp-config") && noBrief.contains("--no-session-persistence"))
    }

    @Test func userMessageIsOneJSONLine() throws {
        let d = BrainLaunch.userMessage("строка 1\nстрока \"2\"")
        #expect(d.last == 0x0A)
        #expect(d.dropLast().firstIndex(of: 0x0A) == nil)
        let obj = try #require(try JSONSerialization.jsonObject(with: d.dropLast()) as? [String: Any])
        #expect(obj["type"] as? String == "user")
        let msg = try #require(obj["message"] as? [String: Any])
        #expect(msg["role"] as? String == "user")
        #expect(msg["content"] as? String == "строка 1\nстрока \"2\"")
    }

    @Test func binaryOverrideAndMissing() {
        #expect(BrainLaunch.findBrainBinary(env: ["SUFLYOR_BRAIN_BIN": "/bin/sh"]) == "/bin/sh")
        #expect(BrainLaunch.findBrainBinary(env: ["SUFLYOR_BRAIN_BIN": "/nonexistent/x"]) == nil)
    }
}

@Suite struct HintPartsTests {
    @Test func splitsFormat() {
        let p = HintParts.parse("СКАЖИ: Да, подключение… бесплатно.\nФАКТЫ: 5 лицензий · 2 дня\nЕСЛИ ДОЖМУТ: точную цифру скину после созвона")
        #expect(p.say == "Да, подключение… бесплатно.")
        #expect(p.facts == "5 лицензий · 2 дня")
        #expect(p.ifPushed == "точную цифру скину после созвона")
        #expect(!p.silent)
    }

    @Test func dashIsSilentAndUnmarkedIsSay() {
        #expect(HintParts.parse(" — \n").silent)
        #expect(HintParts.parse("").silent)
        #expect(HintParts.parse("**СКАЖИ:** коротко").say == "коротко")
        #expect(HintParts.parse("просто текст").say == "просто текст")
    }
}

@Suite struct HintLayoutTests {
    @Test func saySplitsIntoSentencesPerLine() {
        #expect(HintLayout.sentences("Да, подключаем. Сроки — 2 дня! Устроит? Тогда фиксирую")
                == ["Да, подключаем.", "Сроки — 2 дня!", "Устроит?", "Тогда фиксирую"])
        // Десятичные, сокращения, многоточие внутри фразы и адреса не режем.
        #expect(HintLayout.sentences("Рост 3.5% к прошлой неделе, т. е. в норме… пока что.")
                == ["Рост 3.5% к прошлой неделе, т. е. в норме… пока что."])
        #expect(HintLayout.sentences("Ссылка https://wiki.example.org/a.b тут. 5 клиентов уже")
                == ["Ссылка https://wiki.example.org/a.b тут.", "5 клиентов уже"])
        #expect(HintLayout.sentences("Первая строка\nВторая") == ["Первая строка", "Вторая"])
    }

    /// Поток по токенам: уже показанные строки не меняются, растёт только последняя.
    @Test func streamingKeepsEarlierLinesStable() {
        let full = "Да, подключаем. Сроки — 2 дня. Устроит?"
        var prev: [String] = []
        for n in 1...full.count {
            let lines = HintLayout.sentences(String(full.prefix(n)))
            if prev.count > 1 { #expect(Array(lines.prefix(prev.count - 1)) == Array(prev.dropLast())) }
            #expect(lines.count >= prev.count)
            prev = lines
        }
        #expect(prev.count == 3)
    }

    @Test func factsBecomeList() {
        #expect(HintLayout.facts("5 лицензий · 2 дня · 30% быстрее") == ["5 лицензий", "2 дня", "30% быстрее"])
        #expect(HintLayout.facts("• первый\n- второй\n\n") == ["первый", "второй"])
        #expect(HintLayout.facts("") == [])
    }

    @Test func numbersAreHighlighted() {
        let segs = HintLayout.numberSegments("Рост 12,5 % за 2 дня, 1 500 чатов, $4 в сутки")
        #expect(segs.filter(\.isNumber).map(\.text) == ["12,5 %", "2", "1 500", "$4"])
        #expect(segs.map(\.text).joined() == "Рост 12,5 % за 2 дня, 1 500 чатов, $4 в сутки")
        // Цифры внутри кодов и адресов — не числа для ответа.
        #expect(HintLayout.numberSegments("тикет TICKET-1 и mp3, wiki/page2").allSatisfy { !$0.isNumber })
        #expect(HintLayout.numberSegments("без цифр") == [HintLayout.Segment("без цифр", number: false)])
        #expect(HintLayout.numberSegments("до 15.10.").filter(\.isNumber).map(\.text) == ["15.10"])
    }

    /// Метка, пришедшая потоком наполовину, не мелькает крупным текстом в «скажи».
    @Test func unfinishedMarkerIsHidden() {
        #expect(HintParts.parse("СКАЖИ: Да, бесплатно.\nФАК").say == "Да, бесплатно.")
        #expect(HintParts.parse("СКАЖИ: Да, бесплатно.\nФАКТЫ: 5 лицензий\nЕСЛИ ДО").facts == "5 лицензий")
        #expect(HintParts.parse("**СКА").say == "")
        // Обычное начало фразы и метка без продолжения не прячутся.
        #expect(HintParts.parse("СКАЖИ: Да\nСкоро").say == "Да\nСкоро")
        #expect(HintParts.parse("СКАЖИ: Да, бесплатно.\nФАК\n").say == "Да, бесплатно.\nФАК")
    }
}

@Suite struct TranscriptResetTests {
    @Test func resetForgetsLogAndLateResults() {
        let store = TranscriptStore()
        store.fulfill(store.reserve(.they), text: "старый созвон", start: t0, end: t0)
        let late = store.reserve(.they)   // ушло в whisper до конца сессии
        store.reset()
        #expect(store.utterances.isEmpty)
        #expect(store.last(.they) == nil)
        store.fulfill(late, text: "запоздалая", start: t0, end: t0)
        store.fulfill(store.reserve(.they), text: "старый созвон", start: t0, end: t0)  // повтор уже не «повтор»
        #expect(store.utterances.map(\.text) == ["старый созвон"])
    }
}

@Suite struct HintLinkTests {
    @Test func allFourParts() {
        let p = HintParts.parse("""
        СКАЖИ: Сейчас скину ссылку в чат
        ФАКТЫ: 3 проекта
        ЕСЛИ ДОЖМУТ: детали там же
        ССЫЛКА: страница тарифов https://acme.example.com/pricing?plan=team&from=2026-10-01 — тариф для команды
        """)
        #expect(p.say == "Сейчас скину ссылку в чат")
        #expect(p.facts == "3 проекта")
        #expect(p.ifPushed == "детали там же")
        #expect(p.link.hasPrefix("страница тарифов"))
        #expect(p.url == "https://acme.example.com/pricing?plan=team&from=2026-10-01")
    }

    @Test func noLinkLine() {
        let p = HintParts.parse("СКАЖИ: давайте зафиксирую\nФАКТЫ: https://не-ссылка-из-фактов.example")
        #expect(p.link.isEmpty)
        #expect(p.url == nil)   // адрес в ФАКТАХ ссылкой не считается
        #expect(HintParts.parse("СКАЖИ: только это").url == nil)
    }

    @Test func cyrillicParamsAndFirstOfSeveral() {
        #expect(HintParts.parse("ССЫЛКА: https://wiki.example.org/Отдел/Изменения?стр=2&q=а+б.").url
                == "https://wiki.example.org/Отдел/Изменения?стр=2&q=а+б")
        #expect(HintParts.parse("ССЫЛКА: (https://jira.example.org/browse/TICKET-1), а ещё https://second.example").url
                == "https://jira.example.org/browse/TICKET-1")
        #expect(HintParts.parse("ССЫЛКА: https://en.example.org/wiki/Foo_(bar)").url
                == "https://en.example.org/wiki/Foo_(bar)")
    }
}

