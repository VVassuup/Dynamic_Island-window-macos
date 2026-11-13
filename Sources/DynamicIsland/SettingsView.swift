import SwiftUI
import AppKit
import ServiceManagement

struct SettingsView: View {
    @ObservedObject var store = SettingsStore.shared
    @ObservedObject var loc = LocModel.shared
    @State private var hex: String = SettingsStore.shared.s.islandColor
    @State private var loginItem: Bool = SMAppService.mainApp.status == .enabled

    private let presets = ["#000000", "#1C1C1E", "#2B2B30", "#0B1F3A", "#2A1446", "#3A0F14", "#0E2E22", "#FFFFFF"]

    private var accentBinding: Binding<Color> {
        Binding(
            get: { Color(nsColor: NSColor(hex: store.s.accentColor) ?? .white) },
            set: { store.s.accentColor = NSColor($0).hexString }
        )
    }

    private let gradientPresets = ["#FF375F", "#BF5AF2", "#0A84FF", "#30D158", "#FF9F0A", "#C8906A"]

    private var gradientBinding: Binding<Color> {
        Binding(
            get: { Color(nsColor: NSColor(hex: store.s.gradientColor) ?? .systemPink) },
            set: { store.s.gradientColor = NSColor($0).hexString }
        )
    }

    private var langBinding: Binding<String> {
        Binding(
            get: { Loc.normalize(store.s.language) ?? Loc.lang },
            set: { store.s.language = $0; Loc.apply($0) }
        )
    }

    private var loginBinding: Binding<Bool> {
        Binding(
            get: { loginItem },
            set: { on in
                do {
                    if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                } catch {
                    NSLog("DynamicIsland: login item error \(error)")
                }
                loginItem = SMAppService.mainApp.status == .enabled
            }
        )
    }

    private func hint(_ key: String) -> some View {
        Text(Loc.t(key)).font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    private func applyHex() {
        var h = hex.trimmingCharacters(in: .whitespaces).uppercased()
        if !h.hasPrefix("#") { h = "#" + h }
        if NSColor(hex: h) != nil { store.s.islandColor = h; hex = h } else { hex = store.s.islandColor }
    }

    var body: some View {
        Form {
            Section(Loc.t("set_appearance")) {
                LabeledContent(Loc.t("set_size")) {
                    HStack {
                        Slider(value: $store.s.scale, in: 0.7...1.6)
                        Text("\(Int((store.s.scale * 100).rounded()))%").monospacedDigit().frame(width: 44, alignment: .trailing)
                    }
                }
                LabeledContent(Loc.t("set_offset")) {
                    HStack {
                        Slider(value: $store.s.topOffset, in: 0...40, step: 1)
                        Text("\(Int(store.s.topOffset)) px").monospacedDigit().frame(width: 44, alignment: .trailing)
                    }
                }
                Toggle(Loc.t("set_shadow"), isOn: $store.s.shadow)
                Toggle(Loc.t("set_vinyl"), isOn: $store.s.vinylCover)
            }

            Section(Loc.t("set_color")) {
                LabeledContent(Loc.t("set_panelcolor")) {
                    HStack(spacing: 6) {
                        ForEach(presets, id: \.self) { h in
                            let selected = store.s.islandColor.uppercased() == h
                            Circle()
                                .fill(Color(nsColor: NSColor(hex: h) ?? .black))
                                .frame(width: 20, height: 20)
                                .overlay(Circle().stroke(selected ? Color.accentColor : Color.gray.opacity(0.45), lineWidth: selected ? 2.5 : 1))
                                .contentShape(Circle())
                                .onTapGesture { store.s.islandColor = h; hex = h }
                        }
                    }
                }
                LabeledContent(Loc.t("set_hex")) {
                    TextField("#000000", text: $hex)
                        .frame(width: 100)
                        .multilineTextAlignment(.trailing)
                        .onSubmit { applyHex() }
                }
                LabeledContent(Loc.t("set_opacity")) {
                    HStack {
                        Slider(value: $store.s.islandOpacity, in: 0.3...1)
                        Text("\(Int((store.s.islandOpacity * 100).rounded()))%").monospacedDigit().frame(width: 44, alignment: .trailing)
                    }
                }
                Picker(Loc.t("set_bg"), selection: $store.s.backgroundStyle) {
                    Text(Loc.t("set_bg_solid")).tag("solid")
                    Text(Loc.t("set_bg_cover")).tag("cover")
                    Text(Loc.t("set_bg_custom")).tag("custom")
                }
                if store.s.backgroundStyle == "custom" {
                    LabeledContent(Loc.t("set_gradcolor")) {
                        HStack(spacing: 6) {
                            ForEach(gradientPresets, id: \.self) { h in
                                let selected = store.s.gradientColor.uppercased() == h
                                Circle()
                                    .fill(LinearGradient(colors: [Color(nsColor: NSColor(hex: h) ?? .systemPink), .black],
                                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                                    .frame(width: 20, height: 20)
                                    .overlay(Circle().stroke(selected ? Color.accentColor : Color.gray.opacity(0.45), lineWidth: selected ? 2.5 : 1))
                                    .contentShape(Circle())
                                    .onTapGesture { store.s.gradientColor = h }
                            }
                            ColorPicker("", selection: gradientBinding, supportsOpacity: false).labelsHidden()
                        }
                    }
                }
                hint("set_bghint")
                Toggle(Loc.t("set_glow"), isOn: $store.s.coverGlow)
                Toggle(Loc.t("set_accentcover"), isOn: $store.s.accentFromCover)
                if !store.s.accentFromCover {
                    ColorPicker(Loc.t("set_accentcolor"), selection: accentBinding, supportsOpacity: false)
                }
            }

            Section(Loc.t("set_music")) {
                Toggle(Loc.t("set_volume"), isOn: $store.s.showVolume)
                Toggle(Loc.t("set_playervolume"), isOn: $store.s.playerVolume)
                    .disabled(!store.s.showVolume)
                Toggle(Loc.t("set_lyrics"), isOn: $store.s.showLyrics)
                Toggle(Loc.t("set_compactlyrics"), isOn: $store.s.compactLyrics)
                    .disabled(!store.s.showLyrics)
                Toggle(Loc.t("set_clock"), isOn: $store.s.showClock)
                Picker(Loc.t("set_openrecent"), selection: $store.s.recentPlatform) {
                    Text(Loc.t("set_auto")).tag("auto")
                    ForEach(Platforms.all) { p in Text(p.name).tag(p.id) }
                }
                hint("set_recenthint")
            }

            Section(Loc.t("set_notifications")) {
                Toggle(Loc.t("set_winnotif"), isOn: $store.s.systemNotifications)
                hint("set_winnotif_hint")
                Toggle(Loc.t("set_dnd"), isOn: $store.s.doNotDisturb)
                LabeledContent(Loc.t("set_duration")) {
                    HStack {
                        Slider(value: $store.s.notificationSeconds, in: 2...15, step: 1)
                        Text("\(Int(store.s.notificationSeconds))" + Loc.t("unit_sec")).monospacedDigit().frame(width: 44, alignment: .trailing)
                    }
                }
                Button(Loc.t("set_test")) {
                    NotificationCenter.default.post(name: .diTestNotification, object: nil)
                }
            }

            Section(Loc.t("set_system")) {
                Toggle(Loc.t("set_top"), isOn: $store.s.alwaysOnTop)
                Toggle(Loc.t("set_fullscreen"), isOn: $store.s.hideInFullscreen)
                Toggle(Loc.t("set_autostart"), isOn: loginBinding)
            }

            Section(Loc.t("set_events")) {
                Toggle(Loc.t("set_ev_layout"), isOn: $store.s.showLayoutChange)
                Toggle(Loc.t("set_ev_power"), isOn: $store.s.showCharging)
                Toggle(Loc.t("set_ev_bt"), isOn: $store.s.showBluetooth)
            }

            Section(Loc.t("set_clicks")) {
                Toggle(Loc.t("set_clickthrough"), isOn: $store.s.clickThrough)
                hint("set_clickhint")
            }

            Section(Loc.t("set_language")) {
                Picker(Loc.t("set_language"), selection: langBinding) {
                    ForEach(Loc.languages.map { $0.id }, id: \.self) { id in
                        Text(Loc.languages.first { $0.id == id }?.name ?? id).tag(id)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            Section {
                VStack(spacing: 3) {
                    Text("created by @vvassuup")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Link("t.me/vvassuup", destination: URL(string: "https://t.me/vvassuup")!)
                        .font(.caption)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 640)
        .id(loc.lang)
    }
}
