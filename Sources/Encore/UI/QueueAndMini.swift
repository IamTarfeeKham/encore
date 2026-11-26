import Combine
import SwiftUI

// MARK: - Playing Next (queue inspector)

struct QueueView: View {
    /// The tallest the panel may get; it is shorter when there's less to show.
    var maxHeight: CGFloat = .infinity
    @EnvironmentObject var player: PlayerController
    @State private var tab = 0

    // Fixed row metrics (QueueRow: 36 pt artwork + 8 pt padding + 2 pt insets,
    // plus the list's spacing), used to size the panel to its content.
    private static let pickerHeight: CGFloat = 56
    private static let rowHeight: CGFloat = 50
    private static let headerHeight: CGFloat = 44
    private static let bottomPadding: CGFloat = 14

    private var contentHeight: CGFloat {
        if tab == 0 {
            var h = Self.pickerHeight + Self.headerHeight + Self.bottomPadding
            if player.current != nil { h += Self.headerHeight + Self.rowHeight }
            h += player.upNext.isEmpty ? 34 : CGFloat(player.upNext.count) * Self.rowHeight
            return h
        }
        return Self.pickerHeight + Self.bottomPadding + max(120, CGFloat(player.history.count) * Self.rowHeight)
    }

    var body: some View {
        VStack(spacing: 0) {
            PillPicker(selection: $tab, options: [(0, "Playing Next", "list.bullet"), (1, "History", "clock")])
                .padding(12)
            if tab == 0 { upNext } else { history }
        }
        .frame(height: max(180, min(maxHeight, contentHeight)))
        .animation(.easeInOut(duration: 0.25), value: contentHeight)
    }

    private var upNext: some View {
        // Section titles are ordinary rows on frosted glass (the list's own sticky
        // section headers draw an opaque black bar and covered the current song).
        List {
            if let cur = player.current {
                QueueHeader(title: "Now Playing") { EmptyView() }
                QueueRow(track: cur, isCurrent: true)
            }
            QueueHeader(title: "Playing Next") {
                HStack(spacing: 2) {
                    Button { player.toggleShuffle() } label: { Image(systemName: "shuffle") }
                        .foregroundStyle(player.shuffle ? Color.accentColor : .secondary).help("Shuffle")
                    Button { player.repeatMode = player.repeatMode.next } label: { Image(systemName: player.repeatMode.symbol) }
                        .foregroundStyle(player.repeatMode != .off ? Color.accentColor : .secondary).help("Repeat")
                    Button { player.autoplay.toggle() } label: { Image(systemName: "infinity") }
                        .foregroundStyle(player.autoplay ? Color.accentColor : .secondary)
                        .help("Autoplay: keep playing similar music when the queue ends")
                }
                .buttonStyle(BarIconStyle(size: 11, diameter: 24))
                Button("Clear") { player.clearUpNext() }
                    .buttonStyle(TextLinkStyle())
                    .disabled(player.upNext.isEmpty)
            }
            ForEach(Array(player.upNext)) { t in
                QueueRow(track: t, isCurrent: false)
                    .onTapGesture(count: 2) { player.jump(to: t) }
                    .contextMenu {
                        Button("Play Now") { player.jump(to: t) }
                        Button("Remove from Queue", role: .destructive) { player.remove(t) }
                    }
            }
            .onMove { player.moveUpNext(from: $0, to: $1) }
            .onDelete { idx in
                let items = Array(player.upNext)
                idx.map { items[$0] }.forEach(player.remove)
            }
            if player.upNext.isEmpty {
                Text(player.autoplay ? "Similar music will play next." : "Nothing queued.")
                    .foregroundStyle(.secondary).font(.callout)
                    .listRowBackground(Color.clear)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, 1)
    }

    private var history: some View {
        List(player.history) { t in
            QueueRow(track: t, isCurrent: false)
                .onTapGesture(count: 2) { player.play(tracks: [t]) }
                .contextMenu {
                    Button("Play") { player.play(tracks: [t]) }
                    Button("Play Next") { player.playNext([t]) }
                }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .overlay { if player.history.isEmpty { Text("Songs you play appear here.").foregroundStyle(.secondary) } }
    }
}

struct QueueRow: View {
    let track: Track
    let isCurrent: Bool
    @EnvironmentObject var player: PlayerController
    @State private var hover = false
    var body: some View {
        HStack(spacing: 10) {
            Artwork(url: track.thumbnail, cornerRadius: 4).frame(width: 36, height: 36)
                .overlay { if isCurrent { RoundedRectangle(cornerRadius: 4).fill(.black.opacity(0.4)); PlayingBars(animating: player.isPlaying).foregroundStyle(.white) } }
            VStack(alignment: .leading, spacing: 1) {
                Text(track.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Text(track.artistLine).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if let d = track.duration { Text(formatTime(d)).font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary).fixedSize() }
        }
        .padding(.horizontal, 6).padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hover ? Color.primary.opacity(0.08) : .clear))
        .onHover { hover = $0 }
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 1, leading: 8, bottom: 1, trailing: 8))
        .contentShape(Rectangle())
    }
}

// MARK: - Mini player window

/// Compact always-on-top player: artwork card over the song's colour glow,
/// title, progress, transport and like — nothing else.
struct MiniPlayerView: View {
    @EnvironmentObject var player: PlayerController
    @ObservedObject private var prefs = Prefs.shared
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hover = false

    var body: some View {
        ZStack {
            if !prefs.glassMiniPlayers {
                AmbientBackground(artwork: player.current?.largeArtwork, dim: 0.34, parallax: 0.4, energy: 1.4)
            }
            VStack(spacing: 14) {
                // The same breathing cover as the Artwork view (Core Animation, nearly free).
                TiltingArtwork(url: player.current?.largeArtwork, side: 248,
                               breathing: player.isPlaying && prefs.artworkMotion && !reduceMotion)
                    .scaleEffect(player.isPlaying ? 1 : 0.94)
                    .animation(.spring(duration: 0.5, bounce: 0.25), value: player.isPlaying)
                    .padding(.top, 30)
                VStack(spacing: 3) {
                    Text(player.current?.title ?? "Not Playing").font(.system(size: 15, weight: .bold)).lineLimit(1)
                    Text(player.current?.artistLine ?? "").font(.system(size: 12.5)).foregroundStyle(.white.opacity(0.65)).lineLimit(1)
                }
                .padding(.horizontal, 20)
                ScrubberBar().padding(.horizontal, 16)
                HStack(spacing: 18) {
                    Button { player.toggleLike() } label: {
                        Image(systemName: player.likeStatus == .like ? "hand.thumbsup.fill" : "hand.thumbsup")
                    }
                    .buttonStyle(BarIconStyle(size: 13))
                    .hoverTip("Like")
                    TransportControls(size: .regular, showShuffleRepeat: false)
                    Button { openFullPlayer() } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                    }
                    .buttonStyle(BarIconStyle(size: 12))
                    .hoverTip("Open full player")
                }
                .padding(.bottom, 18)
            }
            .foregroundStyle(.white)
            MiniWindowButtons(close: { fadeOut { dismissWindow(id: "mini") } },
                              minimize: { NSApp.windows.first { $0.title == "Mini Player" }?.miniaturize(nil) },
                              expand: { openFullPlayer() })
                .padding(.leading, 12).padding(.top, 11)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(width: 300, height: 470)
        .ignoresSafeArea()
        .playerSurface(glass: prefs.glassMiniPlayers, radius: 24)
        .environment(\.colorScheme, .dark)
        .background(FloatingWindow())
        .background(RoundedWindow(radius: 24))
        .onAppear { MiniPlayer.show() }
    }

    private func fadeOut(then done: @escaping () -> Void) {
        if let w = MiniPlayer.window { MiniPlayer.close(w, then: done) } else { done() }
    }

    private func openFullPlayer() {
                        // Back to the main window, straight into Now Playing; the mini player
                        // fades out. If the main window was hidden, Now Playing is already in
                        // place when it appears (no slide racing the window); if it's on screen,
                        // Now Playing slides up as usual.
                        WindowOpener.open = WindowOpener.open ?? openWindow
                        let mainOnScreen = WindowOpener.mainWindow.map { $0.isVisible && !$0.isMiniaturized && !NSApp.isHidden } ?? false
                        if mainOnScreen {
                            withAnimation(.spring(duration: 0.45, bounce: 0.12)) { AppModel.shared.showNowPlaying = true }
                        } else {
                            var t = Transaction(); t.disablesAnimations = true
                            withTransaction(t) { AppModel.shared.showNowPlaying = true }
                        }
                        WindowOpener.showMain()
                        fadeOut { dismissWindow(id: "mini") }
    }
}

/// Larger window buttons for the mini player (macOS's own are fixed at 12 pt):
/// close, minimise, and green opens the full player. Symbols show on hover, like
/// the system ones.
private struct MiniWindowButtons: View {
    let close: () -> Void
    let minimize: () -> Void
    let expand: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: 9) {
            dot(Color(red: 1, green: 0.37, blue: 0.34), "xmark", "Close", close)
            dot(Color(red: 1, green: 0.74, blue: 0.18), "minus", "Minimise", minimize)
            dot(Color(red: 0.16, green: 0.79, blue: 0.25), "arrow.up.left.and.arrow.down.right", "Open full player", expand)
        }
        .onHover { hover = $0 }
    }

    private func dot(_ color: Color, _ symbol: String, _ label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Circle().fill(color)
                .overlay(Circle().strokeBorder(.black.opacity(0.18), lineWidth: 0.5))
                .overlay(Image(systemName: symbol).font(.system(size: 8, weight: .heavy))
                    .foregroundStyle(.black.opacity(0.6)).opacity(hover ? 1 : 0))
                .frame(width: 16, height: 16)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// Keeps the mini player above other windows and draggable by its background.
struct FloatingWindow: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async {
            guard let w = v.window else { return }
            w.level = .floating
            w.isMovableByWindowBackground = true
            w.titlebarAppearsTransparent = true
            w.collectionBehavior.insert(.canJoinAllSpaces)
            w.backgroundColor = .clear
            w.isOpaque = false
            // No system frame (its corners don't match ours): the window is just the
            // rounded card, with our own buttons and a shadow that follows its shape.
            w.styleMask = [.borderless, .fullSizeContentView, .miniaturizable]
            MiniPlayer.installKeyHandling()
            w.hasShadow = true
            w.invalidateShadow()
            // Measure the shadow again once the rounded glass has drawn (measured too
            // early it takes the plain rectangle's shape and shows at the corners).
            for delay in [0.15, 0.6] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak w] in w?.invalidateShadow() }
            }
            // Track open/closed from the window itself (SwiftUI doesn't always report it).
            AppModel.shared.miniPlayerOpen = true
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
                MainActor.assumeIsolated { AppModel.shared.miniPlayerOpen = false }
            }
            // Our own larger buttons replace the system's small ones.
            for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                w.standardWindowButton(kind)?.isHidden = true
            }
            // Fade in (no pop), and fade out on close.
            w.animationBehavior = .utilityWindow
            w.alphaValue = 0
            MiniPlayer.fade(w, to: 1, duration: 0.22)
        }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// Opens the mini player, or closes it (with a fade) if it's already open.
@MainActor
enum MiniPlayer {
    static var window: NSWindow? { NSApp.windows.first { $0.title == "Mini Player" } }

    /// The mini player has no title bar, so it can't take the keyboard and ⌘W/⌘M
    /// would reach the main window. Instead: after you click the mini player (until
    /// you click another window), ⌘W fades it closed and ⌘M minimises it.
    private static var lastClicked = false
    private static var monitors: [Any] = []

    static func installKeyHandling() {
        guard monitors.isEmpty else { return }
        if let m = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { e in
            MainActor.assumeIsolated { lastClicked = e.window != nil && e.window === window }
            return e
        }) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { e in
            MainActor.assumeIsolated {
                guard lastClicked, let w = window, w.isVisible,
                      e.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command else { return e }
                switch e.charactersIgnoringModifiers?.lowercased() {
                case "w": lastClicked = false; close(w); return nil
                case "m": w.miniaturize(nil); return nil
                default: return e
                }
            }
        }) { monitors.append(m) }
    }

    static func toggle(_ open: OpenWindowAction) {
        if let w = window, w.isVisible, w.alphaValue > 0.5 {
            close(w)
        } else {
            open(id: "mini")
            show()
        }
    }

    /// SwiftUI may reuse the window it hid last time: make sure it's visible and
    /// fade it in.
    static func show() {
        AppModel.shared.miniPlayerOpen = true
        DispatchQueue.main.async {
            guard let w = window else { return }
            // A window SwiftUI kept from last time may still be ordered out.
            if !w.isVisible { w.alphaValue = 0; w.orderFrontRegardless() }
            if w.alphaValue < 0.99 {
                w.alphaValue = 0
                fade(w, to: 1, duration: 0.22)
            }
        }
    }

    /// Fade out, close, and leave the window ready to show again.
    static func close(_ w: NSWindow, then done: (() -> Void)? = nil) {
        fade(w, to: 0, duration: 0.2) {
            if let done { done() } else { w.close() }
            w.orderOut(nil)
            w.alphaValue = 1
            AppModel.shared.miniPlayerOpen = false
        }
    }

    /// Fades the window's opacity with an ease-out curve. (AppKit's own window
    /// animator can't handle the keyboard-ready window class, so this steps it.)
    static func fade(_ w: NSWindow, to target: CGFloat, duration: Double, then done: (() -> Void)? = nil) {
        let start = w.alphaValue, began = CACurrentMediaTime()
        Timer.scheduledTimer(withTimeInterval: 1.0 / 120, repeats: true) { t in
            MainActor.assumeIsolated {
                let p = min((CACurrentMediaTime() - began) / duration, 1)
                let eased = 1 - pow(1 - p, 3)
                w.alphaValue = start + (target - start) * eased
                if p >= 1 { t.invalidate(); done?() }
            }
        }
    }
}

// MARK: - Menu bar player

struct MenuBarPlayerView: View {
    @EnvironmentObject var player: PlayerController
    @EnvironmentObject var model: AppModel
    @ObservedObject private var prefs = Prefs.shared
    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 12) {
                // The same breathing cover as the Artwork view and mini player.
                TiltingArtwork(url: player.current?.largeArtwork, side: 64,
                               breathing: player.isPlaying && prefs.artworkMotion && !reduceMotion)
                    .scaleEffect(player.isPlaying ? 1 : 0.94)
                    .animation(.spring(duration: 0.5, bounce: 0.25), value: player.isPlaying)
                VStack(alignment: .leading, spacing: 3) {
                    Text(player.current?.title ?? "Not Playing").font(.system(size: 13.5, weight: .semibold)).lineLimit(2)
                    Text(player.current?.artistLine ?? "").font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                Button { player.toggleLike() } label: {
                    Image(systemName: player.likeStatus == .like ? "hand.thumbsup.fill" : "hand.thumbsup")
                }
                .buttonStyle(BarIconStyle(size: 13))
            }
            ScrubberBar()                                    // one time display, same bar as the main window
            TransportControls(size: .regular, spread: true)
            VolumeControl()
            Divider()
            HStack {
                Button { WindowOpener.open = WindowOpener.open ?? openWindow; WindowOpener.showMain() } label: {
                    Label("Open \(AppInfo.name)", systemImage: "macwindow")
                }
                Spacer()
                Button { NSApp.terminate(nil) } label: { Label("Quit", systemImage: "power") }
            }
            .buttonStyle(TextLinkStyle())
        }
        .padding(16)
        .frame(width: 320)
        // Cover-tinted Liquid Glass (or, with glass off, the cover's colours).
        .background {
            if !prefs.glassMiniPlayers {
                AmbientBackground(artwork: player.current?.largeArtwork, dim: 0.42, parallax: 0, energy: 1.2)
            }
        }
        .playerSurface(glass: prefs.glassMiniPlayers, radius: 18)
        .background(RoundedWindow(radius: 18))
        .environment(\.colorScheme, .dark)
    }
}

/// A queue section title on a frosted-glass bar, with optional trailing controls.
struct QueueHeader<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            trailing()
        }
        .padding(.horizontal, 12)
        .frame(height: 32)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.white.opacity(0.08), lineWidth: 0.5))
        .padding(.top, 6).padding(.bottom, 2)
        .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8))
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        .moveDisabled(true)
        .deleteDisabled(true)
    }
}


/// Gives the menu bar dropdown's window rounder corners than the system default:
/// a clear window, with the content clipped to the given radius.
struct RoundedWindow: NSViewRepresentable {
    let radius: CGFloat
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async {
            guard let w = v.window else { return }
            w.isOpaque = false
            w.backgroundColor = .clear
            w.hasShadow = true
            if let frame = w.contentView?.superview {
                frame.wantsLayer = true
                frame.layer?.cornerRadius = radius
                frame.layer?.cornerCurve = .continuous
                frame.layer?.masksToBounds = true
                // The system's own panel background (with smaller corners) would peek
                // out past ours; our glass replaces it.
                let ours = w.contentView
                func hideBackdrops(_ v: NSView) {
                    for sub in v.subviews where sub !== ours {   // never our own content
                        if sub is NSVisualEffectView { sub.isHidden = true } else { hideBackdrops(sub) }
                    }
                }
                hideBackdrops(frame)
            }
            w.invalidateShadow()
            for delay in [0.15, 0.6] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak w] in w?.invalidateShadow() }
            }
        }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}


extension View {
    /// A Liquid Glass edge: a thin rim that catches the light at the top and fades
    /// around the sides, with a faint inner glow.
    func glassRim(_ radius: CGFloat) -> some View {
        overlay {
            let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
            shape.strokeBorder(LinearGradient(stops: [.init(color: .white.opacity(0.55), location: 0),
                                                      .init(color: .white.opacity(0.12), location: 0.35),
                                                      .init(color: .white.opacity(0.06), location: 0.7),
                                                      .init(color: .white.opacity(0.22), location: 1)],
                                              startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1.2)
                .overlay(shape.inset(by: 1.2).strokeBorder(.white.opacity(0.07), lineWidth: 3).blur(radius: 2))
                .allowsHitTesting(false)
        }
    }
}


/// The current cover's accent colour (bright, saturated), shared by the glass
/// surfaces and the lock screen.
@MainActor
final class CoverAccent: ObservableObject {
    static let shared = CoverAccent()
    @Published private(set) var color = Color.white
    private var bag: AnyCancellable?
    private var current: URL?

    private init() {
        bag = PlayerController.shared.objectWillChange
            .debounce(for: .milliseconds(150), scheduler: RunLoop.main)
            .sink { [weak self] in self?.refresh() }
        refresh()
    }

    private func refresh() {
        let url = PlayerController.shared.current?.largeArtwork
        guard url != current else { return }
        current = url
        guard let url else { return }
        Task {
            guard let img = await ImageLoader.shared.cgImage(for: url, maxPixel: 96), url == current else { return }
            withAnimation(.easeInOut(duration: 0.6)) { color = LockColors.accent(of: img) }
        }
    }
}

/// Frosted Liquid Glass tinted with the cover's colour at the top, fading down
/// (like Canopy's player).
private struct TintedGlass: ViewModifier {
    let radius: CGFloat
    @ObservedObject private var accent = CoverAccent.shared

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        // Cover colour at the top, fading down; over a darker base so it stays rich
        // (not washed out) when the window isn't the active one.
        let tint = LinearGradient(stops: [.init(color: accent.color.opacity(0.42), location: 0),
                                          .init(color: accent.color.opacity(0.16), location: 0.45),
                                          .init(color: .clear, location: 1)],
                                  startPoint: .top, endPoint: .bottom)
        if #available(macOS 26.0, *) {
            content
                .background(tint, in: shape)
                .background(Color.black.opacity(0.28), in: shape)
                .glassEffect(.regular, in: .rect(cornerRadius: radius))
        } else {
            content
                .background(tint, in: shape)
                .background(Color.black.opacity(0.28), in: shape)
                .background(.regularMaterial, in: shape)
                .clipShape(shape)
                .glassRim(radius)
        }
    }
}

extension View {
    /// Cover-tinted glass that fades to clear.
    func tintedGlass(_ radius: CGFloat) -> some View { modifier(TintedGlass(radius: radius)) }

    /// The mini players' surface: cover-tinted Liquid Glass, or (with glass off)
    /// the cover-colour background clipped to the card; a light rim either way.
    @ViewBuilder func playerSurface(glass: Bool, radius: CGFloat) -> some View {
        if glass {
            tintedGlass(radius)
        } else {
            clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous)).glassRim(radius)
        }
    }
}
