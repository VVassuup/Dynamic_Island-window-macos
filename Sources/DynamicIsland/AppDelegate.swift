import AppKit
import SwiftUI
import Combine

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let controller = IslandController()
    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // только один экземпляр
        if let id = Bundle.main.bundleIdentifier {
            let others = NSRunningApplication.runningApplications(withBundleIdentifier: id)
                .filter { $0.processIdentifier != getpid() }
            if !others.isEmpty {
                NSApp.terminate(nil)
                return
            }
        }

        Loc.apply(SettingsStore.shared.s.language)
        controller.start()
        setupStatusItem()

        NotificationCenter.default.addObserver(forName: .diOpenSettings, object: nil, queue: .main) { [weak self] _ in
            self?.openSettings()
        }
        LocModel.shared.$lang
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.settingsWindow?.title = Loc.t("set_wintitle") }
            .store(in: &cancellables)
    }

    func applicationWillTerminate(_ notification: Notification) {
        SettingsStore.shared.save()
    }

    // MARK: - строка меню (аналог трея)

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            let img = NSImage(systemSymbolName: "capsule.fill", accessibilityDescription: "Dynamic Island")
            img?.isTemplate = true
            button.image = img
            button.toolTip = "Dynamic Island"
        }
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let s = SettingsStore.shared.s

        menu.addItem(item(Loc.t("tray_settings"), #selector(openSettingsAction), key: ","))
        menu.addItem(.separator())

        let dnd = item(Loc.t("tray_dnd"), #selector(toggleDnd))
        dnd.state = s.doNotDisturb ? .on : .off
        menu.addItem(dnd)

        let ct = item(Loc.t("tray_clickthrough"), #selector(toggleClickThrough))
        ct.state = s.clickThrough ? .on : .off
        menu.addItem(ct)

        let langItem = NSMenuItem(title: Loc.t("tray_language"), action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for l in Loc.languages {
            let li = item(l.name, #selector(setLanguage(_:)))
            li.representedObject = l.id
            li.state = Loc.lang == l.id ? .on : .off
            sub.addItem(li)
        }
        langItem.submenu = sub
        menu.addItem(langItem)

        menu.addItem(item(Loc.t("tray_toggle"), #selector(toggleIsland)))
        menu.addItem(item(Loc.t("tray_test"), #selector(testNotification)))
        menu.addItem(.separator())

        let about = NSMenuItem(title: Loc.t("tray_about"), action: nil, keyEquivalent: "")
        about.isEnabled = false
        menu.addItem(about)
        menu.addItem(item(Loc.t("tray_telegram"), #selector(openTelegram)))
        menu.addItem(item(Loc.t("tray_exit"), #selector(quit), key: "q"))
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = self
        return i
    }

    @objc private func openSettingsAction() { openSettings() }
    @objc private func toggleDnd() { SettingsStore.shared.s.doNotDisturb.toggle() }
    @objc private func toggleClickThrough() { SettingsStore.shared.s.clickThrough.toggle() }
    @objc private func toggleIsland() { controller.toggleVisible() }
    @objc private func testNotification() { controller.state.testNotification() }
    @objc private func quit() { NSApp.terminate(nil) }
    @objc private func openTelegram() {
        if let u = URL(string: "https://t.me/vvassuup") { NSWorkspace.shared.open(u) }
    }

    @objc private func setLanguage(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        SettingsStore.shared.s.language = id
        Loc.apply(id)
    }

    // MARK: - окно настроек

    func openSettings() {
        if settingsWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 640),
                             styleMask: [.titled, .closable, .miniaturizable],
                             backing: .buffered, defer: false)
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: SettingsView())
            w.center()
            settingsWindow = w
        }
        settingsWindow?.title = Loc.t("set_wintitle")
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}
