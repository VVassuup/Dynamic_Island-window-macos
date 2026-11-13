import AppKit
import SwiftUI
import Combine

/// Состояние острова: трек, текст, недавние, система, очередь уведомлений.
/// Все методы вызываются на главном потоке.
final class IslandState: ObservableObject {
    enum Page: String { case music, system }

    static let maxRecent = 6

    @Published var expanded = false {
        didSet {
            if expanded && !oldValue {
                refreshPlayerVolume()
                // при наведении событие сразу уступает место раскрытому острову
                activityWork?.cancel()
                activity = nil
            }
        }
    }
    @Published var page: Page = .music {
        didSet { if oldValue != page { SettingsStore.shared.s.lastPage = page.rawValue } }
    }
    @Published var showRecent = false
    @Published var notification: NotificationItem?
    /// «Живое» событие (раскладка, зарядка, Bluetooth-наушники) — показывается на 1–3 секунды.
    @Published var activity: LiveActivity?
    @Published var track: TrackInfo?
    @Published var platform: String?
    @Published var position: Double = 0
    @Published var lyrics: [LyricLine] = []
    @Published var lyricIndex: Int = -1
    @Published var recent: [RecentItem] = []
    @Published var sys = SystemSnapshot()
    @Published var coverColor: NSColor?
    @Published var volume: Double = 0.5
    @Published var muted = false
    @Published var volumeAvailable = false
    /// Если задано — ползунок управляет громкостью этого плеера, а не системной.
    @Published var playerVolumeApp: String?

    var volumeControllable: Bool { playerVolumeApp != nil || volumeAvailable }

    /// Рамки в координатах окна (начало — слева сверху). Заполняются из SwiftUI.
    var islandRect: CGRect = .zero
    var interactiveRects: [CGRect] = []
    var seeking = false
    var volumeDragging = false
    private var systemVolume: Double = 0.5
    private var systemMuted = false
    private var playerVolumeSetAt = Date.distantPast

    let media = MediaService()
    let volumeService = VolumeService()
    private let monitor = SystemMonitor()
    private var queue: [NotificationItem] = []
    private var notifWork: DispatchWorkItem?
    private var activityWork: DispatchWorkItem?
    private let keyboard = KeyboardLayoutService()
    private let power = PowerEventsService()
    private let bluetooth = BluetoothEventsService()
    private var tick: Timer?
    private var sysTimer: Timer?
    private weak var lastArtwork: NSImage?

    private var settings: AppSettings { SettingsStore.shared.s }

    init() {
        page = Page(rawValue: SettingsStore.shared.s.lastPage) ?? .music
        media.onUpdate = { [weak self] t in self?.apply(t) }
    }

    func start() {
        media.start()
        volumeService.onChange = { [weak self] v, m, a in
            guard let self else { return }
            self.volumeAvailable = a
            self.systemVolume = v
            self.systemMuted = m
            guard self.playerVolumeApp == nil else { return }
            self.muted = m
            if !self.volumeDragging { self.volume = v }
        }
        volumeService.start()
        keyboard.onChange = { [weak self] code, name in
            guard let self, self.settings.showLayoutChange else { return }
            self.showActivity(LiveActivity(symbol: "keyboard", title: name, value: code), seconds: 1.3)
        }
        keyboard.start()
        power.onEvent = { [weak self] a, seconds in
            guard let self, self.settings.showCharging else { return }
            self.showActivity(a, seconds: seconds)
        }
        power.start()
        bluetooth.onEvent = { [weak self] a, seconds in
            guard let self, self.settings.showBluetooth else { return }
            self.showActivity(a, seconds: seconds)
        }
        bluetooth.start()
        tick = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.onTick() }
        sys = monitor.sample()
        sysTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.sys = self.monitor.sample()
            if self.expanded { self.refreshPlayerVolume() }
        }
    }

    // MARK: - музыка

    private func apply(_ t: TrackInfo?) {
        let oldKey = track?.key
        guard var t else {
            if track != nil { track = nil }
            if oldKey != nil { lyrics = []; lyricIndex = -1; platform = nil; coverColor = nil }
            updateVolumeTarget()
            return
        }
        if seeking { t.elapsed = position; t.elapsedTimestamp = Date() }
        if track != t { track = t }
        updateVolumeTarget()

        if t.key != oldKey {
            platform = nil
            lyrics = []
            lyricIndex = -1
            addRecent(t)
            detectPlatform(t)
            loadLyrics(t)
        }
        if t.artwork !== lastArtwork {
            lastArtwork = t.artwork
            coverColor = t.artwork.flatMap { ImageUtil.averageColor($0) }
            if let art = t.artwork, let i = recent.firstIndex(where: { $0.id == t.key }), recent[i].artwork == nil {
                recent[i].artwork = art
            }
        }
        onTick()
    }

    private func onTick() {
        guard let t = track else { return }
        if !seeking { position = t.position() }
        guard !lyrics.isEmpty else { if lyricIndex != -1 { lyricIndex = -1 }; return }
        var idx = -1
        let p = position + 0.25
        for (i, l) in lyrics.enumerated() {
            if l.time <= p { idx = i } else { break }
        }
        if idx != lyricIndex { lyricIndex = idx }
    }

    var currentLyric: String {
        guard lyricIndex >= 0, lyricIndex < lyrics.count else { return "" }
        return lyrics[lyricIndex].text
    }

    var nextLyric: String {
        let i = lyricIndex + 1
        guard i >= 0, i < lyrics.count else { return "" }
        return lyrics[i].text
    }

    private func addRecent(_ t: TrackInfo) {
        recent.removeAll { $0.id == t.key }
        recent.insert(RecentItem(title: t.title, artist: t.artist, artwork: t.artwork, platform: nil), at: 0)
        // текущий трек в списке не показывается, поэтому храним на один больше
        if recent.count > Self.maxRecent + 1 { recent.removeLast(recent.count - Self.maxRecent - 1) }
    }

    private func detectPlatform(_ t: TrackInfo) {
        let key = t.key
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let p = PlatformDetector.detect(t)
            DispatchQueue.main.async {
                guard let self, self.track?.key == key else { return }
                self.platform = p
                if let i = self.recent.firstIndex(where: { $0.id == key }) { self.recent[i].platform = p }
            }
        }
    }

    func reloadLyrics() {
        if let t = track { loadLyrics(t) }
    }

    private func loadLyrics(_ t: TrackInfo) {
        guard settings.showLyrics else { lyrics = []; return }
        let key = t.key
        Task { [weak self] in
            let l = await LyricsService.shared.get(artist: t.artist, title: t.title, duration: t.duration, fromBrowser: t.isBrowser)
            DispatchQueue.main.async {
                guard let self, self.track?.key == key else { return }
                self.lyrics = l ?? []
                self.onTick()
            }
        }
    }

    func togglePlayPause() {
        media.togglePlayPause()
        if var t = track {
            t.elapsed = t.position(); t.elapsedTimestamp = Date(); t.isPlaying.toggle()
            track = t
        }
    }

    // MARK: - громкость

    /// Spotify или «Музыка» → громкость плеера; остальное (браузеры и т. д.) → системная.
    private func updateVolumeTarget() {
        let id = track?.bundleId ?? ""
        let app: String? = settings.playerVolume && MediaService.volumePlayers.contains(id) && Script.isRunning(id) ? id : nil
        guard app != playerVolumeApp else { return }
        playerVolumeApp = app
        if app == nil {
            muted = systemMuted
            volume = systemVolume
        } else {
            muted = false
            refreshPlayerVolume(force: true)
        }
    }

    /// Синхронизация с плеером (если громкость поменяли в самом Spotify / «Музыке»).
    func refreshPlayerVolume(force: Bool = false) {
        guard let app = playerVolumeApp, !volumeDragging else { return }
        guard force || Date().timeIntervalSince(playerVolumeSetAt) > 1.5 else { return }
        media.getPlayerVolume(app: app) { [weak self] v in
            guard let self, let v, self.playerVolumeApp == app, !self.volumeDragging,
                  Date().timeIntervalSince(self.playerVolumeSetAt) > 1.5 else { return }
            if v > 0 {
                self.muted = false
                self.volume = v
            } else if !self.muted {
                self.volume = 0
            }
        }
    }

    func volumeBegan() { volumeDragging = true; seeking = true }

    func volumeChanged(_ v: Double) {
        let x = min(1, max(0, v))
        volume = x
        if muted && x > 0 { muted = false }
        if let app = playerVolumeApp {
            playerVolumeSetAt = Date()
            media.setPlayerVolume(app: app, value: x)
        } else {
            volumeService.setVolume(x)
        }
    }

    func volumeEnded() {
        volumeDragging = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.seeking = false }
    }

    func toggleMute() {
        if let app = playerVolumeApp {
            // у плееров нет mute: ставим 0, а прежнее значение храним в volume
            playerVolumeSetAt = Date()
            if muted || volume <= 0.001 {
                muted = false
                if volume <= 0.001 { volume = 0.5 }
                media.setPlayerVolume(app: app, value: volume)
            } else {
                muted = true
                media.setPlayerVolume(app: app, value: 0)
            }
        } else {
            muted.toggle()
            volumeService.setMuted(muted)
        }
    }

    func seekBegan() { seeking = true }

    func seekChanged(_ v: Double) { position = v }

    func seekEnded(_ v: Double) {
        position = v
        media.seek(to: v)
        if var t = track { t.elapsed = v; t.elapsedTimestamp = Date(); track = t }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.seeking = false }
    }

    func openRecent(_ r: RecentItem) {
        let pref = settings.recentPlatform
        let id = pref == "auto" ? (r.platform ?? "youtube") : pref
        Platforms.open(id, artist: r.artist, title: r.title)
    }

    func open(_ r: RecentItem, in platformId: String) {
        Platforms.open(platformId, artist: r.artist, title: r.title)
    }

    func copyTitle(_ r: RecentItem) {
        let s = [r.artist, r.title].filter { !$0.isEmpty }.joined(separator: " — ")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }

    // MARK: - уведомления

    func post(_ n: NotificationItem) {
        if settings.doNotDisturb && !n.force { return }
        queue.append(n)
        if notification == nil { showNext() }
    }

    private func showNext() {
        notifWork?.cancel()
        guard !queue.isEmpty else {
            withAnimation(.spring(response: 0.42, dampingFraction: 0.8)) { notification = nil }
            return
        }
        let n = queue.removeFirst()
        activityWork?.cancel()
        activity = nil
        withAnimation(.spring(response: 0.42, dampingFraction: 0.8)) { notification = n }
        let w = DispatchWorkItem { [weak self] in self?.showNext() }
        notifWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + settings.notificationSeconds, execute: w)
    }

    func dismissNotification() { showNext() }

    // MARK: - «живые» события

    /// Не перебивает уведомления и раскрытый остров. Повторное событие просто обновляет текст и таймер.
    func showActivity(_ a: LiveActivity, seconds: Double) {
        guard notification == nil, !expanded else { return }
        activityWork?.cancel()
        if activity == nil {
            withAnimation(.spring(response: 0.42, dampingFraction: 0.8)) { activity = a }
        } else {
            activity = a
        }
        let w = DispatchWorkItem { [weak self] in
            withAnimation(.spring(response: 0.42, dampingFraction: 0.8)) { self?.activity = nil }
        }
        activityWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: w)
    }

    func testNotification() {
        post(NotificationItem(appName: "Dynamic Island", title: Loc.t("test_title"), body: Loc.t("test_body"),
                              icon: NSApp.applicationIconImage, force: true))
    }
}
