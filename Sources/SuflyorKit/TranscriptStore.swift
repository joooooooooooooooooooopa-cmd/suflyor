import Foundation

/// Чей голос: «они» — звук системы (собеседники), «я» — микрофон.
public enum Channel: String, Sendable {
    case they
    case me
}

/// Одна реплика созвона.
public struct Utterance: Equatable, Sendable {
    public let seq: Int
    public let channel: Channel
    public let text: String
    public let start: Date
    public let end: Date
}

/// Лог созвона в памяти + раздача новых реплик подписчикам (панель, этап 2).
///
/// Расшифровка идёт параллельно (до 2 запросов), ответы приходят вразнобой.
/// Поэтому фрагмент сначала бронирует место (`reserve`), а реплика публикуется
/// только когда готовы все более ранние брони своего канала — порядок речи держится
/// внутри канала. Каналы друг друга не ждут: длинный монолог «я» в whisper не задерживает
/// вопрос собеседника, а подсказка нужна именно на него.
public final class TranscriptStore: @unchecked Sendable {
    public typealias Subscriber = (Utterance) -> Void

    public struct Ticket: Hashable, Sendable {
        public let seq: Int
        public let channel: Channel
    }

    private struct Pending {
        let channel: Channel
        let text: String?
        let start: Date
        let end: Date
    }

    private let lock = NSLock()
    /// Закрытие броней идёт строго по одной: иначе два потока могли бы раздать
    /// подписчикам реплики не в том порядке, в каком они легли в лог.
    private let commitQueue = DispatchQueue(label: "suflyor.transcript.commit")
    private var nextSeq = 0
    /// Невыполненные брони каждого канала по порядку выдачи.
    private var waiting: [Channel: [Int]] = [:]
    /// Брони ниже этого номера выданы до `reset` и уже ничего не значат.
    private var floorSeq = 0
    private var ready: [Int: Pending] = [:]
    private var log: [Utterance] = []
    private var lastText: [Channel: String] = [:]
    private var subscribers: [UUID: Subscriber] = [:]

    public init() {}

    /// Все принятые реплики по порядку.
    public var utterances: [Utterance] {
        lock.lock(); defer { lock.unlock() }
        return log
    }

    /// Последняя реплика канала (для «ответь на последнее»).
    public func last(_ channel: Channel) -> Utterance? {
        lock.lock(); defer { lock.unlock() }
        return log.last { $0.channel == channel }
    }

    /// Подписка на новые реплики. Колбэк зовётся на потоке, который закрыл бронь;
    /// UI сам перекидывает на main. Возвращает токен для отписки.
    @discardableResult
    public func subscribe(_ cb: @escaping Subscriber) -> UUID {
        let id = UUID()
        lock.lock(); subscribers[id] = cb; lock.unlock()
        return id
    }

    public func unsubscribe(_ id: UUID) {
        lock.lock(); subscribers[id] = nil; lock.unlock()
    }

    /// Забыть весь лог (конец сессии). Брони, выданные раньше, при закрытии
    /// молча отбрасываются: расшифровка старого созвона может прийти уже после reset.
    public func reset() {
        commitQueue.sync {
            lock.lock()
            log = []
            ready = [:]
            waiting = [:]
            lastText = [:]
            floorSeq = nextSeq
            lock.unlock()
        }
    }

    /// Бронь места в логе. Зовётся в момент отправки фрагмента на расшифровку.
    public func reserve(_ channel: Channel) -> Ticket {
        lock.lock(); defer { lock.unlock() }
        let t = Ticket(seq: nextSeq, channel: channel)
        nextSeq += 1
        waiting[channel, default: []].append(t.seq)
        return t
    }

    /// Закрывает бронь. `text == nil` (ошибка расшифровки) просто освобождает место,
    /// иначе очередь встала бы навсегда. Мусор отсеивается здесь же, в порядке очереди,
    /// чтобы проверка «повтор предыдущей фразы» сравнивала с действительно предыдущей.
    public func fulfill(_ ticket: Ticket, text: String?, start: Date, end: Date) {
        commitQueue.sync { commit(ticket, text: text, start: start, end: end) }
    }

    private func commit(_ ticket: Ticket, text: String?, start: Date, end: Date) {
        var toEmit: [Utterance] = []
        var subs: [Subscriber] = []
        lock.lock()
        guard ticket.seq >= floorSeq else { lock.unlock(); return }
        ready[ticket.seq] = Pending(channel: ticket.channel, text: text, start: start, end: end)
        while let seq = waiting[ticket.channel]?.first, let p = ready.removeValue(forKey: seq) {
            waiting[ticket.channel]?.removeFirst()
            guard let raw = p.text,
                  let clean = JunkFilter.clean(raw, previous: lastText[p.channel]) else { continue }
            lastText[p.channel] = clean
            let u = Utterance(seq: seq, channel: p.channel, text: clean, start: p.start, end: p.end)
            log.append(u)
            toEmit.append(u)
        }
        subs = Array(subscribers.values)
        lock.unlock()
        // Колбэки вне замка (подписчик может читать store), но внутри commitQueue — порядок сохраняется.
        for u in toEmit { for s in subs { s(u) } }
    }
}
