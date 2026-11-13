import AppKit

/// Загрузка приватного фреймворка MediaRemote (то, что показывает «Сейчас играет» в Пункте управления).
/// Аналог GlobalSystemMediaTransportControlsSessionManager из Windows.
/// ВНИМАНИЕ: на macOS 15.4+ Apple ограничила доступ — тогда работает MediaRemoteAdapter (через perl),
/// а если и он недоступен — запасной путь через AppleScript.
struct MediaRemote {
    typealias GetInfoFn = @convention(c) (DispatchQueue, @escaping @convention(block) (CFDictionary?) -> Void) -> Void
    typealias GetPIDFn = @convention(c) (DispatchQueue, @escaping @convention(block) (Int32) -> Void) -> Void
    typealias IsPlayingFn = @convention(c) (DispatchQueue, @escaping @convention(block) (Bool) -> Void) -> Void
    typealias SendCmdFn = @convention(c) (UInt32, CFDictionary?) -> Bool
    typealias SetElapsedFn = @convention(c) (Double) -> Void
    typealias RegisterFn = @convention(c) (DispatchQueue) -> Void

    let getInfo: GetInfoFn
    let getPID: GetPIDFn?
    let isPlaying: IsPlayingFn?
    let send: SendCmdFn
    let setElapsed: SetElapsedFn?
    let register: RegisterFn?

    // MRCommand
    static let cmdPlay: UInt32 = 0
    static let cmdPause: UInt32 = 1
    static let cmdToggle: UInt32 = 2
    static let cmdNext: UInt32 = 4
    static let cmdPrev: UInt32 = 5

    init?() {
        guard let h = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW) else { return nil }
        func sym<T>(_ n: String, _ t: T.Type) -> T? {
            guard let p = dlsym(h, n) else { return nil }
            return unsafeBitCast(p, to: t)
        }
        guard let gi = sym("MRMediaRemoteGetNowPlayingInfo", GetInfoFn.self),
              let sc = sym("MRMediaRemoteSendCommand", SendCmdFn.self) else { return nil }
        getInfo = gi
        send = sc
        getPID = sym("MRMediaRemoteGetNowPlayingApplicationPID", GetPIDFn.self)
        isPlaying = sym("MRMediaRemoteGetNowPlayingApplicationIsPlaying", IsPlayingFn.self)
        setElapsed = sym("MRMediaRemoteSetElapsedTime", SetElapsedFn.self)
        register = sym("MRMediaRemoteRegisterForNowPlayingNotifications", RegisterFn.self)
    }

    enum K {
        static let title = "kMRMediaRemoteNowPlayingInfoTitle"
        static let artist = "kMRMediaRemoteNowPlayingInfoArtist"
        static let album = "kMRMediaRemoteNowPlayingInfoAlbum"
        static let duration = "kMRMediaRemoteNowPlayingInfoDuration"
        static let elapsed = "kMRMediaRemoteNowPlayingInfoElapsedTime"
        static let timestamp = "kMRMediaRemoteNowPlayingInfoTimestamp"
        static let rate = "kMRMediaRemoteNowPlayingInfoPlaybackRate"
        static let artwork = "kMRMediaRemoteNowPlayingInfoArtworkData"
    }

    static let notifications = [
        "kMRMediaRemoteNowPlayingInfoDidChangeNotification",
        "kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification",
        "kMRMediaRemoteNowPlayingApplicationDidChangeNotification",
    ]
}

/// Текущий трек + управление воспроизведением.
final class MediaService {
    enum Backend { case none, mediaRemote, spotify, music }

    /// Вызывается на главном потоке.
    var onUpdate: ((TrackInfo?) -> Void)?

    private let mr = MediaRemote()
    /// Работает и на macOS 15.4+ (через системный perl). Если не запустился — старый путь.
    private let adapter = MediaRemoteAdapter()
    private(set) var backend: Backend = .none
    private var timer: Timer?
    private var busySince: Date?
    private let q = DispatchQueue(label: "dynamicisland.media", qos: .utility)

    private var artworkKey: String = ""
    private var artwork: NSImage?
    private var artworkTrackKey: String = ""
    private var remoteArtworkURL: String = ""

    func start() {
        if let adapter {
            adapter.onChange = { [weak self] in self?.refresh() }
            adapter.start()
        }
        if let mr {
            mr.register?(DispatchQueue.main)
            for n in MediaRemote.notifications {
                NotificationCenter.default.addObserver(forName: NSNotification.Name(n), object: nil, queue: .main) { [weak self] _ in
                    self?.refresh()
                }
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in self?.refresh() }
        refresh()
    }

    // MARK: - опрос

    /// Адаптер работает и сейчас что-то играет.
    private var adapterSnapshot: MediaRemoteAdapter.Snapshot? {
        guard let a = adapter, a.isActive, let s = a.latest, !s.title.isEmpty else { return nil }
        return s
    }

    func refresh() {
        if let a = adapter, let s = adapterSnapshot {
            busySince = nil
            deliverAdapter(s, artwork: a.artwork(for: s))
            return
        }

        if let b = busySince, Date().timeIntervalSince(b) < 3 { return }
        busySince = Date()

        // Адаптер работает, но ничего не играет — на всякий случай спрашиваем Spotify / «Музыку».
        if let a = adapter, a.isActive { pollScripts(); return }

        guard let mr else { pollScripts(); return }
        mr.getInfo(DispatchQueue.main) { [weak self] cf in
            guard let self else { return }
            let info = (cf.map { $0 as NSDictionary } as? [String: Any]) ?? [:]
            let title = info[MediaRemote.K.title] as? String ?? ""
            guard !title.isEmpty else { self.pollScripts(); return }

            let finish: (String, Bool?) -> Void = { bundle, playing in
                self.busySince = nil
                self.deliverMR(info, bundle: bundle, playing: playing)
            }
            let afterPID: (String) -> Void = { bundle in
                if let ip = mr.isPlaying {
                    ip(DispatchQueue.main) { playing in finish(bundle, playing) }
                } else { finish(bundle, nil) }
            }
            if let gp = mr.getPID {
                gp(DispatchQueue.main) { pid in
                    afterPID(pid > 0 ? (NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? "") : "")
                }
            } else { afterPID("") }
        }
    }

    private func num(_ v: Any?) -> Double? {
        if let d = v as? Double { return d }
        if let n = v as? NSNumber { return n.doubleValue }
        return nil
    }

    private func deliverAdapter(_ s: MediaRemoteAdapter.Snapshot, artwork: Data?) {
        var info: [String: Any] = [
            MediaRemote.K.title: s.title,
            MediaRemote.K.artist: s.artist,
            MediaRemote.K.album: s.album,
            MediaRemote.K.duration: s.duration,
            MediaRemote.K.elapsed: s.elapsed,
            MediaRemote.K.timestamp: s.timestamp,
            MediaRemote.K.rate: s.rate,
        ]
        if let artwork { info[MediaRemote.K.artwork] = artwork }
        let bundle = s.pid > 0 ? (NSRunningApplication(processIdentifier: s.pid)?.bundleIdentifier ?? "") : ""
        deliverMR(info, bundle: bundle, playing: s.playing)
    }

    private func deliverMR(_ info: [String: Any], bundle: String, playing: Bool?) {
        var t = TrackInfo()
        t.title = info[MediaRemote.K.title] as? String ?? ""
        t.artist = info[MediaRemote.K.artist] as? String ?? ""
        t.album = info[MediaRemote.K.album] as? String ?? ""
        t.bundleId = bundle
        t.duration = num(info[MediaRemote.K.duration]) ?? 0
        t.elapsed = num(info[MediaRemote.K.elapsed]) ?? 0
        t.elapsedTimestamp = info[MediaRemote.K.timestamp] as? Date ?? Date()
        let rate = num(info[MediaRemote.K.rate]) ?? 0
        t.rate = rate > 0 ? rate : 1
        t.isPlaying = playing ?? (rate > 0)

        if let data = info[MediaRemote.K.artwork] as? Data, !data.isEmpty {
            let k = "\(data.count)-\(data.prefix(256).hashValue)-\(data.suffix(256).hashValue)"
            if k != artworkKey { artworkKey = k; artwork = NSImage(data: data) }
            artworkTrackKey = t.key
        } else if artworkTrackKey != t.key {
            // MediaRemote иногда не присылает обложку в промежуточных обновлениях — старую сбрасываем только при смене трека
            artwork = nil; artworkKey = ""
        }
        t.artwork = artwork
        backend = .mediaRemote
        onUpdate?(t)
    }

    /// Запасной путь: Spotify и «Музыка» через AppleScript.
    private func pollScripts() {
        let spotify = Script.isRunning("com.spotify.client")
        let music = Script.isRunning("com.apple.Music")
        guard spotify || music else {
            busySince = nil
            backend = .none
            onUpdate?(nil)
            return
        }
        q.async { [weak self] in
            var result: (TrackInfo, Backend, String)? = nil
            if spotify, let r = Self.scriptTrack(app: "com.spotify.client") { result = (r.0, .spotify, r.1) }
            if result == nil, music, let r = Self.scriptTrack(app: "com.apple.Music") { result = (r.0, .music, r.1) }
            DispatchQueue.main.async {
                guard let self else { return }
                self.busySince = nil
                // пока шёл AppleScript, адаптер уже нашёл трек — не перетираем его
                if self.adapterSnapshot != nil { return }
                guard let res = result else { self.backend = .none; self.onUpdate?(nil); return }
                var t = res.0
                let b = res.1
                let artURL = res.2
                if self.artworkTrackKey != t.key { self.artwork = nil; self.artworkKey = ""; self.artworkTrackKey = t.key }
                if !artURL.isEmpty && artURL != self.remoteArtworkURL {
                    self.remoteArtworkURL = artURL
                    self.loadRemoteArtwork(artURL, key: t.key)
                }
                t.artwork = self.artwork
                self.backend = b
                self.onUpdate?(t)
            }
        }
    }

    private func loadRemoteArtwork(_ s: String, key: String) {
        guard let url = URL(string: s) else { return }
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let data, let img = NSImage(data: data) else { return }
            DispatchQueue.main.async {
                guard let self, self.artworkTrackKey == key else { return }
                self.artwork = img
                self.refresh()
            }
        }.resume()
    }

    private static func parseNum(_ s: String) -> Double {
        Double(s.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)) ?? 0
    }

    /// Возвращает трек и URL обложки (только Spotify).
    private static func scriptTrack(app: String) -> (TrackInfo, String)? {
        let isSpotify = app == "com.spotify.client"
        let art = isSpotify ? "(artwork url of t)" : "\"\""
        let src = """
        tell application id "\(app)"
            set st to (player state as text)
            if st is "stopped" then return "stopped"
            set t to current track
            return st & linefeed & (name of t) & linefeed & (artist of t) & linefeed & (album of t) & linefeed & ((duration of t) as text) & linefeed & ((player position) as text) & linefeed & \(art)
        end tell
        """
        guard let out = Script.run(src, timeout: 3), out != "stopped" else { return nil }
        let lines = out.components(separatedBy: "\n")
        guard lines.count >= 6 else { return nil }
        var t = TrackInfo()
        t.isPlaying = lines[0].contains("play")
        t.title = lines[1]
        t.artist = lines[2]
        t.album = lines[3]
        let dur = parseNum(lines[4])
        t.duration = isSpotify ? dur / 1000 : dur // Spotify отдаёт миллисекунды
        t.elapsed = parseNum(lines[5])
        t.elapsedTimestamp = Date()
        t.rate = 1
        t.bundleId = app
        let artURL = lines.count > 6 ? lines[6].trimmingCharacters(in: .whitespaces) : ""
        return t.title.isEmpty ? nil : (t, artURL)
    }

    // MARK: - управление

    private func appleScriptCommand(_ cmd: String) {
        let app = backend == .spotify ? "com.spotify.client" : "com.apple.Music"
        q.async { _ = Script.run("tell application id \"\(app)\" to \(cmd)") }
    }

    private func command(_ mrCmd: UInt32, _ script: String) {
        switch backend {
        case .mediaRemote:
            if let a = adapter, a.isActive { a.send("cmd \(mrCmd)") } else { _ = mr?.send(mrCmd, nil) }
        case .spotify, .music: appleScriptCommand(script)
        case .none: break
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.refresh() }
    }

    // MARK: - громкость плеера (Spotify / «Музыка»)

    /// Плееры со своей громкостью (AppleScript «sound volume», 0…100).
    static let volumePlayers: Set<String> = ["com.spotify.client", "com.apple.Music"]
    private let volQ = DispatchQueue(label: "dynamicisland.playervolume", qos: .userInitiated)
    private var pendingVolume: (app: String, value: Int)?
    private var volumeBusy = false

    /// Читает громкость плеера (0…1). Кол��эк — на главном потоке.
    func getPlayerVolume(app: String, completion: @escaping (Double?) -> Void) {
        volQ.async {
            let out = Script.run("tell application id \"\(app)\" to get sound volume", timeout: 2)
            let v = out.flatMap { Double($0.trimmingCharacters(in: .whitespaces)) }.map { min(1, max(0, $0 / 100)) }
            DispatchQueue.main.async { completion(v) }
        }
    }

    /// Меняет громкость плеера. При быстром перетаскивании отправляется только последнее значение.
    /// Вызывать на главном потоке.
    func setPlayerVolume(app: String, value: Double) {
        pendingVolume = (app, Int((min(1, max(0, value)) * 100).rounded()))
        drainVolume()
    }

    private func drainVolume() {
        guard !volumeBusy, let p = pendingVolume else { return }
        pendingVolume = nil
        volumeBusy = true
        volQ.async { [weak self] in
            _ = Script.run("tell application id \"\(p.app)\" to set sound volume to \(p.value)", timeout: 2)
            DispatchQueue.main.async {
                self?.volumeBusy = false
                self?.drainVolume()
            }
        }
    }

    func togglePlayPause() { command(MediaRemote.cmdToggle, "playpause") }
    func next() { command(MediaRemote.cmdNext, "next track") }
    func previous() { command(MediaRemote.cmdPrev, "previous track") }

    func seek(to seconds: Double) {
        switch backend {
        case .mediaRemote:
            if let a = adapter, a.isActive { a.send("seek " + String(format: "%.3f", seconds)) } else { mr?.setElapsed?(seconds) }
        case .spotify, .music: appleScriptCommand("set player position to " + String(format: "%.2f", seconds))
        case .none: break
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.refresh() }
    }
}
