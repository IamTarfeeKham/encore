import AppKit
import Combine
import CoreImage
import SwiftUI

/// The lock screen player. While music plays and the Mac is locked, it fills the
/// lock screen with the song: a moving background made from the cover (the
/// wallpaper doesn't show), the cover itself, the song's name, a progress bar
/// and play controls. Tap the cover to make it big (the cover then fills the
/// background, drifting slowly) or small again.
///
/// It never takes the keyboard (the password box keeps it), leaves the area
/// around the password box clear and clickable, and exists only while the
/// screen is locked. Settings › Lyrics › Lock Screen turns it off.
@MainActor
final class LockScreenArt {
    static let shared = LockScreenArt()

    private var panel: NSPanel?
    private var space: LockScreenSpace?
    private var playing: AnyCancellable?
    private var watchdog: Timer?
    private let state = LockScreenState()
    /// A developer test shows it without locking (perfLog on); until then, the
    /// watchdog leaves it up.
    private var testUntil = Date.distantPast

    func start() {
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { LockScreenArt.shared.screenLocked() }
        }
        dnc.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { LockScreenArt.shared.hide() }
        }
        if UserDefaults.standard.bool(forKey: "perfLog") {
            dnc.addObserver(forName: .init("local.ytmusicmac.debug.lockArt"), object: nil, queue: .main) { _ in
                MainActor.assumeIsolated {
                    let art = LockScreenArt.shared
                    art.testUntil = Date().addingTimeInterval(8)
                    art.show()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 8) { art.hide() }
                }
            }
        }
    }

    private static var screenIsLocked: Bool {
        guard let d = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return (d["CGSSessionScreenIsLocked"] as? NSNumber)?.boolValue ?? false
    }

    private func screenLocked() {
        guard Prefs.shared.lockScreenArtwork else { return }
        let player = PlayerController.shared
        // Music that starts while locked (media keys, headphones) brings it up too.
        playing = player.$isPlaying.removeDuplicates().sink { on in
            if on, player.current != nil { LockScreenArt.shared.show() }
        }
    }

    private func show() {
        guard panel == nil, PlayerController.shared.current != nil else { return }
        guard let space = space ?? LockScreenSpace() else {
            PerfMonitor.note("lock screen: window-server space unavailable")
            return
        }
        self.space = space
        guard let screen = NSScreen.screens.first else { return }

        let p = LockPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                          backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.hidesOnDeactivate = false
        p.becomesKeyOnlyIfNeeded = true
        p.isReleasedWhenClosed = false
        p.animationBehavior = .none
        p.collectionBehavior = [.stationary, .ignoresCycle, .fullScreenAuxiliary]
        state.systemAbove = false
        let host = NSHostingView(rootView: LockScreenView(state: state))
        host.sizingOptions = []
        host.safeAreaRegions = []
        p.contentView = host
        p.setFrame(screen.frame, display: false)
        p.alphaValue = 0
        p.orderFrontRegardless()
        space.adopt(p)
        panel = p
        NSAnimationContext.runAnimationGroup { $0.duration = 0.45; p.animator().alphaValue = 1 }
        PerfMonitor.note("lock screen: showing (window \(p.windowNumber))")

        // If the lock screen's own clock and password box turn out to sit above this
        // layer, there's no need to draw a clock or keep a gap for the password box.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.checkLayering() }

        // If the unlock notice is ever missed, don't leave it over the desktop.
        watchdog = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            MainActor.assumeIsolated {
                let art = LockScreenArt.shared
                if !Self.screenIsLocked, Date() > art.testUntil { art.hide() }
            }
        }
    }

    /// Looks at the on-screen window order (front to back): is any large window of
    /// the system's lock screen (loginwindow) in front of ours? Also keeps a small
    /// note of the order (owner names, layers, sizes; no titles or contents) for
    /// diagnosing lock screen layouts on other macOS versions.
    private func checkLayering() {
        guard let p = panel else { return }
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        let ours = list.firstIndex { ($0[kCGWindowNumber as String] as? Int) == p.windowNumber }
        let screenArea = (NSScreen.screens.first?.frame).map { $0.width * $0.height } ?? 1
        var lines: [String] = []
        var systemInFront = false
        for (i, w) in list.enumerated() {
            let owner = w[kCGWindowOwnerName as String] as? String ?? "?"
            let layer = w[kCGWindowLayer as String] as? Int ?? 0
            let b = w[kCGWindowBounds as String] as? [String: CGFloat] ?? [:]
            let area = (b["Width"] ?? 0) * (b["Height"] ?? 0)
            lines.append("\(i) \(owner) layer \(layer) \(Int(b["Width"] ?? 0))x\(Int(b["Height"] ?? 0))\(i == ours ? "  <- ours" : "")")
            if let ours, i < ours, owner == "loginwindow", area > screenArea * 0.05 { systemInFront = true }
        }
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("lockscreen.log")
        try? (lines.prefix(40).joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        if systemInFront, Self.screenIsLocked {
            withAnimation(.easeOut(duration: 0.3)) { state.systemAbove = true }
        }
    }

    func hide() {
        playing = nil
        watchdog?.invalidate(); watchdog = nil
        guard let p = panel else { return }
        panel = nil
        p.orderOut(nil)
        p.contentView = nil
        space?.remove()
        space = nil
        PerfMonitor.note("lock screen: hidden")
    }
}

/// Never becomes key or main: the password box keeps the keyboard.
private final class LockPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
private final class LockScreenState: ObservableObject {
    /// The system's clock and password box draw above us (so we don't draw a
    /// clock or keep a gap for the password box).
    @Published var systemAbove = false
}

// MARK: - Layout

private struct LockScreenView: View {
    @ObservedObject var state: LockScreenState
    @ObservedObject private var player = PlayerController.shared
    @ObservedObject private var prefs = Prefs.shared
    @AppStorage("lockScreenLarge") private var large = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { g in
            let w = g.size.width, h = g.size.height
            // Our content stays above the password box (bottom ~27%); when the
            // system clock shows, below it too.
            let top = state.systemAbove ? h * 0.27 : (large ? h * 0.07 : h * 0.29)
            let side = large ? min(h * (0.72 - (top / h)) - 150, w * 0.42) : h * 0.25
            ZStack(alignment: .top) {
                LockBackdrop(artwork: player.current?.largeArtwork, large: large,
                             gap: !state.systemAbove, moving: !reduceMotion)
                    .ignoresSafeArea()
                if !state.systemAbove && !large {
                    LockClock(height: h)
                        .position(x: w / 2, y: h * 0.155)
                        .transition(.opacity)
                }
                VStack(spacing: 14) {
                    TiltingArtwork(url: player.current?.largeArtwork, side: max(side, 120),
                                   breathing: player.isPlaying && prefs.artworkMotion && !reduceMotion)
                        .scaleEffect(player.isPlaying ? 1 : 0.95)
                        .contentShape(Rectangle())
                        .onTapGesture { withAnimation(.spring(duration: 0.7, bounce: 0.16)) { large.toggle() } }
                        .accessibilityLabel(large ? "Make the cover smaller" : "Make the cover bigger")
                        .accessibilityAddTraits(.isButton)
                    if let t = player.current {
                        VStack(spacing: 3) {
                            Text(t.title).font(.system(size: 19, weight: .bold)).lineLimit(1)
                            Text(t.artistLine).font(.system(size: 14.5, weight: .medium)).opacity(0.72).lineLimit(1)
                        }
                        .frame(maxWidth: max(340, w * 0.3))
                        .shadow(color: .black.opacity(0.35), radius: 6, y: 1)
                    }
                    ScrubberBar()
                        .frame(width: max(320, w * 0.26))
                    TransportControls(size: .large, showShuffleRepeat: false)
                }
                .padding(.top, top)
                .frame(maxWidth: .infinity)
            }
            .foregroundStyle(.white)
            .animation(.spring(duration: 0.7, bounce: 0.16), value: large)
        }
        .environmentObject(player)
        .environmentObject(player.clock)
        .environment(\.colorScheme, .dark)
    }
}

/// Date and time, drawn only when our layer covers the system's own clock.
private struct LockClock: View {
    let height: CGFloat
    var body: some View {
        TimelineView(.everyMinute) { ctx in
            VStack(spacing: 2) {
                Text(ctx.date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))
                    .font(.system(size: max(16, height * 0.024), weight: .semibold))
                    .opacity(0.85)
                Text(ctx.date.formatted(.dateTime.hour(.defaultDigits(amPM: .omitted)).minute()))
                    .font(.system(size: max(64, height * 0.115), weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .opacity(0.92)
            }
            .shadow(color: .black.opacity(0.25), radius: 10, y: 2)
        }
    }
}

// MARK: - Background

/// The moving background: the cover's colours drifting (the same layers as the
/// app's background), and — with the big cover — the cover itself, softly
/// blurred, filling the screen and slowly drifting. Everything moves on Core
/// Animation. With `gap`, a soft opening is kept over the password box.
private struct LockBackdrop: NSViewRepresentable {
    let artwork: URL?
    let large: Bool
    let gap: Bool
    let moving: Bool

    func makeNSView(context: Context) -> LockBackdropView { LockBackdropView() }
    func updateNSView(_ v: LockBackdropView, context: Context) {
        v.update(artwork: artwork, large: large, gap: gap, moving: moving)
    }
}

private final class LockBackdropView: NSView {
    private let ambient = AmbientLayerView()
    private let cover = CALayer()
    private let scrim = CAGradientLayer()
    private let gapMask = CALayer()
    private var artwork: URL?
    private var large = false
    private var gap = true
    private var moving = true
    private var loadTask: Task<Void, Never>?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        ambient.autoresizingMask = [.width, .height]
        addSubview(ambient)
        let overlay = NSView()
        overlay.wantsLayer = true
        overlay.autoresizingMask = [.width, .height]
        addSubview(overlay)
        cover.contentsGravity = .resizeAspectFill
        cover.masksToBounds = true
        cover.opacity = 0
        overlay.layer?.addSublayer(cover)
        scrim.colors = [NSColor.black.withAlphaComponent(0.28).cgColor, NSColor.black.withAlphaComponent(0.05).cgColor,
                        NSColor.black.withAlphaComponent(0.1).cgColor, NSColor.black.withAlphaComponent(0.45).cgColor]
        scrim.locations = [0, 0.3, 0.6, 1]
        overlay.layer?.addSublayer(scrim)
        ambient.configure(dark: true, dim: 0.28)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let inset = bounds.insetBy(dx: -bounds.width * 0.12, dy: -bounds.height * 0.12)
        cover.frame = inset
        scrim.frame = bounds
        CATransaction.commit()
        updateGap()
    }

    func update(artwork: URL?, large: Bool, gap: Bool, moving: Bool) {
        ambient.motion = moving ? (large ? 2.2 : 1.6) : 0
        ambient.followsCursor = false
        if self.moving != moving { self.moving = moving; drift() }
        if gap != self.gap { self.gap = gap; updateGap() }
        if large != self.large {
            self.large = large
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = cover.presentation()?.opacity ?? cover.opacity
            fade.duration = 0.9
            fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            cover.opacity = large ? 0.9 : 0
            cover.add(fade, forKey: "fade")
        }
        guard artwork != self.artwork else { return }
        self.artwork = artwork
        loadTask?.cancel()
        guard let artwork else { ambient.setImage(nil); cover.contents = nil; return }
        loadTask = Task { @MainActor [weak self] in
            async let amb = ImageLoader.shared.ambient(for: artwork)
            async let big = ImageLoader.shared.cgImage(for: artwork, maxPixel: 600)
            let (a, b) = await (amb, big)
            guard let self, !Task.isCancelled else { return }
            self.ambient.setImage(a)
            if let b, let soft = Self.soften(b) {
                let swap = CATransition(); swap.type = .fade; swap.duration = 0.8
                self.cover.add(swap, forKey: "swap")
                self.cover.contents = soft
            }
            self.drift()
        }
    }

    /// A slow drift (zoom and pan) for the full-screen cover.
    private func drift() {
        cover.removeAnimation(forKey: "drift")
        guard moving else { return }
        let a = CABasicAnimation(keyPath: "transform")
        a.fromValue = NSValue(caTransform3D: CATransform3DMakeScale(1.0, 1.0, 1))
        a.toValue = NSValue(caTransform3D: CATransform3DTranslate(CATransform3DMakeScale(1.12, 1.12, 1), -18, 12, 0))
        a.duration = 22
        a.autoreverses = true
        a.repeatCount = .infinity
        a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        a.isRemovedOnCompletion = false
        cover.add(a, forKey: "drift")
    }

    /// Lightly blurred and darkened, so text over it stays readable.
    private static func soften(_ img: CGImage) -> CGImage? {
        let ci = CIImage(cgImage: img).clampedToExtent()
            .applyingGaussianBlur(sigma: 14)
            .applyingFilter("CIColorControls", parameters: [kCIInputBrightnessKey: -0.08, kCIInputSaturationKey: 1.15])
            .cropped(to: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        return CIContext(options: [.cacheIntermediates: false]).createCGImage(ci, from: ci.extent)
    }

    /// A soft opening over the system's password box (bottom centre), so it stays
    /// visible and clickable when the system draws it underneath us.
    private func updateGap() {
        guard gap, bounds.width > 0 else { layer?.mask = nil; return }
        let w = Int(bounds.width), h = Int(bounds.height)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        ctx.setFillColor(NSColor.black.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setBlendMode(.destinationOut)
        let rx = CGFloat(w) * 0.17, ry = CGFloat(h) * 0.15
        ctx.translateBy(x: CGFloat(w) / 2, y: CGFloat(h) * 0.135)   // 86.5% down from the top
        ctx.scaleBy(x: rx / ry, y: 1)
        let colors = [NSColor.black.cgColor, NSColor.black.cgColor, NSColor.black.withAlphaComponent(0).cgColor] as CFArray
        if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 0.3, 1]) {
            ctx.drawRadialGradient(g, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: ry, options: [])
        }
        guard let image = ctx.makeImage() else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        gapMask.contents = image
        gapMask.frame = bounds
        layer?.mask = gapMask
        CATransaction.commit()
    }
}

// MARK: - Window-server space

/// A window-server space that shows above the lock screen, the way lock-screen
/// notifications and widgets appear there. These are private SkyLight calls,
/// looked up at run time: if any is missing (another macOS version), this is nil
/// and the lock screen player simply doesn't appear.
private final class LockScreenSpace {
    private typealias MainConnectionID = @convention(c) () -> Int32
    private typealias SpaceCreate = @convention(c) (Int32, Int, UnsafeRawPointer?) -> UInt64
    private typealias SpaceSetAbsoluteLevel = @convention(c) (Int32, UInt64, Int32) -> Int32
    private typealias ShowOrHideSpaces = @convention(c) (Int32, CFArray) -> Int32
    private typealias AddWindows = @convention(c) (Int32, UInt64, CFArray, Int32) -> Int32
    private typealias SpaceDestroy = @convention(c) (Int32, UInt64) -> Int32

    /// "Notification Center at screen lock": above the lock screen.
    private static let level: Int32 = 400

    private let connection: Int32
    private let id: UInt64
    private let addWindows: AddWindows
    private let hideSpaces: ShowOrHideSpaces
    private let destroy: SpaceDestroy

    init?() {
        guard let lib = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW) else { return nil }
        func fn<T>(_ name: String, _ type: T.Type) -> T? { dlsym(lib, name).map { unsafeBitCast($0, to: type) } }
        guard let main = fn("SLSMainConnectionID", MainConnectionID.self),
              let create = fn("SLSSpaceCreate", SpaceCreate.self),
              let setLevel = fn("SLSSpaceSetAbsoluteLevel", SpaceSetAbsoluteLevel.self),
              let show = fn("SLSShowSpaces", ShowOrHideSpaces.self),
              let hide = fn("SLSHideSpaces", ShowOrHideSpaces.self),
              let add = fn("SLSSpaceAddWindowsAndRemoveFromSpaces", AddWindows.self),
              let destroy = fn("SLSSpaceDestroy", SpaceDestroy.self)
        else { return nil }
        connection = main()
        id = create(connection, 1, nil)
        guard id != 0 else { return nil }
        _ = setLevel(connection, id, Self.level)
        _ = show(connection, [NSNumber(value: id)] as CFArray)
        addWindows = add; hideSpaces = hide; self.destroy = destroy
    }

    func adopt(_ window: NSWindow) {
        _ = addWindows(connection, id, [NSNumber(value: window.windowNumber)] as CFArray, 7)
    }

    func remove() {
        _ = hideSpaces(connection, [NSNumber(value: id)] as CFArray)
        _ = destroy(connection, id)
    }
}
