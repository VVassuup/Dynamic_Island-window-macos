import AppKit
import SwiftUI
import Combine

/// Прозрачная панель без рамки поверх строки меню. Не активирует приложение при клике.
final class IslandPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Хост SwiftUI, который принимает первый клик (иначе первый клик только фокусирует окно).
final class IslandHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class IslandController {
    let state = IslandState()
    private var panel: IslandPanel!
    private let reader = NotificationReader()
    private var mouseTimer: Timer?
    private var fsTimer: Timer?
    private var collapseWork: DispatchWorkItem?
    private var cancellables = Set<AnyCancellable>()
    private var lastSettings = SettingsStore.shared.s
    private var menuOpen = false

    private(set) var userHidden = false
    private var fsHidden = false

    private let spring = Animation.spring(response: 0.42, dampingFraction: 0.8)

    func start() {
        let p = IslandPanel(contentRect: NSRect(x: 0, y: 0, width: 520, height: 640),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = false
        p.hidesOnDeactivate = false
        p.isMovable = false
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        p.ignoresMouseEvents = true

        let host = IslandHostingView(rootView: IslandRootView(state: state))
        host.sizingOptions = []
        host.autoresizingMask = [.width, .height]
        p.contentView = host
        panel = p

        applySettings(SettingsStore.shared.s, initial: true)
        layout()
        p.orderFrontRegardless()

        state.start()
        reader.onNotification = { [weak self] n in self?.state.post(n) }
        if SettingsStore.shared.s.systemNotifications { reader.start() }

        let nc = NotificationCenter.default
        nc.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.layout()
        }
        nc.addObserver(forName: .diTestNotification, object: nil, queue: .main) { [weak self] _ in
            self?.state.testNotification()
        }
        nc.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] _ in
            self?.menuOpen = true
        }
        nc.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { [weak self] _ in
            self?.menuOpen = false
        }

        // $s публикует новое значение до присваивания — поэтому работаем с переданным значением
        SettingsStore.shared.$s
            .sink { [weak self] s in self?.applySettings(s, initial: false) }
            .store(in: &cancellables)

        mouseTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in self?.pollMouse() }
        fsTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in self?.checkFullscreen() }
    }

    // MARK: - настройки

    private func applySettings(_ s: AppSettings, initial: Bool) {
        let old = lastSettings
        lastSettings = s
        panel.level = s.alwaysOnTop ? .statusBar : .normal
        if initial { return }

        if s.scale != old.scale || s.topOffset != old.topOffset { layout(s) }
        if s.systemNotifications != old.systemNotifications {
            if s.systemNotifications { reader.start() } else { reader.stop() }
        }
        if s.language != old.language { Loc.apply(s.language) }
        if s.showLyrics != old.showLyrics {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if s.showLyrics { self.state.reloadLyrics() } else { self.state.lyrics = []; self.state.lyricIndex = -1 }
            }
        }
        if !s.hideInFullscreen && fsHidden { fsHidden = false; updateVisibility() }
    }

    // MARK: - положение

    func layout(_ settings: AppSettings? = nil) {
        let s = settings ?? SettingsStore.shared.s
        guard let screen = NSScreen.screens.first, panel != nil else { return }
        // шире острова с запасом, чтобы свечение не обрезалось по бокам; рамка — в целых пикселях (чёткость)
        let w = (520 * s.scale).rounded()
        let h = (640 * s.scale + s.topOffset).rounded()
        let f = screen.frame
        let scaleF = screen.backingScaleFactor
        let x = ((f.midX - w / 2) * scaleF).rounded() / scaleF
        panel.setFrame(NSRect(x: x, y: f.maxY - h, width: w, height: h), display: true)
    }

    // MARK: - мышь: наведение и клики сквозь остров

    private func pollMouse() {
        guard panel.isVisible else { return }
        let m = NSEvent.mouseLocation
        let f = panel.frame
        // SwiftUI-координаты: начало в левом верхнем углу окна
        let pt = CGPoint(x: m.x - f.minX, y: f.maxY - m.y)
        let inside = state.islandRect.insetBy(dx: -2, dy: -2).contains(pt)
        let overInteractive = state.interactiveRects.contains { $0.contains(pt) }
        let s = SettingsStore.shared.s

        let ignore = !(inside && (!s.clickThrough || overInteractive || state.notification != nil))
        if panel.ignoresMouseEvents != ignore { panel.ignoresMouseEvents = ignore }

        if inside {
            collapseWork?.cancel()
            collapseWork = nil
            if !state.expanded && state.notification == nil {
                withAnimation(spring) { state.expanded = true }
            }
        } else if state.expanded && collapseWork == nil && !state.seeking && !menuOpen {
            let w = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.collapseWork = nil
                if self.state.seeking || self.menuOpen { return }
                withAnimation(self.spring) {
                    self.state.expanded = false
                    self.state.showRecent = false
                }
            }
            collapseWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: w)
        }
    }

    // MARK: - полноэкранный режим

    private func checkFullscreen() {
        let s = SettingsStore.shared.s
        var fs = false
        if s.hideInFullscreen, let screen = NSScreen.screens.first,
           let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != getpid(),
           let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] {
            let sf = screen.frame
            let pid = Int(app.processIdentifier)
            for w in list {
                guard (w[kCGWindowLayer as String] as? Int) == 0,
                      (w[kCGWindowOwnerPID as String] as? Int) == pid,
                      let bd = w[kCGWindowBounds as String] as? NSDictionary,
                      let r = CGRect(dictionaryRepresentation: bd as CFDictionary) else { continue }
                // окно занимает весь экран вместе со строкой меню → полноэкранный режим / видео
                if r.minX <= sf.minX + 1 && r.minY <= 1 && r.width >= sf.width - 1 && r.height >= sf.height - 1 {
                    fs = true
                    break
                }
            }
        }
        if fs != fsHidden {
            fsHidden = fs
            updateVisibility()
        }
    }

    // MARK: - видимость

    func toggleVisible() {
        userHidden.toggle()
        updateVisibility()
    }

    private func updateVisibility() {
        if !userHidden && !fsHidden {
            layout()
            panel.orderFrontRegardless()
        } else {
            panel.orderOut(nil)
        }
    }
}
