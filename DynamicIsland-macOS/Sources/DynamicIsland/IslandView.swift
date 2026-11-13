import SwiftUI
import AppKit

// MARK: - рамки для наведения и кликов сквозь остров

struct IslandFrameKey: PreferenceKey {
    static let defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let n = nextValue()
        if n != .zero { value = n }
    }
}

struct InteractiveKey: PreferenceKey {
    static let defaultValue: [CGRect] = []
    static func reduce(value: inout [CGRect], nextValue: () -> [CGRect]) {
        value.append(contentsOf: nextValue())
    }
}

extension View {
    /// Помечает элемент, который принимает клики даже при включённом «клики сквозь остров».
    func interactive() -> some View {
        background(GeometryReader { g in
            Color.clear.preference(key: InteractiveKey.self, value: [g.frame(in: .global)])
        })
    }
}

struct Theme {
    var fg: Color
    var accent: Color
}

// MARK: - корень

struct IslandRootView: View {
    @ObservedObject var state: IslandState
    @ObservedObject var store = SettingsStore.shared
    @ObservedObject var loc = LocModel.shared

    var body: some View {
        IslandShell(state: state, settings: store.s)
            .id(loc.lang)
            .modifier(IslandScale(scale: store.s.scale))
            .padding(.top, store.s.topOffset)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .onPreferenceChange(IslandFrameKey.self) { state.islandRect = $0 }
            .onPreferenceChange(InteractiveKey.self) { state.interactiveRects = $0 }
    }
}

/// Масштаб острова. При 100% трансформ не применяется вовсе — текст и иконки остаются пиксель-в-пиксель.
struct IslandScale: ViewModifier {
    let scale: Double
    @ViewBuilder
    func body(content: Content) -> some View {
        if abs(scale - 1) < 0.001 {
            content
        } else {
            content.scaleEffect(scale, anchor: .top)
        }
    }
}

struct IslandShell: View {
    @ObservedObject var state: IslandState
    let settings: AppSettings

    enum Mode { case compact, expanded, notification, activity }

    static func cornerRadius(for mode: Mode) -> CGFloat {
        switch mode {
        case .compact: return 17
        case .expanded: return 32
        case .notification: return 28
        case .activity: return 18
        }
    }

    private var mode: Mode {
        if state.notification != nil { return .notification }
        if state.expanded { return .expanded }
        return state.activity != nil ? .activity : .compact
    }

    private var fillNS: NSColor { NSColor(hex: settings.islandColor) ?? .black }

    /// Цвет градиента (nil — сплошной фон).
    private var tintNS: NSColor? {
        switch settings.backgroundStyle {
        case "cover": return state.coverColor
        case "custom": return NSColor(hex: settings.gradientColor) ?? NSColor(hex: "#FF375F")
        default: return nil
        }
    }

    private var theme: Theme {
        var lum = fillNS.luminance
        if let t = tintNS { lum = (lum + fillNS.mixed(with: t, IslandBackground.startMix).luminance) / 2 }
        let light = lum > 0.6 && settings.islandOpacity > 0.5
        let fg: Color = light ? .black : .white
        var accent: Color = Color(nsColor: NSColor(hex: settings.accentColor) ?? .white)
        if settings.accentFromCover, let cc = state.coverColor { accent = Color(nsColor: cc) }
        if light && !settings.accentFromCover && settings.accentColor.uppercased() == "#FFFFFF" { accent = .black }
        return Theme(fg: fg, accent: accent)
    }

    var body: some View {
        let radius: CGFloat = Self.cornerRadius(for: mode)
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        let th = theme
        ZStack {
            switch mode {
            case .compact:
                CompactView(state: state, settings: settings, theme: th)
                    .transition(.opacity)
            case .expanded:
                ExpandedView(state: state, settings: settings, theme: th)
                    .transition(.opacity)
            case .notification:
                if let n = state.notification {
                    NotificationView(state: state, item: n, theme: th)
                        .transition(.opacity)
                }
            case .activity:
                if let a = state.activity {
                    ActivityView(item: a, theme: th)
                        .transition(.opacity)
                }
            }
        }
        .foregroundColor(th.fg)
        .clipShape(shape)
        // фон и свечение рисуются отдельным слоем под содержимым: тень не затрагивает текст и иконки
        .background(
            IslandBackground(base: fillNS, tint: tintNS, opacity: settings.islandOpacity, radius: radius)
                .shadow(color: settings.coverGlow ? th.accent.opacity(0.6) : .clear, radius: 22)
                .shadow(color: settings.coverGlow ? th.accent.opacity(0.35) : .clear, radius: 8)
                .shadow(color: settings.shadow ? Color.black.opacity(0.45) : .clear, radius: 12, y: 5)
        )
        .background(GeometryReader { g in
            Color.clear.preference(key: IslandFrameKey.self, value: g.frame(in: .global))
        })
        .animation(.spring(response: 0.42, dampingFraction: 0.8), value: mode)
    }
}

/// Фон острова: сплошной или градиент (оттенок цвета слева сверху → цвет панели справа снизу).
struct IslandBackground: View {
    static let startMix: CGFloat = 0.45
    let base: NSColor
    let tint: NSColor?
    let opacity: Double
    let radius: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        Group {
            if let tint {
                shape.fill(LinearGradient(stops: [
                    .init(color: Color(nsColor: base.mixed(with: tint, Self.startMix)), location: 0),
                    .init(color: Color(nsColor: base.mixed(with: tint, 0.17)), location: 0.55),
                    .init(color: Color(nsColor: base.mixed(with: tint, 0)), location: 1),
                ], startPoint: .topLeading, endPoint: .bottomTrailing))
            } else {
                shape.fill(Color(nsColor: base))
            }
        }
        .opacity(opacity)
        .animation(.easeInOut(duration: 0.7), value: tint?.hexString ?? "")
    }
}

// MARK: - общие элементы

struct Artwork: View {
    let image: NSImage?
    let size: CGFloat
    let radius: CGFloat
    var fg: Color = .white

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    fg.opacity(0.12)
                    Image(systemName: "music.note").font(.system(size: size * 0.42, weight: .semibold)).foregroundColor(fg.opacity(0.6))
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

/// Обложка; в режиме «пластинка» — круглая и вращается во время воспроизведения.
struct CoverView: View {
    let image: NSImage?
    let size: CGFloat
    let vinyl: Bool
    let playing: Bool
    let fg: Color
    var radius: CGFloat = 12

    var body: some View {
        if vinyl {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !playing)) { ctx in
                let angle = (ctx.date.timeIntervalSinceReferenceDate * 40).truncatingRemainder(dividingBy: 360)
                let small = size < 40
                let label = size * (small ? 0.72 : 0.92)
                let hole = max(4, size * (small ? 0.22 : 0.16))
                ZStack {
                    Circle().fill(Color(white: 0.06))
                    // бороздки винила
                    Circle().stroke(Color.white.opacity(small ? 0.16 : 0.06), lineWidth: small ? 0.75 : 1).padding(size * 0.06)
                    Artwork(image: image, size: label, radius: size, fg: fg)
                    Circle().stroke(Color.white.opacity(0.08), lineWidth: 1).padding(size * 0.16)
                    Circle().fill(Color.black).frame(width: hole, height: hole)
                    Circle().stroke(Color.white.opacity(0.3), lineWidth: small ? 0.75 : 1).frame(width: hole, height: hole)
                }
                .frame(width: size, height: size)
                .rotationEffect(.degrees(angle))
            }
            .frame(width: size, height: size)
        } else {
            Artwork(image: image, size: size, radius: radius, fg: fg)
        }
    }
}

struct Equalizer: View {
    let playing: Bool
    let color: Color
    var bars: Int = 4
    var height: CGFloat = 12

    private static let speeds: [Double] = [7.1, 9.3, 6.2, 8.4, 10.1]
    private static let phases: [Double] = [0, 1.3, 2.1, 0.7, 2.8]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !playing)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 2) {
                ForEach(0..<bars, id: \.self) { i in
                    let k = playing ? 0.3 + 0.7 * abs(sin(t * Self.speeds[i % 5] + Self.phases[i % 5])) : 0.25
                    Capsule().fill(color).frame(width: 3, height: max(3, height * k))
                }
            }
            .frame(height: height)
        }
    }
}

struct ClockView: View {
    private static let fmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    var body: some View {
        TimelineView(.periodic(from: Date(), by: 1)) { ctx in
            Text(Self.fmt.string(from: ctx.date))
                .font(.system(size: 14, weight: .semibold, design: .rounded).monospacedDigit())
        }
    }
}

struct IconButton: View {
    let symbol: String
    var size: CGFloat = 13
    var active: Bool = false
    let theme: Theme
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .symbolRenderingMode(.monochrome)
                .font(.system(size: size + 1, weight: .medium))
                .foregroundColor(active ? theme.accent : theme.fg.opacity(0.85))
                .frame(width: 28, height: 28)
                .background(Circle().fill(theme.fg.opacity(active ? 0.16 : 0.08)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .interactive()
    }
}

struct TabButton: View {
    let title: String
    let selected: Bool
    let theme: Theme
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(selected ? theme.fg : theme.fg.opacity(0.5))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Capsule().fill(theme.fg.opacity(selected ? 0.14 : 0)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .interactive()
    }
}

enum Fmt {
    static func time(_ s: Double) -> String {
        let v = max(0, Int(s.rounded(.down)))
        let h = v / 3600, m = (v % 3600) / 60, sec = v % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }

    static func gb(_ bytes: UInt64, decimal: Bool = false) -> String {
        String(format: "%.1f", Double(bytes) / (decimal ? 1_000_000_000 : 1_073_741_824))
    }

    static func speed(_ bps: Double) -> String {
        if bps >= 1_048_576 { return String(format: "%.1f", bps / 1_048_576) + Loc.t("unit_mbs") }
        return String(format: "%.0f", bps / 1024) + Loc.t("unit_kbs")
    }
}

// MARK: - свёрнутый остров

struct CompactView: View {
    @ObservedObject var state: IslandState
    let settings: AppSettings
    let theme: Theme

    var body: some View {
        let lyric = settings.showLyrics && settings.compactLyrics ? state.currentLyric : ""
        if let t = state.track, !lyric.isEmpty {
            HStack(spacing: 8) {
                CoverView(image: t.artwork, size: 22, vinyl: settings.vinylCover, playing: t.isPlaying, fg: theme.fg, radius: 6)
                Text(lyric)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)
                    .id(lyric)
                    .transition(.opacity)
                Equalizer(playing: t.isPlaying, color: theme.accent, bars: 4, height: 12)
            }
            .padding(.horizontal, 7)
            .frame(width: 330, height: 36)
            .animation(.easeInOut(duration: 0.25), value: lyric)
        } else if let t = state.track {
            HStack(spacing: 6) {
                CoverView(image: t.artwork, size: 22, vinyl: settings.vinylCover, playing: t.isPlaying, fg: theme.fg, radius: 6)
                Spacer(minLength: 0)
                if settings.showClock {
                    ClockView().font(.system(size: 12))
                    Spacer(minLength: 0)
                }
                Equalizer(playing: t.isPlaying, color: theme.accent, bars: 4, height: 12)
            }
            .padding(.horizontal, 7)
            .frame(width: settings.showClock ? 150 : 120, height: 34)
        } else if settings.showClock {
            ClockView().frame(width: 120, height: 34)
        } else {
            Color.clear.frame(width: 120, height: 34)
        }
    }
}

// MARK: - развёрнутый остров

struct ExpandedView: View {
    @ObservedObject var state: IslandState
    let settings: AppSettings
    let theme: Theme

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 4) {
                TabButton(title: Loc.t("tab_music"), selected: state.page == .music && !state.showRecent, theme: theme) {
                    state.showRecent = false
                    state.page = .music
                }
                TabButton(title: Loc.t("tab_system"), selected: state.page == .system && !state.showRecent, theme: theme) {
                    state.showRecent = false
                    state.page = .system
                }
                Spacer()
                IconButton(symbol: "clock.arrow.circlepath", active: state.showRecent, theme: theme) {
                    withAnimation(.easeInOut(duration: 0.2)) { state.showRecent.toggle() }
                }
                .help(Loc.t("tip_recent"))
                IconButton(symbol: "gearshape", theme: theme) {
                    NotificationCenter.default.post(name: .diOpenSettings, object: nil)
                }
                .help(Loc.t("tip_settings"))
            }

            Group {
                if state.showRecent {
                    RecentView(state: state, theme: theme)
                } else if state.page == .music {
                    MusicView(state: state, settings: settings, theme: theme)
                } else {
                    SystemView(state: state, theme: theme)
                }
            }
            .transition(.opacity)
        }
        .padding(18)
        .frame(width: 400)
    }
}

struct MusicView: View {
    @ObservedObject var state: IslandState
    let settings: AppSettings
    let theme: Theme

    var body: some View {
        if let t = state.track {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    CoverView(image: t.artwork, size: 58, vinyl: settings.vinylCover, playing: t.isPlaying, fg: theme.fg)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(t.title.isEmpty ? Loc.t("media_untitled") : t.title)
                            .font(.system(size: 15, weight: .semibold)).lineLimit(1)
                        if !t.artist.isEmpty {
                            Text(t.artist).font(.system(size: 12)).foregroundColor(theme.fg.opacity(0.65)).lineLimit(1)
                        }
                        Text(t.platformLabel(state.platform))
                            .font(.system(size: 10, weight: .medium)).foregroundColor(theme.accent.opacity(0.9)).lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    if settings.showVolume && state.volumeControllable {
                        VolumePill(state: state, theme: theme)
                    } else {
                        Equalizer(playing: t.isPlaying, color: theme.accent, bars: 5, height: 18)
                    }
                }

                if settings.showLyrics && !state.lyrics.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(state.currentLyric.isEmpty ? "♪" : state.currentLyric)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(theme.accent)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                        if !state.nextLyric.isEmpty {
                            Text(state.nextLyric).font(.system(size: 12)).foregroundColor(theme.fg.opacity(0.45)).lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .animation(.easeInOut(duration: 0.25), value: state.lyricIndex)
                }

                if t.duration > 0 {
                    SeekBar(state: state, duration: t.duration, theme: theme)
                }

                HStack(spacing: 34) {
                    Spacer()
                    ControlButton(symbol: "backward.fill", size: 18, theme: theme) { state.media.previous() }
                    ControlButton(symbol: t.isPlaying ? "pause.fill" : "play.fill", size: 26, theme: theme) { state.togglePlayPause() }
                    ControlButton(symbol: "forward.fill", size: 18, theme: theme) { state.media.next() }
                    Spacer()
                }
            }
        } else {
            VStack(spacing: 6) {
                Image(systemName: "music.note").font(.system(size: 22, weight: .semibold)).foregroundColor(theme.fg.opacity(0.4))
                Text(Loc.t("media_nothing")).font(.system(size: 14, weight: .semibold))
                Text(Loc.t("media_hint")).font(.system(size: 11.5)).foregroundColor(theme.fg.opacity(0.5)).multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 22)
        }
    }
}

/// Маленький вертикальный ползунок громкости в стиле «Пункта управления» iPhone.
/// Тяните вверх/вниз или крутите колесо мыши; щелчок — вкл./выкл. звук.
struct VolumePill: View {
    @ObservedObject var state: IslandState
    let theme: Theme

    @State private var hover = false
    @State private var dragStart: Double?
    @State private var moved = false
    @State private var scrollMonitor: Any?

    private var active: Bool { hover || dragStart != nil }
    private var width: CGFloat { active ? 20 : 16 }
    private var height: CGFloat { active ? 52 : 44 }

    var body: some View {
        let frac = state.muted ? 0 : min(1, max(0, state.volume))
        ZStack(alignment: .bottom) {
            Rectangle().fill(theme.fg.opacity(0.16))
            Rectangle().fill(theme.fg).frame(height: height * frac)
            Image(systemName: symbol(frac))
                .font(.system(size: active ? 9 : 7.5, weight: .bold))
                .foregroundColor(frac > 0.22 ? Color.black.opacity(0.55) : theme.fg.opacity(0.6))
                .padding(.bottom, active ? 6 : 5)
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: width / 2.6, style: .continuous))
        .frame(width: 22, height: 54)
        .contentShape(Rectangle())
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: active)
        .animation(.easeOut(duration: 0.12), value: frac)
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { v in
                    if dragStart == nil {
                        dragStart = state.muted ? 0 : state.volume
                        moved = false
                        state.volumeBegan()
                    }
                    if abs(v.translation.height) > 2 { moved = true }
                    guard moved, let start = dragStart else { return }
                    // относительное перетаскивание, как на iPhone: палец не «прыгает» к точке
                    state.volumeChanged(start - Double(v.translation.height / height))
                }
                .onEnded { _ in
                    if !moved { state.toggleMute() }
                    dragStart = nil
                    state.volumeEnded()
                }
        )
        .onHover { h in
            hover = h
            h ? installScroll() : removeScroll()
        }
        .onDisappear { removeScroll() }
        .interactive()
        .help(volumeTitle + " \(Int((frac * 100).rounded()))%")
        .accessibilityElement()
        .accessibilityLabel(Loc.t("volume"))
        .accessibilityValue("\(Int((frac * 100).rounded()))%")
        .accessibilityAdjustableAction { dir in
            switch dir {
            case .increment: state.volumeChanged(state.volume + 0.0625)
            case .decrement: state.volumeChanged(state.volume - 0.0625)
            @unknown default: break
            }
        }
    }

    private var volumeTitle: String {
        if let app = state.playerVolumeApp, let name = AppInfo.displayName(app) { return Loc.f("volume_of", name) }
        return Loc.t("volume")
    }

    private func symbol(_ f: Double) -> String {
        if f <= 0.001 { return "speaker.slash.fill" }
        if f < 0.34 { return "speaker.wave.1.fill" }
        if f < 0.67 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }

    private func installScroll() {
        guard scrollMonitor == nil else { return }
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { e in
            let dy = e.hasPreciseScrollingDeltas ? Double(e.scrollingDeltaY) / 300 : Double(e.scrollingDeltaY) / 25
            let sign: Double = e.isDirectionInvertedFromDevice ? -1 : 1
            if dy != 0 { state.volumeChanged((state.muted ? 0 : state.volume) + dy * sign) }
            return nil
        }
    }

    private func removeScroll() {
        if let m = scrollMonitor { NSEvent.removeMonitor(m) }
        scrollMonitor = nil
    }
}

struct ControlButton: View {
    let symbol: String
    let size: CGFloat
    let theme: Theme
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .frame(width: size + 20, height: size + 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundColor(theme.fg)
        .interactive()
    }
}

struct SeekBar: View {
    @ObservedObject var state: IslandState
    let duration: Double
    let theme: Theme
    @State private var dragValue: Double?

    var body: some View {
        let pos = dragValue ?? state.position
        let frac = duration > 0 ? min(1, max(0, pos / duration)) : 0
        VStack(spacing: 4) {
            GeometryReader { g in
                let w = g.size.width
                let thumb: CGFloat = dragValue != nil ? 12 : 8
                ZStack(alignment: .leading) {
                    Capsule().fill(theme.fg.opacity(0.18)).frame(height: 4)
                    Capsule().fill(theme.accent).frame(width: max(4, w * frac), height: 4)
                    Circle().fill(theme.fg).frame(width: thumb, height: thumb)
                        .offset(x: min(max(0, w * frac - thumb / 2), w - thumb))
                }
                .frame(width: w, height: 16)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { v in
                            if dragValue == nil { state.seekBegan() }
                            let x = min(max(0, v.location.x), w)
                            let val = w > 0 ? Double(x / w) * duration : 0
                            dragValue = val
                            state.seekChanged(val)
                        }
                        .onEnded { _ in
                            let val = dragValue ?? pos
                            dragValue = nil
                            state.seekEnded(val)
                        }
                )
            }
            .frame(height: 16)

            HStack {
                Text(Fmt.time(pos))
                Spacer()
                Text("-" + Fmt.time(max(0, duration - pos)))
            }
            .font(.system(size: 10, weight: .medium).monospacedDigit())
            .foregroundColor(theme.fg.opacity(0.55))
        }
        .interactive()
    }
}

struct RecentView: View {
    @ObservedObject var state: IslandState
    let theme: Theme

    var body: some View {
        let items = Array(state.recent.filter { $0.id != state.track?.key }.prefix(IslandState.maxRecent))
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(Loc.t("recent_title")).font(.system(size: 13, weight: .semibold))
                Spacer()
                Text(Loc.t("recent_rmb")).font(.system(size: 10)).foregroundColor(theme.fg.opacity(0.45))
            }
            if items.isEmpty {
                Text(Loc.t("recent_empty"))
                    .font(.system(size: 12))
                    .foregroundColor(theme.fg.opacity(0.5))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 18)
            } else {
                ForEach(items) { r in
                    RecentRow(state: state, item: r, theme: theme)
                }
            }
        }
    }
}

struct RecentRow: View {
    @ObservedObject var state: IslandState
    let item: RecentItem
    let theme: Theme
    @State private var hover = false

    var body: some View {
        HStack(spacing: 10) {
            Artwork(image: item.artwork, size: 32, radius: 7, fg: theme.fg)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title.isEmpty ? Loc.t("media_untitled") : item.title)
                    .font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                if !item.artist.isEmpty {
                    Text(item.artist).font(.system(size: 11)).foregroundColor(theme.fg.opacity(0.55)).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if let p = item.platform {
                Text(Platforms.short(p))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(theme.fg.opacity(0.7))
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Capsule().fill(theme.fg.opacity(0.1)))
            }
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(theme.fg.opacity(hover ? 0.09 : 0)))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { state.openRecent(item) }
        .contextMenu {
            ForEach(Platforms.all) { p in
                Button(Loc.f("menu_openin", p.name)) { state.open(item, in: p.id) }
            }
            Divider()
            Button(Loc.t("menu_copy")) { state.copyTitle(item) }
        }
        .interactive()
    }
}

struct SystemView: View {
    @ObservedObject var state: IslandState
    let theme: Theme

    private var uptime: String {
        let u = Int(state.sys.uptime)
        let d = u / 86400, h = (u % 86400) / 3600, m = (u % 3600) / 60
        return d > 0 ? Loc.f("sys_uptime_days", d, h) : Loc.f("sys_uptime_hours", h, m)
    }

    var body: some View {
        let s = state.sys
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(Loc.t("sys_title")).font(.system(size: 13, weight: .semibold))
                Spacer()
                Text(uptime).font(.system(size: 10.5)).foregroundColor(theme.fg.opacity(0.5))
            }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                StatCard(title: Loc.t("sys_cpu"), value: "\(Int(s.cpu.rounded()))%",
                         sub: Loc.f("sys_threads", s.threads), frac: s.cpu / 100, theme: theme)
                StatCard(title: Loc.t("sys_ram"), value: "\(Int(s.ram.rounded()))%",
                         sub: Loc.f("sys_ramsub", Fmt.gb(s.ramUsed), Fmt.gb(s.ramTotal)), frac: s.ram / 100, theme: theme)
                StatCard(title: Loc.t("sys_disk"), value: "\(Int(s.disk.rounded()))%",
                         sub: Loc.f("sys_disksub", s.diskName, Fmt.gb(UInt64(max(0, s.diskFree)), decimal: true)),
                         frac: s.disk / 100, theme: theme)
                StatCard(title: Loc.t("sys_net"), value: "↓ " + Fmt.speed(s.down),
                         sub: "↑ " + Fmt.speed(s.up), frac: nil, theme: theme)
                if s.battery >= 0 {
                    StatCard(title: Loc.t("sys_battery"), value: "\(s.battery)%",
                             sub: s.charging ? "⚡︎" + Loc.t("sys_charging") : " ",
                             frac: Double(s.battery) / 100, theme: theme)
                }
            }
        }
    }
}

struct StatCard: View {
    let title: String
    let value: String
    let sub: String
    let frac: Double?
    let theme: Theme

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 9.5, weight: .semibold)).tracking(0.6).foregroundColor(theme.fg.opacity(0.5))
            Text(value).font(.system(size: 17, weight: .semibold, design: .rounded).monospacedDigit()).lineLimit(1)
            if let frac {
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(theme.fg.opacity(0.14))
                        Capsule().fill(theme.accent).frame(width: max(3, g.size.width * min(1, max(0, frac))))
                    }
                }
                .frame(height: 4)
            }
            Text(sub).font(.system(size: 10)).foregroundColor(theme.fg.opacity(0.55)).lineLimit(1)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(theme.fg.opacity(0.07)))
    }
}

// MARK: - уведомление

struct NotificationView: View {
    @ObservedObject var state: IslandState
    let item: NotificationItem
    let theme: Theme

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Group {
                if let icon = item.icon {
                    Image(nsImage: icon).resizable().aspectRatio(contentMode: .fit)
                } else {
                    Image(systemName: "bell.fill").font(.system(size: 18)).foregroundColor(theme.accent)
                }
            }
            .frame(width: 38, height: 38)

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(item.appName).font(.system(size: 10.5, weight: .semibold)).foregroundColor(theme.fg.opacity(0.55)).lineLimit(1)
                    Spacer()
                    Text(Loc.t("notif_now")).font(.system(size: 10)).foregroundColor(theme.fg.opacity(0.4))
                }
                Text(item.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                if !item.body.isEmpty {
                    Text(item.body).font(.system(size: 12)).foregroundColor(theme.fg.opacity(0.75)).lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(14)
        .frame(width: 380, alignment: .leading)
        .frame(minHeight: 66)
        .contentShape(Rectangle())
        .onTapGesture { state.dismissNotification() }
        .interactive()
    }
}

/// «Живое» событие: значок · подпись … значение (например, ⌨︎ Русский … RU).
struct ActivityView: View {
    let item: LiveActivity
    let theme: Theme

    var body: some View {
        let tint = item.tint ?? theme.accent
        HStack(spacing: 9) {
            Image(systemName: item.symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(tint)
            Text(item.title)
                .font(.system(size: 12.5, weight: .semibold))
                .lineLimit(1)
                .frame(minWidth: 120, maxWidth: 190, alignment: .leading)
            Spacer(minLength: 18)
            Text(item.value)
                .font(.system(size: 13.5, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundColor(tint)
        }
        .padding(.horizontal, 14)
        .fixedSize()
        .frame(height: 36)
    }
}
