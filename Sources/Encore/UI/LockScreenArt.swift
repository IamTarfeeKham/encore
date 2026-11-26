import AppKit
import Combine
import CoreImage
import SwiftUI

/// The lock screen player (like Canopy). While music plays and the Mac is locked,
/// a Liquid Glass media card (small cover, song, wavy progress line in the cover's
/// colour, controls) sits on the normal lock screen. Click the small cover and the
/// art fills the screen (the cover as the background, a big cover, a clock); click
/// the big cover to go back. It never takes the keyboard, so typing the password
/// or Touch ID works the whole time. Exists only while locked; Settings › Lyrics ›
/// Lock Screen turns it off.
@MainActor
final class LockScreenArt {
    static let shared = LockScreenArt()

    private var panel: NSPanel?
    private var space: LockScreenSpace?
    private var playing: AnyCancellable?
    private var watchdog: Timer?
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
        let host = NSHostingView(rootView: LockScreenView())
        host.sizingOptions = []
        host.safeAreaRegions = []
        p.contentView = host
        p.setFrame(screen.frame, display: false)
        p.alphaValue = 0
        p.orderFrontRegardless()
        space.adopt(p)
        panel = p
        fade(p, to: 1, duration: 0.45)
        PerfMonitor.note("lock screen: showing (window \(p.windowNumber))")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.noteLayering() }

        // If the unlock notice is ever missed, don't leave it over the desktop.
        watchdog = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            MainActor.assumeIsolated {
                let art = LockScreenArt.shared
                if !Self.screenIsLocked, Date() > art.testUntil { art.hide() }
            }
        }
    }

    private func fade(_ p: NSPanel, to alpha: CGFloat, duration: Double) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = duration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            p.animator().alphaValue = alpha
        }
    }

    /// Keeps a small note of the on-screen window order at lock (owner names,
    /// layers, sizes; no titles or contents), for diagnosing other macOS versions.
    private func noteLayering() {
        guard let p = panel else { return }
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        let lines = list.prefix(40).enumerated().map { i, w -> String in
            let owner = w[kCGWindowOwnerName as String] as? String ?? "?"
            let layer = w[kCGWindowLayer as String] as? Int ?? 0
            let b = w[kCGWindowBounds as String] as? [String: CGFloat] ?? [:]
            let ours = (w[kCGWindowNumber as String] as? Int) == p.windowNumber ? "  <- ours" : ""
            return "\(i) \(owner) layer \(layer) \(Int(b["Width"] ?? 0))x\(Int(b["Height"] ?? 0))\(ours)"
        }
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("lockscreen.log")
        try? (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
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

// MARK: - Layout

/// By default: the normal lock screen (wallpaper, the system's clock and password
/// box) with a Liquid Glass media card in the middle. Click the card's cover and
/// the cover fills the screen (a big cover over the art, with the card below it);
/// click the big cover to go back. Clear areas pass clicks through to the system.
private struct LockScreenView: View {
    @ObservedObject private var player = PlayerController.shared
    @ObservedObject private var prefs = Prefs.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var expanded = false
    @State private var accent = Color.white
    @Namespace private var ns

    var body: some View {
        GeometryReader { g in
            let w = g.size.width, h = g.size.height
            let cardWidth = min(max(360, w * 0.26), 460)
            ZStack(alignment: .top) {
                if expanded {
                    LockBackdrop(artwork: player.current?.largeArtwork, moving: !reduceMotion)
                        .ignoresSafeArea()
                        .transition(.opacity)
                    LockClock(height: h)
                        .position(x: w / 2, y: h * 0.14)
                        .transition(.opacity)
                }
                VStack(spacing: 22) {
                    if expanded {
                        cover(side: min(h * 0.42, w * 0.4), radius: 16)
                            .onTapGesture { toggle() }
                            .accessibilityLabel("Back to the normal lock screen")
                    }
                    card(width: cardWidth)
                }
                .padding(.top, expanded ? h * 0.25 : h * 0.43)
                .frame(maxWidth: .infinity)
            }
            .foregroundStyle(.white)
        }
        .environmentObject(player)
        .environmentObject(player.clock)
        .environment(\.colorScheme, .dark)
        .task(id: player.current?.largeArtwork) {
            guard let url = player.current?.largeArtwork,
                  let img = await ImageLoader.shared.cgImage(for: url, maxPixel: 96) else { return }
            accent = LockColors.accent(of: img)
        }
    }

    private func toggle() {
        withAnimation(.spring(duration: 0.65, bounce: 0.14)) { expanded.toggle() }
    }

    private func cover(side: CGFloat, radius: CGFloat) -> some View {
        Artwork(url: player.current?.largeArtwork, cornerRadius: radius, size: side)
            .frame(width: side, height: side)
            .matchedGeometryEffect(id: "cover", in: ns)
            .shadow(color: .black.opacity(expanded ? 0.45 : 0.25), radius: expanded ? 30 : 8, y: expanded ? 14 : 3)
            .contentShape(Rectangle())
    }

    /// The media card: cover (click to fill the screen), song, wavy progress, controls.
    private func card(width: CGFloat) -> some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                if !expanded {
                    cover(side: 50, radius: 9)
                        .onTapGesture { toggle() }
                        .accessibilityLabel("Show the cover full screen")
                        .accessibilityAddTraits(.isButton)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(player.current?.title ?? "").font(.system(size: 14, weight: .semibold)).lineLimit(1)
                    Text(player.current?.artistLine ?? "").font(.system(size: 12.5)).opacity(0.7).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            WaveScrubber(accent: accent)
            LockControls()
        }
        .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 12)
        .frame(width: width)
        .lockGlass(22)
    }
}

private extension View {
    /// Liquid Glass on macOS 26 and later; frosted glass with a light rim before that.
    @ViewBuilder func lockGlass(_ radius: CGFloat) -> some View {
        tintedGlass(radius)
    }
}

/// Plain glyphs, like the system's own media controls.
private struct LockControls: View {
    @ObservedObject private var player = PlayerController.shared
    var body: some View {
        HStack(spacing: 38) {
            Button { player.previous() } label: { Image(systemName: "backward.fill").font(.system(size: 19)) }
            Button { player.togglePlayPause() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 26))
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 30)
            }
            Button { player.next() } label: { Image(systemName: "forward.fill").font(.system(size: 19)) }
        }
        .buttonStyle(LockGlyphStyle())
    }
}

private struct LockGlyphStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.6 : 1)
            .scaleEffect(configuration.isPressed ? 0.88 : 1)
            .animation(.spring(duration: 0.2), value: configuration.isPressed)
            .contentShape(Rectangle())
    }
}

/// Android-style progress: a wavy line in the cover's colour for what's played
/// (moving while it plays, flat when paused), a thin line for the rest, a small
/// upright thumb, and the times. Click or drag to seek.
private struct WaveScrubber: View {
    let accent: Color
    @ObservedObject private var player = PlayerController.shared
    @EnvironmentObject private var clock: PlaybackClock
    @State private var drag: Double?

    private func fmt(_ t: Double) -> String {
        let s = max(0, Int(t.rounded())); return String(format: "%d:%02d", s / 60, s % 60)
    }

    var body: some View {
        VStack(spacing: 6) {
            GeometryReader { g in
                let duration = max(clock.duration, 1)
                let progress = drag ?? min(max(clock.time / duration, 0), 1)
                WaveLine(progress: progress, color: NSColor(accent), playing: player.isPlaying && drag == nil)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { v in drag = min(max(v.location.x / g.size.width, 0), 1) }
                        .onEnded { v in
                            let f = min(max(v.location.x / g.size.width, 0), 1)
                            player.seek(to: f * duration)
                            drag = nil
                        })
            }
            .frame(height: 22)
            HStack {
                Text(fmt(drag.map { $0 * clock.duration } ?? clock.time))
                Spacer()
                Text("-" + fmt(clock.duration - (drag.map { $0 * clock.duration } ?? clock.time)))
            }
            .font(.system(size: 11, weight: .medium)).monospacedDigit().opacity(0.65)
        }
    }
}

/// The wavy line, drawn and moved by Core Animation (no per-frame work).
private struct WaveLine: NSViewRepresentable {
    let progress: Double
    let color: NSColor
    let playing: Bool
    func makeNSView(context: Context) -> WaveLineView { WaveLineView() }
    func updateNSView(_ v: WaveLineView, context: Context) { v.update(progress: progress, color: color, playing: playing) }
}

private final class WaveLineView: NSView {
    private let wave = CAShapeLayer()
    private let waveMask = CALayer()
    private let rest = CAShapeLayer()
    private let thumb = CALayer()
    private var progress = 0.0, playing = false
    private let wavelength: CGFloat = 22, amplitude: CGFloat = 3.2

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        for l in [wave, rest] { l.fillColor = nil; l.lineCap = .round; l.lineWidth = 3.2 }
        rest.strokeColor = NSColor.white.withAlphaComponent(0.28).cgColor
        rest.lineWidth = 2.4
        waveMask.backgroundColor = NSColor.black.cgColor
        wave.mask = waveMask
        thumb.cornerRadius = 2
        layer?.addSublayer(rest)
        layer?.addSublayer(wave)
        layer?.addSublayer(thumb)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        // A wave one wavelength longer than the bar, slid left in a loop.
        let mid = bounds.midY
        let path = CGMutablePath()
        let steps = Int((bounds.width + wavelength * 2) / 2)
        for i in 0...steps {
            let x = CGFloat(i) * 2 - wavelength
            let y = mid + amplitude * sin(x / wavelength * 2 * .pi)
            i == 0 ? path.move(to: CGPoint(x: x, y: y)) : path.addLine(to: CGPoint(x: x, y: y))
        }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        wave.frame = bounds
        wave.path = path
        rest.frame = bounds
        CATransaction.commit()
        apply(animated: false)
        restartFlow()
    }

    func update(progress: Double, color: NSColor, playing: Bool) {
        wave.strokeColor = color.cgColor
        thumb.backgroundColor = color.cgColor
        let wasPlaying = self.playing
        self.progress = progress
        self.playing = playing
        apply(animated: true)
        if wasPlaying != playing { restartFlow() }
    }

    /// Played part (wave) up to the thumb, thin line after it.
    private func apply(animated: Bool) {
        let x = bounds.width * progress
        CATransaction.begin()
        CATransaction.setAnimationDuration(animated ? 0.5 : 0)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .linear))
        // The mask sits in the wave layer's own coordinates, which slide; keep it
        // at the bar's left edge by giving it the bar's frame and clipping by width.
        waveMask.frame = CGRect(x: 0, y: 0, width: max(0, x - 4), height: bounds.height)
        let p = CGMutablePath()
        p.move(to: CGPoint(x: min(x + 6, bounds.width), y: bounds.midY))
        p.addLine(to: CGPoint(x: bounds.width, y: bounds.midY))
        rest.path = p
        thumb.frame = CGRect(x: x - 2, y: bounds.midY - 9, width: 4, height: 18)
        wave.lineWidth = playing ? 3.2 : 2.8
        CATransaction.commit()
    }

    /// The wave flows while playing and relaxes into a flat line when paused.
    private func restartFlow() {
        wave.removeAnimation(forKey: "flow")
        wave.removeAnimation(forKey: "flatten")
        if playing {
            wave.transform = CATransform3DIdentity
            let a = CABasicAnimation(keyPath: "sublayerTransform.translation.x")
            a.fromValue = 0
            a.toValue = -wavelength
            a.duration = 1.1
            a.repeatCount = .infinity
            wave.add(a, forKey: "flow")
        } else {
            let flat = CABasicAnimation(keyPath: "transform.scale.y")
            flat.fromValue = 1; flat.toValue = 0.05
            flat.duration = 0.4
            flat.fillMode = .forwards
            flat.isRemovedOnCompletion = false
            wave.add(flat, forKey: "flatten")
        }
    }
}

enum LockColors {
    /// A bright, saturated version of the cover's average colour.
    static func accent(of img: CGImage) -> Color {
        let ci = CIImage(cgImage: img)
        guard let avg = CIFilter(name: "CIAreaAverage", parameters: [kCIInputImageKey: ci,
                                                                    kCIInputExtentKey: CIVector(cgRect: ci.extent)])?.outputImage
        else { return .white }
        var px = [UInt8](repeating: 0, count: 4)
        CIContext(options: [.workingColorSpace: NSNull()]).render(avg, toBitmap: &px, rowBytes: 4,
                                                                  bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                                                                  format: .RGBA8, colorSpace: nil)
        let c = NSColor(red: CGFloat(px[0]) / 255, green: CGFloat(px[1]) / 255, blue: CGFloat(px[2]) / 255, alpha: 1)
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        c.usingColorSpace(.deviceRGB)?.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        if s < 0.12 { return Color(white: 0.95) }   // a grey cover: plain white
        return Color(hue: Double(h), saturation: Double(max(s, 0.55)), brightness: Double(max(b, 0.92)))
    }
}

/// Date and time.
private struct LockClock: View {
    let height: CGFloat
    var body: some View {
        TimelineView(.everyMinute) { ctx in
            VStack(spacing: 2) {
                Text(ctx.date.formatted(.dateTime.weekday(.wide).month(.wide).day()))
                    .font(.system(size: max(16, height * 0.024), weight: .semibold))
                    .opacity(0.85)
                Text(ctx.date.formatted(.dateTime.hour(.defaultDigits(amPM: .omitted)).minute()))
                    .font(.system(size: max(64, height * 0.12), weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .opacity(0.9)
            }
            .shadow(color: .black.opacity(0.2), radius: 10, y: 2)
        }
    }
}

// MARK: - Background

/// The full-screen art: the cover, filling the screen, a little softened and
/// darkened so the clock and card read well, rendered in 16-bit colour (smooth, no
/// banding) and drifting slowly like a camera move (Core Animation).
private struct LockBackdrop: NSViewRepresentable {
    let artwork: URL?
    let moving: Bool
    func makeNSView(context: Context) -> LockBackdropView { LockBackdropView() }
    func updateNSView(_ v: LockBackdropView, context: Context) { v.update(artwork: artwork, moving: moving) }
}

private final class LockBackdropView: NSView {
    private let art = CALayer()
    private let scrim = CAGradientLayer()
    private var artwork: URL?
    private var moving = true
    private var loadTask: Task<Void, Never>?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        art.contentsGravity = .resizeAspectFill
        art.minificationFilter = .trilinear
        layer?.addSublayer(art)
        scrim.colors = [NSColor.black.withAlphaComponent(0.35).cgColor, NSColor.black.withAlphaComponent(0.1).cgColor,
                        NSColor.black.withAlphaComponent(0.15).cgColor, NSColor.black.withAlphaComponent(0.5).cgColor]
        scrim.locations = [0, 0.3, 0.62, 1]
        layer?.addSublayer(scrim)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        art.frame = bounds.insetBy(dx: -bounds.width * 0.06, dy: -bounds.height * 0.06)
        scrim.frame = bounds
        CATransaction.commit()
    }

    func update(artwork: URL?, moving: Bool) {
        if moving != self.moving { self.moving = moving; drift() }
        guard artwork != self.artwork else { return }
        self.artwork = artwork
        loadTask?.cancel()
        guard let artwork else { art.contents = nil; return }
        loadTask = Task { @MainActor [weak self] in
            guard let img = await ImageLoader.shared.cgImage(for: artwork, maxPixel: 1200) else { return }
            let soft = await Task.detached(priority: .userInitiated) { Self.render(img) }.value
            guard let self, !Task.isCancelled else { return }
            let swap = CATransition(); swap.type = .fade; swap.duration = 0.6
            self.art.add(swap, forKey: "swap")
            self.art.contents = soft
            self.drift()
        }
    }

    private func drift() {
        art.removeAnimation(forKey: "drift")
        guard moving else { return }
        let a = CABasicAnimation(keyPath: "transform")
        a.fromValue = NSValue(caTransform3D: CATransform3DIdentity)
        a.toValue = NSValue(caTransform3D: CATransform3DTranslate(CATransform3DMakeScale(1.06, 1.06, 1), -20, 12, 0))
        a.duration = 24
        a.autoreverses = true
        a.repeatCount = .infinity
        a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        a.isRemovedOnCompletion = false
        art.add(a, forKey: "drift")
    }

    nonisolated private static func render(_ img: CGImage) -> CGImage? {
        let extent = CGRect(x: 0, y: 0, width: img.width, height: img.height)
        let ci = CIImage(cgImage: img).clampedToExtent()
            .applyingGaussianBlur(sigma: 2.5)
            .applyingFilter("CIColorControls", parameters: [kCIInputBrightnessKey: -0.12, kCIInputSaturationKey: 1.08])
            .cropped(to: extent)
        let ctx = CIContext(options: [.workingFormat: CIFormat.RGBAh, .cacheIntermediates: false])
        return ctx.createCGImage(ci, from: extent, format: .RGBA16,
                                 colorSpace: CGColorSpace(name: CGColorSpace.displayP3) ?? CGColorSpaceCreateDeviceRGB())
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
