import Foundation

/// Отладочный журнал сессии в файл — только по явному включению (`TranscriptDebug`).
///
/// Нужен для живого теста без глаз на панели: по нему видно, что звук идёт по обоим каналам,
/// что расшифровал whisper, что ушло мозгу и что он ответил. По умолчанию выключен и файла
/// не создаёт вовсе: в журнал попадает текст разговора, а без просьбы пользователя на диск не пишем ни слова.
public final class DebugLog: @unchecked Sendable {
    public static var defaultURL: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Logs/Suflyor/debug.log")
    }

    /// Один на процесс; флаг перечитывается в начале каждой сессии (`reload`): приложение живёт
    /// неделями, и включить журнал под один созвон надо без перезапуска.
    public static let shared = DebugLog(enabled: TranscriptDebug.enabled(), url: defaultURL)
    /// Заглушка: ничего не пишет и файла не трогает.
    public static let off = DebugLog(enabled: false, url: URL(fileURLWithPath: "/dev/null"))

    /// Читают колбэки звука и мозга со своих потоков, меняет начало сессии на main — под замком.
    public var enabled: Bool {
        flagLock.lock()
        defer { flagLock.unlock() }
        return _enabled
    }
    private var _enabled: Bool
    private let flagLock = NSLock()
    public let url: URL
    /// Запись на своей очереди: колбэки звука и мозга не ждут диска.
    private let queue = DispatchQueue(label: "suflyor.debuglog")
    private var handle: FileHandle?
    private let stamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    public init(enabled: Bool, url: URL) {
        _enabled = enabled
        self.url = url
    }

    /// Начало сессии: флаг берём свежий. Выключили — файл закрываем, но не стираем: прошлый
    /// журнал пользователь, может, ещё не разобрал. Заглушку `off` не включаем никогда.
    public func reload(enabled on: Bool) {
        guard self !== DebugLog.off else { return }
        flagLock.lock()
        _enabled = on
        flagLock.unlock()
        guard !on else { return }
        queue.async { [self] in
            try? handle?.close()
            handle = nil
        }
    }

    public func log(_ line: @autoclosure () -> String) {
        guard enabled else { return }
        let text = "\(stamp.string(from: Date())) \(line())\n"
        queue.async { [self] in write(text) }
    }

    /// Дождаться, пока всё записано (тесты, выход). Без проверки `enabled`: так тест «выключен —
    /// файла нет» не пройдёт случайно, если запись всё-таки ушла в очередь.
    public func flush() {
        queue.sync {}
    }

    /// Начало сессии: файл обнуляем. Журнал нужен на разбор одного созвона, а копить текст
    /// всех разговоров за день на диске незачем. Перезапуск после выдачи доступа — та же сессия, его не зовут.
    public func startOver() {
        guard enabled else { return }
        queue.async { [self] in
            try? handle?.close()
            handle = nil
            guard FileManager.default.fileExists(atPath: url.path),
                  let h = try? FileHandle(forWritingTo: url) else { return }
            try? h.truncate(atOffset: 0)
            try? h.close()
        }
    }

    private func write(_ text: String) {
        if handle == nil { handle = open() }
        guard let h = handle, let data = text.data(using: .utf8) else { return }
        // Throwing-варианты: старые write/seek при сбое диска роняют процесс исключением ObjC.
        _ = try? h.seekToEnd()
        try? h.write(contentsOf: data)
    }

    /// Каталог 0700, файл 0600: в журнале текст разговора, другим пользователям мака он не нужен.
    private func open() -> FileHandle? {
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
            if !fm.fileExists(atPath: url.path) {
                guard fm.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { return nil }
            }
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return try FileHandle(forWritingTo: url)
        } catch {
            appLog.error("отладочный журнал не открылся: \(error.localizedDescription)")
            return nil
        }
    }
}

/// Уровень звука канала за окно: видно, что буферы реально идут и это не тишина.
/// Пишут колбэки захвата (свои очереди), читает таймер на main — поэтому под замком.
public final class LevelMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var sumSquares: Double = 0
    private var samples = 0
    private var buffers = 0

    public init() {}

    public func feed(_ s: [Float]) {
        var acc: Double = 0
        for x in s { acc += Double(x) * Double(x) }
        lock.lock()
        sumSquares += acc
        samples += s.count
        buffers += 1
        lock.unlock()
    }

    /// Снимок за окно и обнуление. dBFS — RMS относительно полной шкалы; нет сэмплов — nil.
    public func take() -> (dbfs: Double?, buffers: Int) {
        lock.lock()
        defer { sumSquares = 0; samples = 0; buffers = 0; lock.unlock() }
        guard samples > 0 else { return (nil, buffers) }
        let rms = (sumSquares / Double(samples)).squareRoot()
        return (rms > 0 ? 20 * log10(rms) : -.infinity, buffers)
    }

    /// «-42.1 dBFS, 50 буф» / «нет звука, 0 буф».
    public static func describe(_ s: (dbfs: Double?, buffers: Int)) -> String {
        guard let db = s.dbfs else { return "нет звука, \(s.buffers) буф" }
        return db.isFinite ? String(format: "%.1f dBFS, %d буф", db, s.buffers) : "тишина 0, \(s.buffers) буф"
    }
}
