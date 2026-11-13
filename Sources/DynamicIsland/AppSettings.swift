import Foundation
import Combine

/// Настройки приложения. Хранятся в ~/Library/Application Support/DynamicIsland/settings.json
struct AppSettings: Codable, Equatable {
    // внешний вид
    var scale: Double = 1.0
    var topOffset: Double = 8
    var islandColor: String = "#000000"
    var islandOpacity: Double = 1.0
    var coverGlow: Bool = false
    var accentFromCover: Bool = true
    var accentColor: String = "#FFFFFF"
    var shadow: Bool = false
    var vinylCover: Bool = false
    /// Фон острова: solid — сплошной, cover — градиент из цвета трека, custom — свой градиент
    var backgroundStyle: String = "solid"
    var gradientColor: String = "#FF375F"

    // музыка
    var showLyrics: Bool = true
    var showVolume: Bool = true
    var playerVolume: Bool = true
    var compactLyrics: Bool = true
    var showClock: Bool = true
    var recentPlatform: String = "auto"
    var lastPage: String = "music"

    // уведомления
    var notificationSeconds: Double = 5
    var systemNotifications: Bool = false
    var doNotDisturb: Bool = false

    // система
    var hideInFullscreen: Bool = true
    var alwaysOnTop: Bool = true
    var clickThrough: Bool = true

    // «живые» события
    var showLayoutChange: Bool = true
    var showCharging: Bool = true
    var showBluetooth: Bool = true
    var language: String = ""

    init() {}

    // Терпимое чтение: отсутствующие ключи берутся по умолчанию.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func v<T: Decodable>(_ k: CodingKeys, _ d: T) -> T {
            ((try? c.decodeIfPresent(T.self, forKey: k)) ?? nil) ?? d
        }
        scale = v(.scale, scale)
        topOffset = v(.topOffset, topOffset)
        islandColor = v(.islandColor, islandColor)
        islandOpacity = v(.islandOpacity, islandOpacity)
        coverGlow = v(.coverGlow, coverGlow)
        accentFromCover = v(.accentFromCover, accentFromCover)
        accentColor = v(.accentColor, accentColor)
        shadow = v(.shadow, shadow)
        vinylCover = v(.vinylCover, vinylCover)
        backgroundStyle = v(.backgroundStyle, backgroundStyle)
        gradientColor = v(.gradientColor, gradientColor)
        showLyrics = v(.showLyrics, showLyrics)
        showVolume = v(.showVolume, showVolume)
        playerVolume = v(.playerVolume, playerVolume)
        compactLyrics = v(.compactLyrics, compactLyrics)
        showClock = v(.showClock, showClock)
        recentPlatform = v(.recentPlatform, recentPlatform)
        lastPage = v(.lastPage, lastPage)
        notificationSeconds = v(.notificationSeconds, notificationSeconds)
        systemNotifications = v(.systemNotifications, systemNotifications)
        doNotDisturb = v(.doNotDisturb, doNotDisturb)
        hideInFullscreen = v(.hideInFullscreen, hideInFullscreen)
        alwaysOnTop = v(.alwaysOnTop, alwaysOnTop)
        clickThrough = v(.clickThrough, clickThrough)
        showLayoutChange = v(.showLayoutChange, showLayoutChange)
        showCharging = v(.showCharging, showCharging)
        showBluetooth = v(.showBluetooth, showBluetooth)
        language = v(.language, language)

        scale = min(1.6, max(0.6, scale))
        islandOpacity = min(1, max(0.2, islandOpacity))
        notificationSeconds = min(30, max(2, notificationSeconds))
    }
}

final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    @Published var s: AppSettings {
        didSet { if s != oldValue { scheduleSave() } }
    }

    private let fileURL: URL
    private var saveWork: DispatchWorkItem?

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support")
        let dir = base.appendingPathComponent("DynamicIsland", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("settings.json")

        if let data = try? Data(contentsOf: fileURL),
           let loaded = try? JSONDecoder().decode(AppSettings.self, from: data) {
            s = loaded
        } else {
            s = AppSettings()
        }
    }

    private func scheduleSave() {
        saveWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.save() }
        saveWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: w)
    }

    func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(s) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
