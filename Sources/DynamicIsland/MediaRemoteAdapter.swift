import Foundation

/// «Сейчас играет» для macOS 15.4+.
/// Apple закрыла MediaRemote для сторонних приложений, но системный /usr/bin/perl доступ сохранил.
/// Поэтому запускаем perl, который загружает наш MediaRemoteAdapter.dylib (Contents/Frameworks),
/// читаем из него JSON-строки (stdout) и отправляем команды строками в stdin.
final class MediaRemoteAdapter {
    struct Snapshot {
        var title = ""
        var artist = ""
        var album = ""
        var duration: Double = 0
        var elapsed: Double = 0
        var rate: Double = 0
        var timestamp = Date()
        var playing: Bool?
        var pid: Int32 = 0

        var trackKey: String { title + "|" + artist }
    }

    /// Вызывается на главном потоке при каждом новом снимке / смене состояния.
    var onChange: (() -> Void)?

    private(set) var latest: Snapshot?
    private(set) var isReady = false
    private(set) var failed = false

    private var artworkData: Data?
    private var artworkTrack = ""

    private var process: Process?
    private var stdinPipe: Pipe?
    private var buffer = Data()
    private var restarts: [Date] = []
    private let scriptURL: URL
    private let libURL: URL

    init?() {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/perl"),
              let script = Bundle.main.url(forResource: "mediaremote-adapter", withExtension: "pl"),
              let frameworks = Bundle.main.privateFrameworksURL else { return nil }
        let lib = frameworks.appendingPathComponent("MediaRemoteAdapter.dylib")
        guard FileManager.default.fileExists(atPath: lib.path) else { return nil }
        scriptURL = script
        libURL = lib
    }

    /// Адаптер запущен и отвечает.
    var isActive: Bool { isReady && !failed && process?.isRunning == true }

    /// Обложка текущего трека (только если она относится именно к нему).
    func artwork(for s: Snapshot) -> Data? {
        artworkTrack == s.trackKey ? artworkData : nil
    }

    func start() {
        signal(SIGPIPE, SIG_IGN) // запись в закрытый pipe не должна ронять приложение
        launch()
    }

    func send(_ line: String) {
        guard isActive, let h = stdinPipe?.fileHandleForWriting,
              let d = (line + "\n").data(using: .utf8) else { return }
        try? h.write(contentsOf: d)
    }

    // MARK: - процесс

    private func launch() {
        guard !failed else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        p.arguments = [scriptURL.path, libURL.path, "adapter_stream"]
        let out = Pipe()
        let inp = Pipe()
        p.standardOutput = out
        p.standardInput = inp
        p.standardError = FileHandle.nullDevice

        out.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; return }
            DispatchQueue.main.async { self?.consume(d) }
        }
        p.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async { self?.handleExit() }
        }

        do {
            try p.run()
        } catch {
            failed = true
            return
        }
        process = p
        stdinPipe = inp
    }

    private func handleExit() {
        process = nil
        stdinPipe = nil
        isReady = false
        latest = nil
        buffer.removeAll()
        onChange?()
        guard !failed else { return }

        let now = Date()
        restarts = restarts.filter { now.timeIntervalSince($0) < 60 } + [now]
        if restarts.count > 3 { failed = true; return } // падает постоянно — сдаёмся, работает запасной путь
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.launch() }
    }

    // MARK: - разбор вывода

    private func consume(_ d: Data) {
        buffer.append(d)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer.subdata(in: buffer.startIndex..<nl)
            buffer.removeSubrange(buffer.startIndex...nl)
            if !line.isEmpty { handle(line) }
        }
    }

    private func num(_ v: Any?) -> Double? {
        if let d = v as? Double { return d }
        if let n = v as? NSNumber { return n.doubleValue }
        return nil
    }

    private func handle(_ line: Data) {
        guard let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { return }
        if obj["ready"] != nil { isReady = true; onChange?(); return }
        if obj["error"] != nil { failed = true; onChange?(); return }

        var s = Snapshot()
        s.title = obj["title"] as? String ?? ""
        s.artist = obj["artist"] as? String ?? ""
        s.album = obj["album"] as? String ?? ""
        s.duration = num(obj["duration"]) ?? 0
        s.elapsed = num(obj["elapsed"]) ?? 0
        s.rate = num(obj["rate"]) ?? 0
        if let ts = num(obj["timestamp"]), ts > 0 { s.timestamp = Date(timeIntervalSince1970: ts) }
        if let p = obj["playing"] as? Bool { s.playing = p }
        s.pid = Int32(num(obj["pid"]) ?? 0)

        if let b64 = obj["artwork"] as? String, let data = Data(base64Encoded: b64), !data.isEmpty {
            artworkData = data
            artworkTrack = s.trackKey
        }
        latest = s
        onChange?()
    }
}
