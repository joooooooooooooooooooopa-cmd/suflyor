import EventKit
import Foundation

/// Событие календаря в том виде, который нужен суфлёру.
public struct CalendarEvent: Equatable, Sendable {
    public var id: String
    public var title: String
    public var start: Date
    public var end: Date
    /// Имена участников (не почты), без самого пользователя.
    public var attendees: [String]
    /// Событие на весь день (отпуск, дежурство, «Офис»): это не созвон.
    public var allDay: Bool

    public init(id: String, title: String, start: Date, end: Date? = nil, attendees: [String] = [], allDay: Bool = false) {
        self.id = id
        self.title = title
        self.start = start
        self.end = end ?? start.addingTimeInterval(3_600)
        self.attendees = attendees
        self.allDay = allDay
    }

    public var topic: CallTopic { CallTopic(topic: title, with: attendees.joined(separator: ", ")) }
}

/// Источник событий: в приложении EventKit, в тестах фейк.
public protocol EventSource: AnyObject {
    func events(from: Date, to: Date) -> [CalendarEvent]
}

/// Какая встреча сейчас: идёт или начнётся в ближайшие 3 минуты.
public enum CalendarWatcher {
    public static let lead: TimeInterval = 180
    /// Идущая встреча, которой осталось больше этого, — та, на которой пользователь сейчас сидит.
    /// Если меньше — скорее всего, она дозаканчивается и он нажал ⌃⌥⌘ уже под следующий созвон.
    public static let stillRunning: TimeInterval = 300
    /// Длиннее — рабочий блок («Работа», «Фокус»), а не созвон: его название темой не берём.
    public static let maxMeeting: TimeInterval = 3 * 3_600

    /// Порядок: идущая встреча, до конца которой > 5 мин (из нескольких — начавшаяся позже);
    /// иначе ближайшая, что начнётся в ≤ 3 мин; иначе идущая, что вот-вот кончится (созвон затянулся).
    /// События на весь день и длиннее 3 ч не считаются вовсе.
    public static func current(_ source: EventSource, now: Date) -> CalendarEvent? {
        let all = source.events(from: now.addingTimeInterval(-12 * 3_600), to: now.addingTimeInterval(lead))
            .filter { !$0.allDay && $0.end.timeIntervalSince($0.start) <= maxMeeting }
        let running = all.filter { $0.start <= now && $0.end > now }
        if let e = running.filter({ $0.end.timeIntervalSince(now) > stillRunning }).max(by: { $0.start < $1.start }) {
            return e
        }
        if let e = all.filter({ $0.start > now && $0.start <= now.addingTimeInterval(lead) }).min(by: { $0.start < $1.start }) {
            return e
        }
        return running.max { $0.start < $1.start }
    }
}

/// Календари macOS через EventKit. Нет доступа — молча без темы.
final class EventKitSource: EventSource {
    private let store = EKEventStore()

    static var status: EKAuthorizationStatus { EKEventStore.authorizationStatus(for: .event) }
    static var authorized: Bool { status == .fullAccess }

    /// Спрашиваем один раз (если macOS ещё не спрашивал); ответ пользователя дальше помнит система.
    func requestIfNeeded(_ done: @escaping (Bool) -> Void) {
        guard Self.status == .notDetermined else { done(Self.authorized); return }
        store.requestFullAccessToEvents { ok, _ in DispatchQueue.main.async { done(ok) } }
    }

    func events(from: Date, to: Date) -> [CalendarEvent] {
        guard Self.authorized else { return [] }
        let pred = store.predicateForEvents(withStart: from, end: to, calendars: nil)
        return store.events(matching: pred).map { e in
            let names = (e.attendees ?? []).filter { !$0.isCurrentUser }.compactMap { p -> String? in
                guard let n = p.name?.trimmingCharacters(in: .whitespaces), !n.isEmpty, !n.contains("@") else { return nil }
                return n
            }
            return CalendarEvent(id: e.calendarItemIdentifier, title: e.title ?? "Без названия",
                                 start: e.startDate, end: e.endDate, attendees: names, allDay: e.isAllDay)
        }
    }
}
