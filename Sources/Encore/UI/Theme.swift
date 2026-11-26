import SwiftUI
import AppKit
import Combine

// MARK: - Liquid Glass

/// Liquid Glass on macOS 26+, frosted material with a hairline edge before that.
struct GlassPanel: ViewModifier {
    var radius: CGFloat
    var tint: Color? = nil
    var interactive = false
    /// Bars that content scrolls under use the denser "regular" glass for legibility.
    var dense = false
    /// The sidebar and player bar: frosted or clear glass, per Settings.
    var bar = false
    @ObservedObject private var prefs = Prefs.shared

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        if prefs.glassStyle == .solid {
            content
                .background(Color(nsColor: .windowBackgroundColor).opacity(0.96), in: shape)
                .overlay(shape.strokeBorder(.white.opacity(0.08), lineWidth: 0.5))
        } else if prefs.glassStyle == .frosted {
            content
                .background(.regularMaterial.opacity(0.6 + prefs.glassTint), in: shape)
                .background((tint ?? .clear), in: shape)
                .overlay(shape.strokeBorder(.white.opacity(0.14), lineWidth: 0.6))
        } else if #available(macOS 26.0, *) {
            if bar && prefs.barSurface == .frosted {
                // Frosted under the glass: what's behind is blurred, not readable.
                content
                    .background(.thinMaterial, in: shape)
                    .glassEffect(glass, in: .rect(cornerRadius: radius))
            } else {
                content.glassEffect(glass, in: .rect(cornerRadius: radius))
            }
        } else {
            content
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
                .background((tint ?? .clear), in: RoundedRectangle(cornerRadius: radius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(LinearGradient(colors: [.white.opacity(0.28), .white.opacity(0.06)],
                                                 startPoint: .top, endPoint: .bottom), lineWidth: 0.7))
        }
    }

    @available(macOS 26.0, *)
    private var glass: Glass {
        // "Clear" glass: more transparent and refractive (true liquid look) than the
        // frosted "regular" variant; a light dark tint keeps text readable.
        // Always the clear (lensing) variant, like Apple Music's floating bars; the
        // transparency setting controls how much tint sits in the glass everywhere.
        var g = Glass.clear
        // Clear Liquid Glass bars get a lighter tint, so they stay see-through.
        let clearBar = bar && prefs.barSurface == .liquid
        g = g.tint(Color.black.opacity(min(0.85, prefs.glassTint * (clearBar ? 0.6 : 1) + (dense && !clearBar ? 0.14 : 0) + (tint == nil ? 0 : 0.04))))
        if interactive { g = g.interactive() }
        return g
    }
}

extension View {
    /// Light, static surface for cards that scroll (glass inside scrolling
    /// content has to be re-rendered every frame; this doesn't).
    func cardSurface(_ radius: CGFloat = 16) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return self
            .background(shape.fill(Color.primary.opacity(0.07)))
            .overlay(shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.16), .white.opacity(0.04)],
                                                       startPoint: .top, endPoint: .bottom), lineWidth: 0.6))
    }

    func glassPanel(_ radius: CGFloat = 18, tint: Color? = nil, interactive: Bool = false, dense: Bool = false, bar: Bool = false) -> some View {
        modifier(GlassPanel(radius: radius, tint: tint, interactive: interactive, dense: dense, bar: bar))
    }

    /// Frosted-glass panel for lists that float over busy content (the queue): a
    /// blur strong enough that text behind can't be read, without darkening it.
    func readablePanel(_ radius: CGFloat = 20) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return self
            .background(Color.white.opacity(0.06), in: shape)
            .background(.regularMaterial, in: shape)
            .overlay(shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.28), .white.opacity(0.06)],
                                                       startPoint: .top, endPoint: .bottom), lineWidth: 0.7))
    }

    /// Capsule buttons used across the app: `prominent` is a solid accent pill
    /// for the main action, otherwise a soft translucent pill.
    func glassButton(prominent: Bool = false) -> some View {
        buttonStyle(CapsuleButtonStyle(prominent: prominent))
    }
}

// MARK: - Scroll activity

/// Tracks whether the user is scrolling right now (any scroll view). Hover
/// effects and parallax pause during scrolls so every frame goes to scrolling.
/// Deliberately not observable: reading it never triggers a re-render.
@MainActor
enum ScrollActivity {
    private(set) static var isScrolling = false
    /// Set by the developer scroll test (PerfMonitor) while it scrolls the page.
    static func setTestScrolling(_ v: Bool) { isScrolling = v }
    private static var lastEvent = Date.distantPast
    private static var monitor: Any?

    static func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { e in
            lastEvent = Date()
            if !isScrolling { isScrolling = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                if Date().timeIntervalSince(lastEvent) >= 0.17 { isScrolling = false }
            }
            return e
        }
    }
}


// MARK: - Cursor tracking for the parallax background

@MainActor
final class PointerTracker: ObservableObject {
    static let shared = PointerTracker()
    /// Normalised pointer position (0…1) within the window.
    @Published private(set) var point = CGPoint(x: 0.5, y: 0.5)
    private var lastUpdate = Date.distantPast

    func update(_ p: CGPoint, in size: CGSize) {
        guard size.width > 0, size.height > 0, !ScrollActivity.isScrolling else { return }
        let now = Date()
        guard now.timeIntervalSince(lastUpdate) > 1.0 / 60 else { return }
        lastUpdate = now
        point = CGPoint(x: min(max(p.x / size.width, 0), 1), y: min(max(p.y / size.height, 0), 1))
    }

    func reset() { point = CGPoint(x: 0.5, y: 0.5) }
}

// MARK: - Animated artwork background

/// The current song's artwork, blurred into soft colour, slowly rotating in
/// three layers and drifting with the cursor (parallax).
///
/// Implemented with Core Animation: the rotation runs in the window server,
/// so it never touches the main thread and can't make scrolling stutter.
struct AmbientBackground: View {
    let artwork: URL?
    /// 0…1: how strongly the content is dimmed for legibility (nil = user setting).
    var dim: Double? = nil
    var parallax: CGFloat = 1
    /// Multiplies the motion (the artwork view drifts a little livelier).
    var energy: Double = 1
    @Environment(\.colorScheme) private var scheme
    @ObservedObject private var prefs = Prefs.shared
    @State private var image: CGImage?

    var body: some View {
        AmbientLayerRepresentable(image: image, dim: dim ?? prefs.backgroundDim, parallax: parallax, dark: scheme == .dark,
                                  accent: NSColor(prefs.accentColor),
                                  motion: prefs.animatedBackground ? prefs.backgroundMotion * energy : 0,
                                  followsCursor: prefs.followCursor)
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .task(id: artwork) {
                guard let artwork, let img = await ImageLoader.shared.ambient(for: artwork) else { return }
                image = img
            }
    }
}

private struct AmbientLayerRepresentable: NSViewRepresentable {
    let image: CGImage?
    let dim: Double
    let parallax: CGFloat
    let dark: Bool
    let accent: NSColor
    let motion: Double
    let followsCursor: Bool

    func makeNSView(context: Context) -> AmbientLayerView { AmbientLayerView() }
    func updateNSView(_ v: AmbientLayerView, context: Context) {
        v.setFallback(accent: accent, dark: dark)
        v.parallax = parallax
        v.motion = motion
        v.followsCursor = followsCursor
        v.configure(dark: dark, dim: dim)
        v.setImage(image)
    }
}

final class AmbientLayerView: NSView {
    var parallax: CGFloat = 1
    private let veil = CALayer()
    private let fallback = CAGradientLayer()
    private var group: CALayer?
    private var currentImage: CGImage?
    private var dark = true
    private var pointerSub: AnyCancellable?

    // (size relative to max side, x/y offset relative to side, parallax strength, spin seconds per turn, opacity)
    private let specs: [(CGFloat, CGFloat, CGFloat, CGFloat, Double, Float)] = [
        (1.7, 0, 0, -70, 140, 0.95),
        (1.05, 0.24, -0.16, 120, -140, 0.45),
        (0.8, -0.26, 0.2, 170, 70, 0.35),
    ]

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer = CALayer()
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.black.cgColor
        fallback.colors = [NSColor(red: 0.32, green: 0.12, blue: 0.38, alpha: 1).cgColor,
                           NSColor(red: 0.1, green: 0.12, blue: 0.3, alpha: 1).cgColor]
        fallback.startPoint = CGPoint(x: 0, y: 1); fallback.endPoint = CGPoint(x: 1, y: 0)
        layer?.addSublayer(fallback)
        layer?.addSublayer(veil)
        pointerSub = MainActor.assumeIsolated {
            PointerTracker.shared.$point.sink { [weak self] p in self?.movePointer(p) }
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    func configure(dark: Bool, dim: Double) {
        guard let root = layer else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        self.dark = dark
        root.backgroundColor = dark ? NSColor.black.cgColor : NSColor(white: 0.93, alpha: 1).cgColor
        veil.backgroundColor = dark ? NSColor.black.withAlphaComponent(dim).cgColor
                                    : NSColor.white.withAlphaComponent(dim + 0.12).cgColor
        fallback.opacity = 1
        CATransaction.commit()
    }

    private var fallbackKey = ""

    /// With nothing playing: a background that suits the accent colour. A deep,
    /// muted shade of the accent flowing into a neighbouring hue (so any accent
    /// gets a matching mood); grey accents get a neutral slate; light mode gets
    /// soft tints instead.
    func setFallback(accent: NSColor, dark: Bool) {
        guard let c = accent.usingColorSpace(.deviceRGB) else { return }
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        c.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        let key = String(format: "%.3f-%.3f-%d", h, s, dark ? 1 : 0)
        guard key != fallbackKey else { return }
        fallbackKey = key
        let grey = s < 0.15
        func tone(_ hue: CGFloat, _ sat: CGFloat, _ bri: CGFloat) -> CGColor {
            NSColor(hue: (hue + 1).truncatingRemainder(dividingBy: 1), saturation: grey ? 0.08 : sat,
                    brightness: bri, alpha: 1).cgColor
        }
        let colors: [CGColor] = dark
            ? [tone(h, min(0.75, s * 0.8), 0.42), tone(h + 0.07, min(0.6, s * 0.65), 0.25), tone(h - 0.05, min(0.5, s * 0.5), 0.12)]
            : [tone(h, min(0.28, s * 0.3), 0.97), tone(h + 0.07, min(0.2, s * 0.22), 0.92), tone(h - 0.05, min(0.14, s * 0.16), 0.88)]
        CATransaction.begin(); CATransaction.setAnimationDuration(0.6)
        fallback.colors = colors
        fallback.locations = [0, 0.55, 1]
        CATransaction.commit()
    }

    func setImage(_ img: CGImage?) {
        guard let img, img !== currentImage else { return }
        currentImage = img
        let new = makeGroup(img)
        new.opacity = 0
        layer?.insertSublayer(new, below: veil)
        let old = group
        group = new
        // Cross-fade: new artwork fades in over the old, then the old is removed.
        CATransaction.begin()
        CATransaction.setAnimationDuration(1.4)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
        CATransaction.setCompletionBlock { old?.removeFromSuperlayer() }
        new.opacity = 1
        CATransaction.commit()
        fallback.isHidden = true
    }

    private func makeGroup(_ img: CGImage) -> CALayer {
        let (square, faded) = Self.bake(img)
        let g = CALayer()
        g.frame = bounds
        for (i, spec) in specs.enumerated() {
            let wrapper = CALayer()          // moves with the pointer
            let art = CALayer()              // spins forever
            // The soft radial fade of the upper layers is baked into the bitmap once,
            // instead of a live gradient mask that cost an extra off-screen pass on
            // every frame of the animation. Same pixels.
            art.contents = i > 0 ? (faded ?? img) : (square ?? img)
            art.contentsGravity = .resizeAspectFill
            art.opacity = dark ? spec.5 : spec.5 * 0.7
            if i > 0, dark { art.compositingFilter = "plusL" }
            addSpin(to: art, spec: spec)
            wrapper.addSublayer(art)
            g.addSublayer(wrapper)
        }
        layoutGroup(g, animated: false)
        return g
    }

    /// The artwork centre-cropped to a square (what aspect-fill shows on the square
    /// layers), and the same square with the radial fade the mask used to apply:
    /// opaque centre → 60% halfway → clear at the edge.
    private static func bake(_ img: CGImage) -> (CGImage?, CGImage?) {
        let side = 256
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        func ctx() -> CGContext? {
            CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        }
        let w = CGFloat(img.width), h = CGFloat(img.height), s = CGFloat(side)
        let scale = max(s / w, s / h)
        let drawRect = CGRect(x: (s - w * scale) / 2, y: (s - h * scale) / 2, width: w * scale, height: h * scale)
        guard let sq = ctx() else { return (nil, nil) }
        sq.interpolationQuality = .high
        sq.draw(img, in: drawRect)
        let square = sq.makeImage()
        guard let mctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                   space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue),
              let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceGray(),
                                    colors: [CGColor(gray: 1, alpha: 1), CGColor(gray: 0.6, alpha: 1), CGColor(gray: 0, alpha: 1)] as CFArray,
                                    locations: [0, 0.5, 1]),
              let fc = ctx(), let square else { return (square, nil) }
        mctx.setFillColor(gray: 0, alpha: 1); mctx.fill(CGRect(x: 0, y: 0, width: s, height: s))
        let c = CGPoint(x: s / 2, y: s / 2)
        mctx.drawRadialGradient(grad, startCenter: c, startRadius: 0, endCenter: c, endRadius: s / 2, options: [])
        guard let mask = mctx.makeImage() else { return (square, nil) }
        fc.clip(to: CGRect(x: 0, y: 0, width: s, height: s), mask: mask)
        fc.draw(square, in: CGRect(x: 0, y: 0, width: s, height: s))
        return (square, fc.makeImage())
    }

    private func addSpin(to art: CALayer, spec: (CGFloat, CGFloat, CGFloat, CGFloat, Double, Float)) {
        art.removeAnimation(forKey: "spin")
        guard motion > 0 else { return }
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0
        spin.toValue = (spec.4 > 0 ? 1 : -1) * 2 * Double.pi
        spin.duration = abs(spec.4) / motion
        spin.repeatCount = .infinity
        spin.isRemovedOnCompletion = false
        // The motion is very slow, so ~30 fps looks identical and leaves the
        // GPU free to scroll at the display's full refresh rate.
        spin.preferredFrameRateRange = CAFrameRateRange(minimum: 10, maximum: 30, preferred: 30)
        art.add(spin, forKey: "spin")
    }

    /// 0 = still, 1 = normal, >1 = livelier.
    var motion: Double = 1 {
        didSet {
            guard oldValue != motion, let g = group else { return }
            for (i, wrapper) in (g.sublayers ?? []).enumerated() where i < specs.count {
                if let art = wrapper.sublayers?.first { addSpin(to: art, spec: specs[i]) }
            }
        }
    }
    var followsCursor = true

    private func layoutGroup(_ g: CALayer, animated: Bool) {
        let side = max(bounds.width, bounds.height)
        let p = followsCursor ? MainActor.assumeIsolated { PointerTracker.shared.point } : CGPoint(x: 0.5, y: 0.5)
        let px = (p.x - 0.5) * parallax, py = (p.y - 0.5) * parallax
        g.frame = bounds
        for (i, wrapper) in (g.sublayers ?? []).enumerated() where i < specs.count {
            let spec = specs[i]
            let size = side * spec.0
            let center = CGPoint(x: bounds.midX + side * spec.1 + px * spec.3,
                                 y: bounds.midY + side * spec.2 + py * spec.3)
            if !animated {
                wrapper.bounds = CGRect(x: 0, y: 0, width: size, height: size)
                if let art = wrapper.sublayers?.first {
                    art.frame = wrapper.bounds
                }
            }
            wrapper.position = center
        }
    }

    private func movePointer(_ p: CGPoint) {
        guard let g = group else { return }
        CATransaction.begin()
        CATransaction.setAnimationDuration(1.3)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1))
        layoutGroup(g, animated: true)
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        fallback.frame = bounds
        veil.frame = bounds
        if let g = group { layoutGroup(g, animated: false) }
        CATransaction.commit()
    }
}

// MARK: - Window chrome

/// Window setup: draggable background, content under the title bar, and the
/// close / minimise / zoom buttons inset so they sit neatly inside the sidebar.
struct WindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async {
            guard let w = v.window else { return }
            // Not movable by background: with that on, AppKit recomputes the window's
            // drag region over every view on each update (5×/s during playback),
            // which was most of the app's CPU while playing. The top bar is the drag
            // area instead (WindowDragArea), like a native title bar.
            w.isMovableByWindowBackground = false
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.styleMask.insert(.fullSizeContentView)
            w.backgroundColor = .black
            // Testing aid: `open --args -debugWindowSize 980x620` launches at an exact size.
            if let spec = UserDefaults.standard.string(forKey: "debugWindowSize") {
                let parts = spec.split(separator: "x").compactMap { Double($0) }
                if parts.count == 2, let screen = w.screen ?? NSScreen.main {
                    let vf = screen.visibleFrame
                    let size = NSSize(width: min(parts[0], vf.width), height: min(parts[1], vf.height))
                    w.setFrame(NSRect(x: vf.minX + 20, y: vf.maxY - size.height - 20, width: size.width, height: size.height), display: true)
                }
            }
            context.coordinator.attach(w)
            if let cv = w.contentView { PerfMonitor.shared.start(in: cv) }
        }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
    func makeCoordinator() -> TrafficLights { TrafficLights() }

    final class TrafficLights: NSObject {
        /// Close button's left edge, and the vertical centre shared with the top bar row.
        static let left: CGFloat = 20
        static var centerY: CGFloat = ContentView.topBarHeight / 2
        private static var all: [TrafficLights] = []

        /// Called by the top bar with its row's measured centre, so the buttons
        /// line up with the row exactly, whatever its final position.
        static func align(toRowMidY y: CGFloat) {
            guard y > 0, abs(y - centerY) > 0.25 else { return }
            centerY = y
            all.forEach { $0.apply() }
        }
        /// Slightly larger than the system's buttons.
        static let scale: CGFloat = 1.2
        static let spacing: CGFloat = 24
        private weak var window: NSWindow?
        private var observers: [NSObjectProtocol] = []
        private var baseSize: NSSize?
        private var applying = false

        func attach(_ w: NSWindow) {
            window = w
            Self.all.append(self)
            let names: [Notification.Name] = [NSWindow.didResizeNotification, NSWindow.didEndLiveResizeNotification,
                                              NSWindow.didExitFullScreenNotification, NSWindow.didBecomeKeyNotification,
                                              NSWindow.didResignKeyNotification, NSWindow.didUpdateNotification,
                                              NSWindow.didBecomeMainNotification]
            for n in names {
                observers.append(NotificationCenter.default.addObserver(forName: n, object: w, queue: .main) { [weak self] _ in
                    self?.apply()
                })
            }
            // AppKit re-lays out the buttons on its own at times; put them back
            // whenever one of them moves.
            for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                guard let b = w.standardWindowButton(type) else { continue }
                b.postsFrameChangedNotifications = true
                observers.append(NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: b, queue: .main) { [weak self] _ in
                    self?.apply()
                })
            }
            apply()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.apply() }
        }

        func apply() {
            if applying {
                // A change arrived mid-apply; settle it on the next pass.
                DispatchQueue.main.async { [weak self] in self?.apply() }
                return
            }
            guard let w = window, !w.styleMask.contains(.fullScreen),
                  let close = w.standardWindowButton(.closeButton),
                  let titlebar = close.superview, let container = titlebar.superview else { return }
            applying = true
            defer { applying = false }
            if baseSize == nil { baseSize = close.bounds.size }
            let base = baseSize!
            let size = NSSize(width: (base.width * Self.scale).rounded(), height: (base.height * Self.scale).rounded())
            // Title bar area tall enough for the moved buttons, but only as wide as
            // them so it never swallows clicks meant for our own top-bar controls.
            let height = Self.centerY + size.height / 2 + 8
            let width = Self.left + 2 * Self.spacing + size.width + 10
            var f = container.frame
            if abs(f.height - height) > 0.5 || abs(f.width - width) > 0.5 || abs(f.origin.y - (w.frame.height - height)) > 0.5 {
                f.origin.x = 0
                f.origin.y = w.frame.height - height
                f.size = NSSize(width: width, height: height)
                container.frame = f
                titlebar.frame = container.bounds
            }
            for (i, type) in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].enumerated() {
                guard let b = w.standardWindowButton(type) else { continue }
                let target = NSRect(x: Self.left + CGFloat(i) * Self.spacing,
                                    y: (titlebar.bounds.height - Self.centerY - size.height / 2).rounded(),
                                    width: size.width, height: size.height)
                if b.frame != target { b.frame = target }
                // Smaller bounds than frame → AppKit draws the button scaled up. Pin the
                // origin too: AppKit rescales bounds when it resizes the frame itself.
                let bounds = NSRect(origin: .zero, size: base)
                if b.bounds != bounds { b.bounds = bounds }
            }
        }

        deinit { observers.forEach(NotificationCenter.default.removeObserver) }
    }
}

// MARK: - Pill selector

/// The app's segmented control: a soft capsule track with a sliding accent
/// pill behind the selected option (replaces the boxy system segmented style).
struct PillPicker<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(value: Value, title: String, symbol: String?)]
    var compact = false
    /// Sitting on a glass capsule already: no extra track fill (avoids a double edge).
    var onGlass = false
    /// Icons only (the titles become tooltips and VoiceOver labels).
    var iconOnly = false
    var tipEdge: VerticalEdge = .top
    @Namespace private var ns
    @State private var hovered: Value?

    init(selection: Binding<Value>, options: [(Value, String, String?)], compact: Bool = false, onGlass: Bool = false,
         iconOnly: Bool = false, tipEdge: VerticalEdge = .top) {
        self._selection = selection
        self.options = options.map { (value: $0.0, title: $0.1, symbol: $0.2) }
        self.compact = compact
        self.onGlass = onGlass
        self.iconOnly = iconOnly
        self.tipEdge = tipEdge
    }

    var body: some View {
        // One continuous track; the selected option slides as a single capsule and
        // a hovered option gets a fainter capsule of the same shape — no seams.
        HStack(spacing: 0) {
            ForEach(options, id: \.value) { opt in
                let on = opt.value == selection
                let button = Button {
                    withAnimation(.spring(duration: 0.32, bounce: 0.22)) { selection = opt.value }
                } label: {
                    HStack(spacing: 5) {
                        if let s = opt.symbol {
                            // The chosen option's icon is filled, as elsewhere in the app.
                            Image(systemName: s)
                                .font(.system(size: iconOnly ? 14 : (compact ? 10 : 11), weight: iconOnly ? .medium : .semibold))
                                .symbolVariant(on ? .fill : .none)
                        }
                        if !iconOnly { Text(opt.title).lineLimit(1) }
                    }
                    .font(.system(size: compact ? 11 : 12, weight: .semibold))
                    .padding(.horizontal, iconOnly ? 12 : (compact ? 11 : 14))
                    .padding(.vertical, compact ? 5 : 7)
                    .foregroundStyle(on ? Color.primary : Color.secondary)
                    .background {
                        if on {
                            Capsule()
                                .fill(Color.primary.opacity(0.18))
                                .shadow(color: .black.opacity(0.18), radius: 3, y: 1)
                                .matchedGeometryEffect(id: "pill", in: ns)
                        } else if hovered == opt.value {
                            Capsule().fill(Color.primary.opacity(0.08))
                        }
                    }
                    .contentShape(Capsule())
                    .onHover { h in withAnimation(.easeOut(duration: 0.12)) { if h { hovered = opt.value } else if hovered == opt.value { hovered = nil } } }
                }
                .buttonStyle(PillOptionStyle())
                .accessibilityLabel(opt.title)
                if iconOnly { button.hoverTip(opt.title, edge: tipEdge) } else { button }
            }
        }
        .padding(onGlass ? 2 : 3)
        .background { if !onGlass { Capsule().fill(Color.primary.opacity(0.06)) } }
        .cursorSheen(Capsule(), strength: 0.12)
        .fixedSize()
    }
}

private struct PillOptionStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.spring(duration: 0.2, bounce: 0.4), value: configuration.isPressed)
    }
}


struct CapsuleButtonStyle: ButtonStyle {
    var prominent: Bool
    func makeBody(configuration: Configuration) -> some View { CapsuleBody(configuration: configuration, prominent: prominent) }

    private struct CapsuleBody: View {
        let configuration: ButtonStyleConfiguration
        let prominent: Bool
        @State private var hover = false
        @Environment(\.isEnabled) private var enabled
        @Environment(\.controlSize) private var size

        var body: some View {
            let large = size == .large || size == .extraLarge
            configuration.label
                .font(.system(size: large ? 13 : 12, weight: .semibold))
                .labelStyle(.titleAndIcon)
                .padding(.horizontal, large ? 16 : 12)
                .padding(.vertical, large ? 8 : 5)
                .frame(minHeight: large ? 32 : 26)
                .foregroundStyle(prominent ? Color.white : Color.primary)
                .background {
                    if prominent {
                        Capsule().fill(Color.accentColor)
                    } else {
                        Capsule().fill(Color.primary.opacity(configuration.isPressed ? 0.2 : (hover ? 0.15 : 0.1)))
                    }
                }
                .overlay(Capsule().strokeBorder(.white.opacity(prominent ? 0 : (hover ? 0.18 : 0.08)), lineWidth: 0.6))
                .cursorSheen(Capsule(), strength: prominent ? 0.28 : 0.18)
                .brightness(prominent && hover ? 0.06 : 0)
                .scaleEffect(configuration.isPressed ? 0.95 : 1)
                .opacity(enabled ? 1 : 0.45)
                .contentShape(Capsule())
                .animation(.spring(duration: 0.2, bounce: 0.35), value: configuration.isPressed)
                .animation(.easeOut(duration: 0.15), value: hover)
                .onHover { hover = $0 }
        }
    }
}


/// Sheets are separate windows and don't inherit the app's accent; re-apply it.
struct AppAccent: ViewModifier {
    @ObservedObject private var prefs = Prefs.shared
    func body(content: Content) -> some View {
        content.tint(prefs.accentColor).accentColor(prefs.accentColor).preferredColorScheme(prefs.colorScheme)
    }
}
extension View { func appAccent() -> some View { modifier(AppAccent()) } }


// MARK: - Cursor sheen

/// A soft highlight that follows the pointer across a control (light catching
/// glass), so buttons visibly react to where the cursor is.
struct CursorSheen<S: Shape>: ViewModifier {
    let shape: S
    var strength: Double = 0.2
    @State private var point: CGPoint?

    func body(content: Content) -> some View {
        content
            .overlay {
                GeometryReader { g in
                    if let p = point {
                        RadialGradient(colors: [.white.opacity(strength), .white.opacity(0)],
                                       center: UnitPoint(x: p.x / max(g.size.width, 1), y: p.y / max(g.size.height, 1)),
                                       startRadius: 0, endRadius: max(g.size.width, g.size.height) * 0.8)
                            .blendMode(.plusLighter)
                            .transition(.opacity)
                    }
                }
                .clipShape(shape)
                .allowsHitTesting(false)
            }
            .onContinuousHover { phase in
                switch phase {
                case .active(let p):
                    if point == nil { withAnimation(.easeOut(duration: 0.15)) { point = p } } else { point = p }
                case .ended:
                    withAnimation(.easeOut(duration: 0.25)) { point = nil }
                }
            }
    }
}

extension View {
    func cursorSheen<S: Shape>(_ shape: S, strength: Double = 0.2) -> some View { modifier(CursorSheen(shape: shape, strength: strength)) }
}


/// Motion used for sliding panels (sidebar, queue): a soft, slightly fluid spring.
enum Motion {
    static let panel = Animation.spring(response: 0.42, dampingFraction: 0.86)
}


/// Drag the window from here (the top bar's empty space), like a title bar.
/// Double-click zooms the window, following the system setting.
struct WindowDragArea: NSViewRepresentable {
    final class DragView: NSView {
        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 {
                let action = UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") ?? "Maximize"
                if action == "Minimize" { window?.performMiniaturize(nil) } else if action != "None" { window?.performZoom(nil) }
                return
            }
            window?.performDrag(with: event)
        }
        override var mouseDownCanMoveWindow: Bool { true }
    }
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
