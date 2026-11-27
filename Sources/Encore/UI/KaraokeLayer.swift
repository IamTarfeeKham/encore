import SwiftUI
import AppKit
import CoreText
import Combine

/// The active lyric line, animated entirely by Core Animation (full display refresh
/// rate, no per-frame main-thread work).
///
/// Behaviour:
/// - The clock runs 150 ms ahead for word-synced lyrics (115 ms for line-synced).
/// - Each syllable is filled by a soft edge (about half a letter wide) that crosses it
///   in exactly the time it is sung, so long held notes fill slowly with the voice.
/// - Each letter floats up as the edge reaches it (a smooth, critically damped rise of
///   about 0.14 em) and stays up while the line plays.
/// - A soft halo blooms around the letters being sung and fades behind them; held
///   notes keep theirs until the note ends.
/// - Long held notes give off a few small sparkles that drift up and fade.
struct KaraokeLineView: NSViewRepresentable {
    let line: LyricLine
    let look: LyricLook
    var active = true
    var dimAlpha: Float = 0.34
    var blur: CGFloat = 0

    func makeNSView(context: Context) -> KaraokeLayerView { KaraokeLayerView() }
    func updateNSView(_ v: KaraokeLayerView, context: Context) {
        v.configure(line: line, look: look)
        v.setState(active: active, dimAlpha: dimAlpha, blur: blur)
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: KaraokeLayerView, context: Context) -> CGSize? {
        let width = proposal.width ?? 600
        return CGSize(width: width, height: KaraokeLayerView.measure(text: KaraokeTiming(line).text, look: look, width: width).height)
    }
}


final class KaraokeLayerView: NSView {
    private let dim = CALayer()
    private let litHost = CALayer()
    private let sparkHost = CALayer()
    private var line: LyricLine?
    private var look: LyricLook?
    private var builtWidth: CGFloat = 0
    private var letters: [Letter] = []
    private var sparks: [Spark] = []
    private var subs = Set<AnyCancellable>()
    private var isActive = false
    private var image: CGImage?
    private var rects: [CGRect?] = []
    /// Each character's glyph outline, in its rect's own (top-down) coordinates — the halo's shape.
    private var paths: [CGPath?] = []
    private var fadingOut = false
    private var inactiveAlpha: Float = KaraokeLayerView.unsungAlpha
    private var timing: KaraokeTiming?
    private var layoutSize: CGSize = .zero
    private var scale: CGFloat = 2

    /// One letter: its lit copy and soft-edged sweep mask (positioned in its syllable's
    /// coordinates), its halo, and the song times the edge touches, crosses and leaves it.
    private struct Letter {
        var box: CALayer; var layer: CALayer; var mask: CALayer; var glow: CALayer?
        var xInWord: CGFloat; var wordWidth: CGFloat; var feather: CGFloat
        var ws: Double; var dur: Double
        var start: Double; var hit: Double; var full: Double
        var glowHold: Double
    }
    /// One sparkle off a held note.
    private struct Spark {
        var layer: CALayer; var at: Double; var life: Double
        var from: CGPoint; var to: CGPoint
    }

    static let wordLead = 0.15, lineLead = 0.115
    /// Brightness of words not yet sung (and of inactive lines).
    static let unsungAlpha: Float = 0.38
    var lead: Double { line?.exactWords == true ? Self.wordLead : Self.lineLead }
    /// Light the whole line at once: chosen in Settings, or forced when the lyrics have no
    /// per-word timing (a guessed sweep would run on while the singer pauses).
    private var wholeLine: Bool { look?.style == .line || line?.exactWords != true }

    /// A soft round dot, white in the middle fading to nothing.
    private static let dot: CGImage? = {
        let n = 64
        guard let ctx = CGContext(data: nil, width: n, height: n, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                 colors: [NSColor.white.cgColor, NSColor.white.withAlphaComponent(0.55).cgColor, NSColor.white.withAlphaComponent(0).cgColor] as CFArray,
                                 locations: [0, 0.35, 1]) else { return nil }
        let c = CGPoint(x: n / 2, y: n / 2)
        ctx.drawRadialGradient(g, startCenter: c, startRadius: 0, endCenter: c, endRadius: CGFloat(n / 2), options: [])
        return ctx.makeImage()
    }()

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer = CALayer()
        layerUsesCoreImageFilters = true
        dim.contentsGravity = .topLeft
        dim.opacity = Self.unsungAlpha
        for l in [dim, litHost, sparkHost] {
            l.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
            layer?.addSublayer(l)
        }
        MainActor.assumeIsolated {
            let p = PlayerController.shared
            p.clock.$epoch.dropFirst().receive(on: RunLoop.main).sink { [weak self] _ in self?.resync() }.store(in: &subs)
            p.now.$isPlaying.dropFirst().receive(on: RunLoop.main).sink { [weak self] _ in
                DispatchQueue.main.async { self?.resync() }
            }.store(in: &subs)
            Prefs.shared.$lyricsOffset.dropFirst().receive(on: RunLoop.main).sink { [weak self] _ in
                DispatchQueue.main.async { self?.resync() }
            }.store(in: &subs)
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: Layout

    static func attributed(_ text: String, look: LyricLook) -> NSAttributedString {
        let para = NSMutableParagraphStyle()
        para.lineSpacing = 4
        para.alignment = look.center ? .center : .left
        para.lineBreakMode = .byWordWrapping
        return NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: look.size, weight: .bold),
            .foregroundColor: NSColor.white,
            .paragraphStyle: para,
        ])
    }

    static func measure(text: String, look: LyricLook, width: CGFloat) -> CGSize {
        let fs = CTFramesetterCreateWithAttributedString(attributed(text, look: look))
        let s = CTFramesetterSuggestFrameSizeWithConstraints(fs, CFRange(location: 0, length: 0), nil,
                                                             CGSize(width: width, height: .greatestFiniteMagnitude), nil)
        // Room above for letters that rise (and their sparkles stay inside the row's slot).
        return CGSize(width: width, height: ceil(s.height) + 6)
    }

    func configure(line: LyricLine, look: LyricLook) {
        let changed = self.line?.id != line.id || self.line?.text != line.text || self.look != look
        self.line = line
        self.look = look
        if changed || abs(builtWidth - bounds.width) > 0.5 { rebuild() }
    }

    override func layout() {
        super.layout()
        if abs(builtWidth - bounds.width) > 0.5 { rebuild() }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { rebuild() }
    }

    private func rebuild() {
        guard let line, let look, bounds.width > 10, let window else { return }
        let timing = KaraokeTiming(line)
        builtWidth = bounds.width
        let scale = window.backingScaleFactor
        let size = Self.measure(text: timing.text, look: look, width: bounds.width)

        let fs = CTFramesetterCreateWithAttributedString(Self.attributed(timing.text, look: look))
        let frame = CTFramesetterCreateFrame(fs, CFRange(location: 0, length: 0), CGPath(rect: CGRect(origin: .zero, size: size), transform: nil), nil)

        let pw = Int(ceil(size.width * scale)), ph = Int(ceil(size.height * scale))
        guard pw > 0, ph > 0, let ctx = CGContext(data: nil, width: pw, height: ph, bitsPerComponent: 8, bytesPerRow: 0,
                                                  space: CGColorSpaceCreateDeviceRGB(),
                                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        ctx.scaleBy(x: scale, y: scale)
        CTFrameDraw(frame, ctx)
        guard let image = ctx.makeImage() else { return }

        CATransaction.begin(); CATransaction.setDisableActions(true)
        dim.frame = CGRect(origin: .zero, size: size)
        dim.contents = image
        dim.contentsScale = scale
        litHost.frame = dim.frame
        sparkHost.frame = dim.frame
        CATransaction.commit()

        // Glyph rectangles from Core Text.
        var utf16: [Int] = []; var o = 0
        for ch in timing.text { utf16.append(o); o += ch.utf16.count }
        utf16.append(o)
        let ctLines = CTFrameGetLines(frame) as! [CTLine]
        var origins = [CGPoint](repeating: .zero, count: ctLines.count)
        CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &origins)
        var rects = [CGRect?](repeating: nil, count: timing.count)
        var charAt: [Int: Int] = [:]
        for (ci, off) in utf16.dropLast().enumerated() { charAt[off] = ci }
        var glyphs: [(ci: Int, li: Int, x: CGFloat, path: CGPath)] = []
        for (li, ctLine) in ctLines.enumerated() {
            for run in CTLineGetGlyphRuns(ctLine) as! [CTRun] {
                let n = CTRunGetGlyphCount(run)
                guard n > 0 else { continue }
                let font = (CTRunGetAttributes(run) as NSDictionary)[kCTFontAttributeName] as! CTFont
                var gs = [CGGlyph](repeating: 0, count: n), pos = [CGPoint](repeating: .zero, count: n), idx = [CFIndex](repeating: 0, count: n)
                CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &gs)
                CTRunGetPositions(run, CFRange(location: 0, length: 0), &pos)
                CTRunGetStringIndices(run, CFRange(location: 0, length: 0), &idx)
                for g in 0..<n {
                    guard let ci = charAt[idx[g]], let path = CTFontCreatePathForGlyph(font, gs[g], nil) else { continue }
                    glyphs.append((ci, li, origins[li].x + pos[g].x, path))
                }
            }
        }
        for (li, ctLine) in ctLines.enumerated() {
            let r = CTLineGetStringRange(ctLine)
            var asc: CGFloat = 0, desc: CGFloat = 0, lead: CGFloat = 0
            _ = CTLineGetTypographicBounds(ctLine, &asc, &desc, &lead)
            let top = size.height - origins[li].y - asc
            for ci in 0..<timing.count {
                let off = utf16[ci]
                guard off >= r.location, off < r.location + r.length else { continue }
                let x0 = origins[li].x + CTLineGetOffsetForStringIndex(ctLine, off, nil)
                let x1 = origins[li].x + CTLineGetOffsetForStringIndex(ctLine, utf16[ci + 1], nil)
                rects[ci] = CGRect(x: x0, y: top - 3, width: max(x1 - x0, 0.5), height: asc + desc + 6)
            }
        }
        var paths = [CGPath?](repeating: nil, count: timing.count)
        for g in glyphs {
            guard let r = rects[g.ci] else { continue }
            let baseline = size.height - origins[g.li].y
            var t = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: g.x - r.minX, ty: baseline - r.minY)
            guard let placed = g.path.copy(using: &t) else { continue }
            if let old = paths[g.ci] { let both = CGMutablePath(); both.addPath(old); both.addPath(placed); paths[g.ci] = both } else { paths[g.ci] = placed }
        }
        self.paths = paths
        self.image = image
        self.rects = rects
        self.timing = timing
        self.layoutSize = size
        self.scale = scale
        clearAnimated()
        if isActive { buildAnimated(); resync() } else if fadingOut {
            fadingOut = false
            CATransaction.begin(); CATransaction.setDisableActions(true)
            dim.opacity = inactiveAlpha
            CATransaction.commit()
        }
    }

    /// Active → each letter becomes its own little stack (halo, dim copy, lit copy) that
    /// rises as one; inactive → just the line's dim text.
    func setState(active: Bool, dimAlpha: Float, blur: CGFloat) {
        inactiveAlpha = dimAlpha
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.5)
        if active || !fadingOut {
            if active { CATransaction.setDisableActions(true) }
            dim.opacity = active ? 0 : dimAlpha
        }
        dim.filters = blur > 0.1 ? [CIFilter(name: "CIGaussianBlur", parameters: [kCIInputRadiusKey: blur])!] : nil
        CATransaction.commit()
        guard active != isActive else { return }
        isActive = active
        if active {
            fadingOut = false
            clearAnimated()
            buildAnimated()
            resync()
        } else {
            // The sung line settles: letters ease back down while the lit copies fade to dim.
            // Then the whole-line dim text takes over (identical pixels, so no jump).
            fadingOut = true
            CATransaction.begin(); CATransaction.setDisableActions(true)
            for L in letters {
                for l in [L.box, L.layer, L.glow].compactMap({ $0 }) {
                    if let p = l.presentation() { l.transform = p.transform; l.opacity = p.opacity }
                    l.removeAllAnimations()
                }
                if let p = L.mask.presentation() { L.mask.position = p.position }
                L.mask.removeAllAnimations()
            }
            for S in sparks {
                if let p = S.layer.presentation() { S.layer.position = p.position; S.layer.opacity = p.opacity; S.layer.transform = p.transform }
                S.layer.removeAllAnimations()
            }
            CATransaction.commit()
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.45)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(controlPoints: 0.3, 0, 0.2, 1))
            CATransaction.setCompletionBlock { [weak self] in
                guard let self, !self.isActive else { return }
                self.fadingOut = false
                CATransaction.begin(); CATransaction.setDisableActions(true)
                self.dim.opacity = dimAlpha
                CATransaction.commit()
                self.clearAnimated()
            }
            for L in letters {
                L.box.actions = nil; L.box.transform = CATransform3DIdentity
                L.layer.actions = nil; L.layer.opacity = 0
                L.glow?.actions = nil; L.glow?.opacity = 0
            }
            for S in sparks { S.layer.actions = nil; S.layer.opacity = 0 }
            CATransaction.commit()
        }
    }

    private func clearAnimated() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        litHost.sublayers?.forEach { $0.removeFromSuperlayer() }
        sparkHost.sublayers?.forEach { $0.removeFromSuperlayer() }
        letters = []; sparks = []
        CATransaction.commit()
    }

    private func buildAnimated() {
        guard let look, let line, let image, let timing, layoutSize.width > 0 else { return }
        let size = layoutSize, scale = self.scale, rects = self.rects
        CATransaction.begin(); CATransaction.setDisableActions(true)
        func contentsRect(_ r: CGRect, in s: CGSize) -> CGRect {
            CGRect(x: r.minX / s.width, y: r.minY / s.height, width: r.width / s.width, height: r.height / s.height)
        }
        let styled = !wholeLine
        let paths = self.paths
        let feather = look.size * 0.5
        let lift = liftAmount
        var rng = SplitMix(seed: UInt64(truncatingIfNeeded: line.id &* 7919 &+ timing.count))

        // Syllables = runs of letters sharing a start time (the parts of one word light in turn).
        let chars = Array(timing.text)
        // How long each whole word is sung (all its syllables), for the sparkles.
        var wordSpan = [Double](repeating: 0, count: timing.count)
        var a = 0
        while a < timing.count {
            if chars[a].isWhitespace { a += 1; continue }
            var b = a
            while b + 1 < timing.count, !chars[b + 1].isWhitespace { b += 1 }
            for x in a...b { wordSpan[x] = timing.ends[b] - timing.starts[a] }
            a = b + 1
        }
        var i = 0
        while i < timing.count {
            if chars[i].isWhitespace { i += 1; continue }
            var j = i
            while j + 1 < timing.count, !chars[j + 1].isWhitespace, timing.wordStarts[j + 1] == timing.wordStarts[i] { j += 1 }
            // The letters' own timing: for word-synced lyrics that's the syllable; for
            // line-synced ones each word gets its share of the line, so the fill runs across it.
            let ws = timing.starts[i], we = max(timing.ends[j], ws + 0.05)
            let dur = we - ws
            let wordRects = (i...j).compactMap { rects[$0] }
            guard let first = wordRects.first else { i = j + 1; continue }
            let wr = wordRects.dropFirst().reduce(first) { $0.union($1) }
            let w = max(wr.width, 1)
            // Edge runs from −f/2 (at the syllable's start) to w + f/2 (at its end).
            func time(atEdge x: CGFloat) -> Double { ws + dur * Double((x + feather / 2) / (w + feather)) }
            let held = dur >= 0.75
            for k in i...j {
                guard let r = rects[k] else { continue }
                // One stack per letter, so the dim and lit copies (and the halo) rise together.
                let box = CALayer()
                box.frame = r
                box.actions = ["transform": NSNull(), "position": NSNull(), "bounds": NSNull()]
                let local = CGRect(origin: .zero, size: r.size)
                var g: CALayer?
                if styled, look.glow, let path = paths[k] {
                    // A halo drawn from the letter's own outline (shadow only, no fill).
                    let gl = CALayer()
                    gl.frame = local
                    gl.shadowPath = path
                    gl.shadowColor = NSColor.white.cgColor
                    gl.shadowOffset = .zero
                    gl.shadowRadius = look.size * 0.3
                    gl.shadowOpacity = 1
                    gl.opacity = 0
                    gl.actions = ["opacity": NSNull()]
                    box.addSublayer(gl)
                    g = gl
                }
                let d = CALayer()
                d.contents = image; d.contentsScale = scale
                d.contentsRect = contentsRect(r, in: size)
                d.frame = local
                d.opacity = Self.unsungAlpha
                d.actions = ["opacity": NSNull()]
                box.addSublayer(d)
                let l = CALayer()
                l.contents = image; l.contentsScale = scale
                l.contentsRect = contentsRect(r, in: size)
                l.frame = local
                l.actions = ["opacity": NSNull()]
                let xIn = r.minX - wr.minX
                // Soft-edged sweep mask, half a letter wide, positioned in syllable space.
                let m = CAGradientLayer()
                m.startPoint = CGPoint(x: 0, y: 0.5); m.endPoint = CGPoint(x: 1, y: 0.5)
                m.colors = [NSColor.black.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor, NSColor.clear.cgColor]
                let half = w + 2 * feather
                m.locations = [0, NSNumber(value: Double((half - feather / 2) / (2 * half))),
                               NSNumber(value: Double((half + feather / 2) / (2 * half))), 1]
                m.bounds = CGRect(x: 0, y: 0, width: 2 * half, height: r.height + 4)
                m.anchorPoint = CGPoint(x: 0.5, y: 0.5)
                m.actions = ["position": NSNull()]
                l.mask = m
                box.addSublayer(l)
                litHost.addSublayer(box)
                let s0 = time(atEdge: xIn), s1 = time(atEdge: xIn + r.width / 2), s2 = time(atEdge: xIn + r.width + feather)
                letters.append(Letter(box: box, layer: l, mask: m, glow: g, xInWord: xIn, wordWidth: w, feather: feather,
                                      ws: ws, dur: dur, start: s0, hit: s1, full: s2,
                                      glowHold: held ? max(s2, we) : s2))
            }
            // Sparkles drift up off notes the singer holds.
            if styled, look.particles, wordSpan[i] >= 0.9, let dot = Self.dot {
                let n = max(1, min(10, Int((dur / 0.16).rounded())))
                for q in 0..<n {
                    let at = ws + 0.08 + (dur - 0.1) * (Double(q) + rng.unit() * 0.7) / Double(n)
                    let edgeX = min(max(CGFloat((at - ws) / dur) * (w + feather) - feather / 2, 0), w)
                    let x = wr.minX + edgeX + CGFloat(rng.unit() - 0.5) * look.size * 0.3
                    let y = wr.minY + look.size * 0.3 - lift
                    let rad = look.size * CGFloat(0.05 + 0.04 * rng.unit())
                    let p = CALayer()
                    p.contents = dot
                    p.bounds = CGRect(x: 0, y: 0, width: rad * 5, height: rad * 5)
                    p.position = CGPoint(x: x, y: y)
                    p.opacity = 0
                    p.actions = ["position": NSNull(), "opacity": NSNull(), "transform": NSNull()]
                    sparkHost.addSublayer(p)
                    let to = CGPoint(x: x + CGFloat(rng.unit() - 0.5) * look.size * 0.5,
                                     y: y - look.size * CGFloat(0.55 + 0.45 * rng.unit()))
                    sparks.append(Spark(layer: p, at: at, life: 0.9 + 0.5 * rng.unit(), from: CGPoint(x: x, y: y), to: to))
                }
            }
            i = j + 1
        }
        CATransaction.commit()
    }

// MARK: Timeline

    private var liftAmount: CGFloat { look?.lift == true ? (look?.size ?? 30) * (wholeLine ? 0.1 : 0.14) : 0 }

    /// Critically damped rise: quick to start, settles softly with no bounce (~1 s to rest).
    private static let liftDuration = 1.2
    private static func rise(_ x: Double) -> Double {
        guard x > 0 else { return 0 }
        let w = 5.5 * x
        return x >= liftDuration ? 1 : 1 - (1 + w) * exp(-w)
    }
    private static let riseValues: [Double] = (0...24).map { rise(liftDuration * Double($0) / 24) }

    private func edge(_ L: Letter, at t: Double) -> CGFloat {
        let p = CGFloat(max(0, min(1, (t - L.ws) / max(L.dur, 0.01))))
        return -L.feather / 2 + (L.wordWidth + L.feather) * p
    }

    private func maskX(_ L: Letter, edge e: CGFloat) -> CGFloat { e - L.xInWord }

    private func ease(_ x: Double) -> Double { let t = max(0, min(1, x)); return t * t * (3 - 2 * t) }

    /// Halo envelope: in as the edge arrives, held through a held note, then out over 0.8 s.
    private static let glowPeak: Float = 0.45, glowFade = 0.8
    private func glowOpacity(_ L: Letter, at t: Double) -> Float {
        let a = L.start - 0.05
        if t <= a { return 0 }
        if t < L.hit { return Self.glowPeak * Float(ease((t - a) / max(L.hit - a, 0.01))) }
        if t <= L.glowHold { return Self.glowPeak }
        return Self.glowPeak * Float(1 - ease((t - L.glowHold) / Self.glowFade))
    }

    /// Re-anchors all Core Animation timelines to the current song position.
    func resync() {
        guard let look, window != nil, isActive else { return }
        let (clockNow, playing, rate) = MainActor.assumeIsolated { () -> (Double, Bool, Double) in
            let p = PlayerController.shared
            return (p.clock.now() + Prefs.shared.lyricsOffset, p.now.isPlaying, max(p.playbackRate, 0.1))
        }
        let songNow = clockNow + lead
        let mediaNow = CACurrentMediaTime()
        func media(_ t: Double) -> CFTimeInterval { mediaNow + (t - songNow) / rate }

        CATransaction.begin(); CATransaction.setDisableActions(true)
        let lift = liftAmount
        if wholeLine {
            // The whole line fades up and rises together as it starts.
            let t0 = letters.map(\.ws).min() ?? 0
            let fadeIn = 0.3
            for L in letters {
                L.box.removeAllAnimations(); L.mask.removeAllAnimations(); L.layer.removeAllAnimations()
                L.layer.mask = nil
                L.layer.opacity = Float(ease((songNow - t0) / fadeIn))
                L.box.transform = CATransform3DMakeTranslation(0, -lift * CGFloat(Self.rise(songNow - t0)), 0)
                guard playing else { continue }
                if songNow < t0 + fadeIn {
                    let f = CABasicAnimation(keyPath: "opacity")
                    f.fromValue = 0; f.toValue = 1
                    f.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    f.beginTime = media(t0); f.duration = fadeIn / rate
                    f.fillMode = .both; f.isRemovedOnCompletion = false
                    L.layer.add(f, forKey: "fade")
                }
                if lift > 0, songNow < t0 + Self.liftDuration {
                    let up = CAKeyframeAnimation(keyPath: "transform.translation.y")
                    up.values = Self.riseValues.map { -Double(lift) * $0 }
                    up.beginTime = media(t0); up.duration = Self.liftDuration / rate
                    up.fillMode = .both; up.isRemovedOnCompletion = false
                    L.box.add(up, forKey: "lift")
                }
            }
            CATransaction.commit(); return
        }
        for L in letters {
            L.box.removeAllAnimations(); L.mask.removeAllAnimations(); L.glow?.removeAllAnimations()
            let e = edge(L, at: songNow)
            L.mask.position = CGPoint(x: maskX(L, edge: e), y: L.layer.bounds.midY)
            let dy = -lift * CGFloat(Self.rise(songNow - L.start))
            L.box.transform = CATransform3DMakeTranslation(0, dy, 0)
            L.glow?.opacity = glowOpacity(L, at: songNow)
            guard playing else { continue }
            if songNow < L.ws + L.dur {
                let a = CABasicAnimation(keyPath: "position.x")
                a.fromValue = maskX(L, edge: -L.feather / 2)
                a.toValue = maskX(L, edge: L.wordWidth + L.feather / 2)
                a.beginTime = media(L.ws); a.duration = max(L.dur, 0.01) / rate
                a.timingFunction = CAMediaTimingFunction(name: .linear)
                a.fillMode = .both; a.isRemovedOnCompletion = false
                L.mask.add(a, forKey: "sweep")
            }
            if lift > 0, songNow < L.start + Self.liftDuration {
                let up = CAKeyframeAnimation(keyPath: "transform.translation.y")
                up.values = Self.riseValues.map { -Double(lift) * $0 }
                up.calculationMode = .linear
                up.beginTime = media(L.start); up.duration = Self.liftDuration / rate
                up.fillMode = .both; up.isRemovedOnCompletion = false
                L.box.add(up, forKey: "lift")
            }
            if let g = L.glow, songNow < L.glowHold + Self.glowFade {
                let a0 = L.start - 0.05, total = L.glowHold + Self.glowFade - a0
                let k = CAKeyframeAnimation(keyPath: "opacity")
                k.values = [0, Self.glowPeak, Self.glowPeak, 0]
                k.keyTimes = [0, NSNumber(value: (L.hit - a0) / total), NSNumber(value: (L.glowHold - a0) / total), 1]
                k.timingFunctions = [CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(name: .linear), CAMediaTimingFunction(name: .easeInEaseOut)]
                k.beginTime = media(a0); k.duration = total / rate
                k.fillMode = .both; k.isRemovedOnCompletion = false
                g.add(k, forKey: "glow")
            }
        }
        for S in sparks {
            S.layer.removeAllAnimations()
            S.layer.opacity = 0
            guard playing, songNow < S.at + S.life else { continue }
            let pos = CABasicAnimation(keyPath: "position")
            pos.fromValue = NSValue(point: S.from); pos.toValue = NSValue(point: S.to)
            pos.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.6, 0.3, 1)
            let op = CAKeyframeAnimation(keyPath: "opacity")
            op.values = [0, 0.9, 0]; op.keyTimes = [0, 0.18, 1]
            op.timingFunctions = [CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(name: .easeIn)]
            let sc = CAKeyframeAnimation(keyPath: "transform.scale")
            sc.values = [0.4, 1, 0.6]; sc.keyTimes = [0, 0.25, 1]
            let grp = CAAnimationGroup()
            grp.animations = [pos, op, sc]
            grp.beginTime = media(S.at); grp.duration = S.life / rate
            grp.fillMode = .both; grp.isRemovedOnCompletion = false
            S.layer.add(grp, forKey: "spark")
        }
        CATransaction.commit()
    }
}

/// Small deterministic random source, so a line's sparkles land the same way every time.
private struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E3779B97F4A7C15 }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
}
