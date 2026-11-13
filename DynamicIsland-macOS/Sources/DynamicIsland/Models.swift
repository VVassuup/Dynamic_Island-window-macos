import AppKit
import SwiftUI

struct TrackInfo: Equatable {
    var title: String = ""
    var artist: String = ""
    var album: String = ""
    /// Bundle id приложения-источника (com.spotify.client, com.google.Chrome…)
    var bundleId: String = ""
    var artwork: NSImage?
    var duration: Double = 0
    var elapsed: Double = 0
    var elapsedTimestamp: Date = Date()
    var rate: Double = 1
    var isPlaying: Bool = false

    var key: String { artist + "|" + title }

    /// Текущая позиция с интерполяцией по времени (как GetPosition в оригинале).
    func position(at now: Date = Date()) -> Double {
        var p = elapsed
        if isPlaying { p += now.timeIntervalSince(elapsedTimestamp) * (rate > 0 ? rate : 1) }
        if duration > 0 { p = min(p, duration) }
        return max(0, p)
    }

    private static let browserIds: Set<String> = [
        "com.apple.safari", "com.google.chrome", "com.google.chrome.canary", "com.microsoft.edgemac",
        "org.mozilla.firefox", "com.operasoftware.opera", "com.operasoftware.operagx",
        "ru.yandex.desktop.yandex-browser", "com.brave.browser", "com.vivaldi.vivaldi",
        "company.thebrowser.browser", "org.chromium.chromium",
    ]

    var isBrowser: Bool {
        let id = bundleId.lowercased()
        if id.contains("music") { return false }
        return Self.browserIds.contains(id) || id.contains("browser") || id.contains("chrome")
            || id.contains("firefox") || id.contains("safari") || id.contains("webkit")
    }

    var browserName: String {
        let id = bundleId.lowercased()
        if id.contains("safari") || id.contains("webkit") { return "Safari" }
        if id.contains("chrome") { return "Chrome" }
        if id.contains("edgemac") { return "Edge" }
        if id.contains("firefox") { return "Firefox" }
        if id.contains("opera") { return "Opera" }
        if id.contains("yandex") { return Loc.t("src_yabrowser") }
        if id.contains("brave") { return "Brave" }
        if id.contains("vivaldi") { return "Vivaldi" }
        if id.contains("thebrowser") { return "Arc" }
        return Loc.t("src_browser")
    }

    var sourceName: String {
        let id = bundleId.lowercased()
        if id.contains("spotify") { return "Spotify" }
        if id == "com.apple.music" { return "Apple Music" }
        if id.contains("yandex") && id.contains("music") { return Loc.t("src_yamusic") }
        if isBrowser { return browserName + " · " + Loc.t("src_web") }
        if id.contains("telegram") { return "Telegram" }
        if id.contains("vlc") { return "VLC" }
        if id.contains("iina") { return "IINA" }
        if id == "com.apple.quicktimeplayerx" { return "QuickTime" }
        if id.isEmpty { return Loc.t("src_media") }
        return AppInfo.displayName(bundleId) ?? bundleId
    }

    /// Подпись источника под названием трека.
    func platformLabel(_ platform: String?) -> String {
        guard let platform else { return sourceName }
        let name = Platforms.name(platform)
        return isBrowser ? name + " · " + browserName : name
    }
}

struct RecentItem: Identifiable, Equatable {
    var id: String { artist + "|" + title }
    var title: String
    var artist: String
    var artwork: NSImage?
    var platform: String?
}

struct NotificationItem: Identifiable, Equatable {
    let id = UUID()
    var appName: String
    var title: String
    var body: String
    var icon: NSImage?
    /// Показывать даже в режиме «Не беспокоить» (тестовые/системные).
    var force: Bool = false
}

struct LyricLine: Equatable {
    var time: Double
    var text: String
}

struct Platform: Identifiable {
    let id: String
    let name: String
}

/// Музыкальные площадки: названия и ссылки для поиска трека.
enum Platforms {
    static var all: [Platform] {
        [
            Platform(id: "vk", name: Loc.t("plat_vk")),
            Platform(id: "yandex", name: Loc.t("plat_yandex")),
            Platform(id: "youtube", name: "YouTube"),
            Platform(id: "ytmusic", name: "YouTube Music"),
            Platform(id: "spotify", name: "Spotify"),
            Platform(id: "soundcloud", name: "SoundCloud"),
            Platform(id: "apple", name: "Apple Music"),
        ]
    }

    static func name(_ id: String) -> String {
        all.first { $0.id == id }?.name ?? id
    }

    static func short(_ id: String?) -> String {
        switch id {
        case "vk": return "VK"
        case "yandex": return Loc.t("plat_yandex_short")
        case "youtube": return "YouTube"
        case "ytmusic": return "YT Music"
        case "spotify": return "Spotify"
        case "soundcloud": return "SoundCloud"
        case "apple": return "Apple"
        default: return ""
        }
    }

    private static let unreserved = CharacterSet(charactersIn:
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    static func open(_ id: String, artist: String, title: String) {
        let q = (artist + " " + title).trimmingCharacters(in: .whitespaces)
        let e = q.addingPercentEncoding(withAllowedCharacters: unreserved) ?? q
        let s: String
        switch id {
        case "vk": s = "https://vk.com/audio?q=" + e + "&section=search"
        case "yandex": s = "https://music.yandex.ru/search?text=" + e
        case "ytmusic": s = "https://music.youtube.com/search?q=" + e
        case "spotify": s = "spotify:search:" + e
        case "soundcloud": s = "https://soundcloud.com/search?q=" + e
        case "apple": s = "https://music.apple.com/search?term=" + e
        default: s = "https://www.youtube.com/results?search_query=" + e
        }
        if id == "spotify" {
            if let u = URL(string: s), NSWorkspace.shared.urlForApplication(toOpen: u) != nil {
                NSWorkspace.shared.open(u)
                return
            }
            if let u = URL(string: "https://open.spotify.com/search/" + e) { NSWorkspace.shared.open(u) }
            return
        }
        if let u = URL(string: s) { NSWorkspace.shared.open(u) }
    }
}

enum AppInfo {
    static func url(_ bundleId: String) -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId)
    }

    static func displayName(_ bundleId: String) -> String? {
        guard let u = url(bundleId) else { return nil }
        let n = FileManager.default.displayName(atPath: u.path)
        return n.hasSuffix(".app") ? String(n.dropLast(4)) : n
    }

    static func icon(_ bundleId: String) -> NSImage? {
        guard let u = url(bundleId) else { return nil }
        return NSWorkspace.shared.icon(forFile: u.path)
    }
}

extension NSColor {
    /// #RRGGBB или #AARRGGBB (как в WPF).
    convenience init?(hex: String) {
        var h = hex.trimmingCharacters(in: .whitespaces)
        if h.hasPrefix("#") { h.removeFirst() }
        guard h.count == 6 || h.count == 8, let v = UInt64(h, radix: 16) else { return nil }
        let a, r, g, b: CGFloat
        if h.count == 8 {
            a = CGFloat((v >> 24) & 0xFF) / 255
            r = CGFloat((v >> 16) & 0xFF) / 255
            g = CGFloat((v >> 8) & 0xFF) / 255
            b = CGFloat(v & 0xFF) / 255
        } else {
            a = 1
            r = CGFloat((v >> 16) & 0xFF) / 255
            g = CGFloat((v >> 8) & 0xFF) / 255
            b = CGFloat(v & 0xFF) / 255
        }
        self.init(srgbRed: r, green: g, blue: b, alpha: a)
    }

    /// Смешивание цветов: t = 0 → self, t = 1 → other.
    func mixed(with other: NSColor, _ t: CGFloat) -> NSColor {
        let a = usingColorSpace(.sRGB) ?? .black
        let b = other.usingColorSpace(.sRGB) ?? .black
        let k = min(1, max(0, t))
        return NSColor(srgbRed: a.redComponent + (b.redComponent - a.redComponent) * k,
                       green: a.greenComponent + (b.greenComponent - a.greenComponent) * k,
                       blue: a.blueComponent + (b.blueComponent - a.blueComponent) * k,
                       alpha: 1)
    }

    /// Яркость 0…1 (для выбора чёрного/белого текста).
    var luminance: CGFloat {
        let c = usingColorSpace(.sRGB) ?? .black
        return 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent
    }

    var hexString: String {
        guard let c = usingColorSpace(.sRGB) else { return "#000000" }
        return String(format: "#%02X%02X%02X",
                      Int(round(c.redComponent * 255)),
                      Int(round(c.greenComponent * 255)),
                      Int(round(c.blueComponent * 255)))
    }
}

enum ImageUtil {
    /// Средний цвет обложки, осветлённый для акцента.
    static func averageColor(_ image: NSImage) -> NSColor? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let side = 8
        var px = [UInt8](repeating: 0, count: side * side * 4)
        let ok: Bool = px.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: side, height: side, bitsPerComponent: 8,
                                      bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard ok else { return nil }
        var r = 0.0, g = 0.0, b = 0.0
        let n = Double(side * side)
        for i in 0..<(side * side) {
            r += Double(px[i * 4]); g += Double(px[i * 4 + 1]); b += Double(px[i * 4 + 2])
        }
        let base = NSColor(deviceRed: r / n / 255, green: g / n / 255, blue: b / n / 255, alpha: 1)
        var hue: CGFloat = 0, sat: CGFloat = 0, bri: CGFloat = 0, al: CGFloat = 0
        base.getHue(&hue, saturation: &sat, brightness: &bri, alpha: &al)
        return NSColor(deviceHue: hue, saturation: min(1, sat * 1.25), brightness: max(bri, 0.78), alpha: 1)
    }
}

/// Запуск AppleScript через osascript (в фоне, без проблем с потоками NSAppleScript).
enum Script {
    static func run(_ source: String, timeout: TimeInterval = 4) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", source]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        killer.cancel()
        guard p.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func isRunning(_ bundleId: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).isEmpty
    }
}

extension Notification.Name {
    static let diOpenSettings = Notification.Name("DynamicIsland.OpenSettings")
    static let diTestNotification = Notification.Name("DynamicIsland.TestNotification")
}
