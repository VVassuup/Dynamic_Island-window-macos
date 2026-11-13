import Carbon
import Foundation
import SwiftUI

/// Короткое «живое» событие в острове (как на iPhone): значок · подпись · значение.
struct LiveActivity: Equatable {
    let id = UUID()
    var symbol: String
    var title: String
    var value: String
    var tint: Color? = nil

    static func == (a: LiveActivity, b: LiveActivity) -> Bool { a.id == b.id }
}

/// Следит за сменой раскладки клавиатуры (RU / EN / …) через Text Input Sources.
final class KeyboardLayoutService {
    /// code — «RU», «EN»; name — название языка («Русский», «English»).
    var onChange: ((_ code: String, _ name: String) -> Void)?

    private var lastId: String?
    private var observer: NSObjectProtocol?

    func start() {
        lastId = Self.current()?.id
        observer = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
            object: nil, queue: .main
        ) { [weak self] _ in
            // macOS иногда присылает уведомление раньше, чем раскладка реально сменилась
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { self?.check() }
        }
    }

    func stop() {
        if let o = observer { DistributedNotificationCenter.default().removeObserver(o) }
        observer = nil
    }

    deinit { stop() }

    private func check() {
        guard let cur = Self.current(), cur.id != lastId else { return }
        lastId = cur.id
        onChange?(cur.code, cur.name)
    }

    static func current() -> (id: String, code: String, name: String)? {
        guard let src = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return nil }

        func prop(_ key: CFString) -> AnyObject? {
            guard let p = TISGetInputSourceProperty(src, key) else { return nil }
            return Unmanaged<AnyObject>.fromOpaque(p).takeUnretainedValue()
        }

        let id = prop(kTISPropertyInputSourceID) as? String ?? ""
        let layoutName = prop(kTISPropertyLocalizedName) as? String ?? ""
        let lang = (prop(kTISPropertyInputSourceLanguages) as? [String])?.first ?? ""
        let base = String(lang.split(separator: "-").first ?? "")

        let code = base.isEmpty ? String(layoutName.prefix(3)).uppercased() : shortCode(base)
        var name = layoutName
        if !base.isEmpty, let n = Locale(identifier: base).localizedString(forLanguageCode: base), !n.isEmpty {
            name = n.prefix(1).uppercased() + n.dropFirst()
        }
        return (id, code, name)
    }

    private static func shortCode(_ iso: String) -> String {
        switch iso.lowercased() {
        case "uk": return "UA"
        case "be": return "BY"
        case "kk": return "KZ"
        case "ka": return "GE"
        case "hy": return "AM"
        default: return iso.uppercased()
        }
    }
}
