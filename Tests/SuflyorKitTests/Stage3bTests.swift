import Foundation
import Testing
@testable import SuflyorKit

@Suite struct LinkWhitelistTests {
    private let brief = """
    ## Ссылки
    - Тарифы: https://acme.example.com/pricing?plan=team.
    - [Jira TICKET-1](https://jira.example.org/browse/TICKET-1)
    - **https://wiki.example.org/spaces/DOC/pages/973602854/Onboarding-guide**
    - Изменения: https://wiki.example.org/Отдел/Изменения?стр=2
    - Пульт https://app.example.dev/dashboard/ и пульт 2 https://app.example.dev/dashboard/v2/
    - http://insecure.example.org/ — не https, не берём
    """

    private var w: LinkWhitelist { LinkWhitelist(briefText: brief) }

    @Test func extractTrimsTail() {
        #expect(w.urls == [
            "https://acme.example.com/pricing?plan=team",
            "https://jira.example.org/browse/TICKET-1",
            "https://wiki.example.org/spaces/DOC/pages/973602854/Onboarding-guide",
            "https://wiki.example.org/Отдел/Изменения?стр=2",
            "https://app.example.dev/dashboard/",
            "https://app.example.dev/dashboard/v2/",
        ])
    }

    @Test func exactMatch() {
        #expect(w.resolve("https://jira.example.org/browse/TICKET-1") == .allowed("https://jira.example.org/browse/TICKET-1"))
        #expect(w.resolve("https://jira.example.org/browse/TICKET-1.") == .allowed("https://jira.example.org/browse/TICKET-1"))
        #expect(w.resolve("https://app.example.dev/dashboard/") == .allowed("https://app.example.dev/dashboard/"))
    }

    @Test func truncatedIsRestored() {
        #expect(w.resolve("https://wiki.example.org/spaces/DOC/pages/973602854/Onboarding-")
                == .allowed("https://wiki.example.org/spaces/DOC/pages/973602854/Onboarding-guide"))
    }

    @Test func ambiguousPrefixIsHidden() {
        #expect(w.resolve("https://wiki.example.org/") == .rejected)   // две страницы вики
        #expect(w.resolve("https://") == .rejected)
    }

    @Test func inventedIsHidden() {
        #expect(w.resolve("https://jira.example.org/browse/TICKET-999") == .rejected)
        #expect(w.resolve("https://evil.example.com/pricing?plan=team") == .rejected)
        #expect(LinkWhitelist.empty.resolve("https://jira.example.org/browse/TICKET-1") == .rejected)
    }

    @Test func cyrillicAndPercentEncoding() {
        let encoded = "https://wiki.example.org/%D0%9E%D1%82%D0%B4%D0%B5%D0%BB/%D0%98%D0%B7%D0%BC%D0%B5%D0%BD%D0%B5%D0%BD%D0%B8%D1%8F?%D1%81%D1%82%D1%80=2"
        #expect(w.resolve(encoded) == .allowed("https://wiki.example.org/Отдел/Изменения?стр=2"))
        #expect(w.resolve("https://WIKI.example.org/Отдел/Изменения?стр=2") == .allowed("https://wiki.example.org/Отдел/Изменения?стр=2"))
    }
}
