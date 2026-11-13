import AppKit
import CoreGraphics

/// Определяет, где на самом деле играет трек. Для приложений хватает bundle id.
/// Для браузеров смотрим вкладки (AppleScript: Safari и Chromium-браузеры)
/// и заголовки окон (CGWindowList: заголовки видны при разрешении «Запись экрана»).
enum PlatformDetector {
    private static let vkWord = try! NSRegularExpression(pattern: #"\bvk\b"#, options: [.caseInsensitive])

    private static let chromiumIds: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.canary", "com.microsoft.edgemac", "com.brave.Browser",
        "com.vivaldi.Vivaldi", "ru.yandex.desktop.yandex-browser", "com.operasoftware.Opera",
        "company.thebrowser.Browser", "org.chromium.Chromium",
    ]

    /// Вызывать в фоне: может запускать AppleScript.
    static func detect(_ t: TrackInfo) -> String? {
        let id = t.bundleId.lowercased()
        if id.contains("spotify") { return "spotify" }
        if id.contains("yandex") && id.contains("music") { return "yandex" }
        if id.contains("vkmusic") || id.contains("vk.music") || id.hasPrefix("com.vk") { return "vk" }
        if id.contains("soundcloud") { return "soundcloud" }
        if id == "com.apple.music" || id.contains("applemusic") { return "apple" }
        if id.contains("youtube") && id.contains("music") { return "ytmusic" }
        if !t.isBrowser { return nil }

        var texts: [(text: String, browser: Bool)] = []
        for s in browserTabs(t.bundleId) { texts.append((s, true)) }
        for w in windowTitles() { texts.append((text: w.0, browser: w.1)) }

        // 1) вкладка/окно, где есть название трека — самый надёжный признак
        let track = t.title.trimmingCharacters(in: .whitespaces).lowercased()
        if track.count >= 3 {
            for w in texts where w.text.contains(track) {
                if let p = fromText(w.text) { return p }
            }
        }
        // 2) любая музыкальная вкладка браузера
        for w in texts where w.browser {
            if let p = fromText(w.text) { return p }
        }
        return nil
    }

    static func fromText(_ s: String) -> String? {
        if s.contains("youtube music") || s.contains("music.youtube.com") { return "ytmusic" }
        if s.contains("вконтакте") || s.contains("vk.com") || s.contains("vk.ru") || s.contains("vk музыка") || s.contains("vk music")
            || vkWord.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil { return "vk" }
        if s.contains("яндекс музыка") || s.contains("яндекс.музыка") || s.contains("yandex music") || s.contains("music.yandex") { return "yandex" }
        if s.contains("soundcloud") { return "soundcloud" }
        if s.contains("spotify") { return "spotify" }
        if s.contains("apple music") || s.contains("music.apple.com") { return "apple" }
        if s.contains("youtube") || s.contains("youtu.be") { return "youtube" }
        return nil
    }

    /// Заголовки + URL всех вкладок браузера (нужно разрешение «Автоматизация»).
    private static func browserTabs(_ bundleId: String) -> [String] {
        guard Script.isRunning(bundleId) else { return [] }
        let titleProp: String
        if bundleId.lowercased() == "com.apple.safari" { titleProp = "name" }
        else if chromiumIds.contains(bundleId) { titleProp = "title" }
        else { return [] } // Firefox не поддерживает AppleScript для вкладок

        let src = """
        set out to ""
        tell application id "\(bundleId)"
            repeat with w in windows
                repeat with t in tabs of w
                    try
                        set out to out & (\(titleProp) of t) & " " & (URL of t) & linefeed
                    end try
                end repeat
            end repeat
        end tell
        return out
        """
        guard let r = Script.run(src) else { return [] }
        return r.lowercased().components(separatedBy: "\n").filter { !$0.isEmpty }
    }

    /// Заголовки видимых окон. Без разрешения «Запись экрана» macOS их не отдаёт — тогда пусто.
    private static func windowTitles() -> [(String, Bool)] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
        var res: [(String, Bool)] = []
        for w in list {
            guard let name = w[kCGWindowName as String] as? String, !name.isEmpty else { continue }
            let owner = (w[kCGWindowOwnerName as String] as? String ?? "").lowercased()
            let browser = ["safari", "chrome", "firefox", "edge", "opera", "brave", "vivaldi", "yandex", "arc"].contains { owner.contains($0) }
            res.append((name.lowercased(), browser))
        }
        return res
    }
}
