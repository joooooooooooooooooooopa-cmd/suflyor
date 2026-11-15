import Foundation
import os

let appLog = Logger(subsystem: "local.suflyor", category: "app")

/// Локальный whisper-server (whisper.cpp): запускаем сами, слушает только 127.0.0.1.
public final class WhisperServer {
    public struct Config {
        public var binary = "/opt/homebrew/bin/whisper-server"
        public var model = NSHomeDirectory() + "/Library/Application Support/Suflyor/ggml-small.bin"
        /// ru по умолчанию: на коротких фразах auto у small-модели часто путает язык.
        public var language = ProcessInfo.processInfo.environment["SUFLYOR_LANG"] ?? "ru"
        public var threads = 4
        public init() {}
    }

    public enum Failure: LocalizedError {
        case missing(String)
        case notReady
        case stopped
        public var errorDescription: String? {
            switch self {
            case .missing(let p): return "Не найден файл: \(p)"
            case .notReady: return "whisper-server не поднялся за 60 с"
            case .stopped: return "whisper-server остановлен"
            }
        }
    }

    public let config: Config
    public private(set) var port: Int = 0
    /// `process`, `stopped` и `ready` — под замком: start идёт в фоне, stop зовут с main,
    /// и процесс не должен родиться после stop (иначе он переживёт сессию сиротой).
    private let lock = NSLock()
    private var process: Process?
    private var stopped = false
    private var ready = false
    /// Сервер умер сам (упал, убит системой) уже после готовности. Наш `stop` сюда не попадает.
    /// Зовётся на чужом потоке.
    public var onExit: ((Int32) -> Void)?

    public init(config: Config = Config()) {
        self.config = config
    }

    public var baseURL: URL { URL(string: "http://127.0.0.1:\(port)")! }

    func arguments(port: Int) -> [String] {
        [
            "--model", config.model,
            "--host", "127.0.0.1",
            "--port", String(port),
            "--language", config.language,
            "--threads", String(config.threads),
            "--no-timestamps",
            // Подавляет токены вроде [музыка] на уровне декодера; остатки ловит JunkFilter.
            "--suppress-nst",
            // Без перебора температур и с одним кандидатом: на шуме fallback крутит декодер
            // по кругу секундами, а суфлёру нужен быстрый ответ, а не лучший из пяти.
            "-nf",
            "-bo", "1",
        ]
    }

    /// Запуск и ожидание готовности (загрузка small-модели — пара секунд).
    /// Один объект — один запуск: перезапуск идёт новым сервером на новом порту.
    public func start() throws {
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: config.binary) else { throw Failure.missing(config.binary) }
        // Модель только читаем: whisper-server открывает её на чтение и ничего рядом не пишет.
        guard fm.isReadableFile(atPath: config.model) else { throw Failure.missing(config.model) }

        let p = Process()
        do {
            lock.lock()
            defer { lock.unlock() }
            guard !stopped, process == nil else { throw Failure.stopped }
            port = try Self.freeLoopbackPort()
            p.executableURL = URL(fileURLWithPath: config.binary)
            p.arguments = arguments(port: port)
            // Рабочая папка — временная: на всякий случай, чтобы сервер ничего не создал в чужих местах.
            p.currentDirectoryURL = fm.temporaryDirectory
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            p.terminationHandler = { [weak self] p in self?.exited(p) }
            // run и запись в process — под одним замком: stop не проскочит между ними.
            try p.run()
            process = p
        }
        appLog.info("whisper-server pid=\(p.processIdentifier) port=\(self.port)")

        let deadline = Date().addingTimeInterval(60)
        while Date() < deadline {
            if !p.isRunning || isStopped { break }
            if ping() {
                lock.lock()
                ready = !stopped
                lock.unlock()
                if ready { return }
                break
            }
            Thread.sleep(forTimeInterval: 0.3)
        }
        let wasStopped = isStopped
        stop()
        throw wasStopped ? Failure.stopped : Failure.notReady
    }

    private var isStopped: Bool {
        lock.lock(); defer { lock.unlock() }
        return stopped
    }

    private func exited(_ p: Process) {
        lock.lock()
        let unexpected = process === p && ready && !stopped
        if process === p { process = nil }
        lock.unlock()
        if unexpected { onExit?(p.terminationStatus) }
    }

    public func stop() {
        lock.lock()
        stopped = true
        let p = process
        process = nil
        lock.unlock()
        guard let p else { return }
        if p.isRunning {
            p.terminate()
            // Даём 2 с на корректный выход, потом добиваем: модель держит ~0.5 ГБ.
            let deadline = Date().addingTimeInterval(2)
            while p.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
            if p.isRunning { kill(p.processIdentifier, SIGKILL) }
        }
    }

    public var pid: pid_t? {
        lock.lock(); defer { lock.unlock() }
        return process?.processIdentifier
    }

    private func ping() -> Bool {
        var req = URLRequest(url: baseURL)
        req.timeoutInterval = 1
        let sem = DispatchSemaphore(value: 0)
        var ok = false
        LoopbackHTTP.session.dataTask(with: req) { _, resp, _ in
            ok = (resp as? HTTPURLResponse) != nil
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 2)
        return ok
    }

    /// Свободный порт: биндим сокет на 127.0.0.1:0, читаем выданный порт, закрываем.
    static func freeLoopbackPort() throws -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { throw POSIXError(.EADDRINUSE) }
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let got = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }
        guard got == 0 else { throw POSIXError(.EIO) }
        return Int(UInt16(bigEndian: addr.sin_port))
    }
}

/// Единственная сетевая сессия приложения. Без кэша, кук и прокси;
/// любой хост кроме 127.0.0.1 отбрасывается до отправки.
enum LoopbackHTTP {
    static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.connectionProxyDictionary = [:]
        c.urlCache = nil
        c.httpCookieStorage = nil
        // 8 с хватает с запасом: 12-секундная фраза у small-модели считается меньше секунды.
        // Дольше — сервер завис, и ждать его значит копить очередь из фраз собеседника.
        c.timeoutIntervalForRequest = WhisperClient.timeout
        return URLSession(configuration: c)
    }()

    static func isLoopback(_ url: URL) -> Bool {
        url.scheme == "http" && url.host == "127.0.0.1"
    }
}

/// Клиент /inference: WAV из памяти → текст.
public final class WhisperClient {
    public let endpoint: URL
    public let language: String
    static let timeout: TimeInterval = 8

    public init(baseURL: URL, language: String) {
        precondition(LoopbackHTTP.isLoopback(baseURL), "whisper только на 127.0.0.1")
        self.endpoint = baseURL.appendingPathComponent("inference")
        self.language = language
    }

    /// Синхронный вызов: зовётся из рабочей очереди транскрайбера, не с main.
    public func transcribe(wav: Data) -> String? {
        guard LoopbackHTTP.isLoopback(endpoint) else { return nil }
        var mp = Multipart()
        mp.addFile("file", filename: "chunk.wav", mime: "audio/wav", data: wav)
        mp.addField("temperature", "0.0")
        mp.addField("response_format", "json")
        mp.addField("language", language)
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue(mp.contentType, forHTTPHeaderField: "Content-Type")
        req.httpBody = mp.finalized()
        req.timeoutInterval = Self.timeout

        let sem = DispatchSemaphore(value: 0)
        var text: String?
        LoopbackHTTP.session.dataTask(with: req) { data, resp, err in
            defer { sem.signal() }
            guard err == nil, let data, (resp as? HTTPURLResponse)?.statusCode == 200,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let t = obj["text"] as? String else { return }
            text = t
        }.resume()
        // Страховка поверх таймаута URLSession: рабочая очередь транскрайбера не должна встать навсегда.
        guard sem.wait(timeout: .now() + Self.timeout + 2) == .success else { return nil }
        return text
    }
}

/// Уборка за прошлым запуском, который умер, не успев погасить детей (краш, kill -9, перезагрузка
/// посреди выката). Висящий whisper-server держит ~0.5 ГБ и порт, папка мозга — пустой мусор в TMPDIR.
enum StartupCleanup {
    /// Папки мозга старше часа: живой мозг этого процесса ещё не запущен, а единственный экземпляр
    /// гарантирует, что чужих живых нет.
    static let brainDirMaxAge: TimeInterval = 3_600
    static let brainDirPrefix = "suflyor-brain-"

    /// Сироты whisper-server из вывода `ps -axo pid=,ppid=,command=`: родитель умер (PPID 1),
    /// и это именно наш запуск — слушает 127.0.0.1 и грузит нашу модель. Чужие whisper-server
    /// (другие приложения, ручной запуск) с другими аргументами не трогаем.
    static func orphanWhisperPIDs(ps: String, model: String) -> [pid_t] {
        ps.split(separator: "\n").compactMap { line in
            let f = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard f.count == 3, let pid = pid_t(f[0]), let ppid = pid_t(f[1]), ppid == 1 else { return nil }
            let cmd = String(f[2])
            let exe = cmd.components(separatedBy: " --").first ?? cmd
            guard exe.hasSuffix("/whisper-server") || exe == "whisper-server",
                  cmd.contains("--host 127.0.0.1"),
                  cmd.contains("--model \(model) ") || cmd.hasSuffix("--model \(model)") else { return nil }
            return pid
        }
    }

    static func staleBrainDirs(in dir: URL, now: Date, maxAge: TimeInterval = brainDirMaxAge) -> [URL] {
        let fm = FileManager.default
        let items = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey])) ?? []
        return items.filter { u in
            guard u.lastPathComponent.hasPrefix(brainDirPrefix),
                  let v = try? u.resourceValues(forKeys: [.contentModificationDateKey, .isDirectoryKey]),
                  v.isDirectory == true, let m = v.contentModificationDate else { return false }
            return now.timeIntervalSince(m) > maxAge
        }
    }

    /// При старте приложения (не CLI-прогонов): гасим сирот и чистим старые папки мозга.
    static func run(model: String = WhisperServer.Config().model) {
        for pid in orphanWhisperPIDs(ps: psOutput(), model: model) {
            appLog.info("гашу осиротевший whisper-server pid=\(pid)")
            kill(pid, SIGTERM)
        }
        let fm = FileManager.default
        for u in staleBrainDirs(in: fm.temporaryDirectory, now: Date()) {
            try? fm.removeItem(at: u)
        }
    }

    private static func psOutput() -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-axo", "pid=,ppid=,command="]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
