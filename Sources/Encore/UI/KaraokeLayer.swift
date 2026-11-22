import SwiftUI
import AppKit
import CoreText
import Combine

/// The active lyric line, animated entirely by Core Animation (full display refresh
/// rate, no per-frame main-thread work).
///
/// Behaviour (modelled on the Better Lyrics karaoke style):
/// - The clock runs 150 ms ahead for word-synced lyrics (115 ms for line-synced).
/// - Each word is revealed by a soft gradient that runs across it over 1.6× the
///   word's duration, starting 10 % early; letters light in sequence ("letter wave")
///   and float up slightly as they light, then settle.
/// - Each word glows while sung and the glow decays over max(1.2× duration, 1.2 s).
///   The glow belongs to that word's own glyphs, so it never spills onto other lines.
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
    private let glowHost = CALayer()
    private let litHost = CALayer()
    private var line: LyricLine?
    private var look: LyricLook?
    private var builtWidth: CGFloat = 0
    private var letters: [Letter] = []
    private var words: [Word] = []
    private var subs = Set<AnyCancellable>()
    private var isActive = false
    private var image: CGImage?
    private var rects: [CGRect?] = []
    private var timing: KaraokeTiming?
    private var layoutSize: CGSize = .zero
    private var scale: CGFloat = 2

    /// Per-letter reveal: lit between `on0`…`on1` (song time).
    /// One letter: its lit copy, the sweep mask (in the word's coordinates),
    /// the sweep timing of its word, and when the sweep reaches its centre.
    private struct Letter {
        var layer: CALayer; var mask: CALayer
        var xInWord: CGFloat; var wordWidth: CGFloat
        var sweepStart: Double; var sweepDur: Double
        var hit: Double; var held: Bool
    }
    /// Per-word glow envelope.
    private struct Word { var layer: CALayer; var start: Double; var end: Double; var decay: Double }

    static let wordLead = 0.15, lineLead = 0.115
    var lead: Double { line?.exactWords == true ? Self.wordLead : Self.lineLead }

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer = CALayer()
        layerUsesCoreImageFilters = true
        dim.contentsGravity = .topLeft
        dim.opacity = 0.3
        for l in [dim, glowHost, litHost] {
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
        glowHost.frame = dim.frame
        litHost.frame = dim.frame
        CATransaction.commit()

        // Glyph rectangles from Core Text.
        var utf16: [Int] = []; var o = 0
        for ch in timing.text { utf16.append(o); o += ch.utf16.count }
        utf16.append(o)
        let ctLines = CTFrameGetLines(frame) as! [CTLine]
        var origins = [CGPoint](repeating: .zero, count: ctLines.count)
        CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &origins)
        var rects = [CGRect?](repeating: nil, count: timing.count)
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
        self.image = image
        self.rects = rects
        self.timing = timing
        self.layoutSize = size
        self.scale = scale
        clearAnimated()
        if isActive { buildAnimated(); resync() }
    }

    /// Active → build the per-letter and per-word layers; inactive → just the dim text.
    func setState(active: Bool, dimAlpha: Float, blur: CGFloat) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.5)
        dim.opacity = active ? 0.3 : dimAlpha
        dim.filters = blur > 0.1 ? [CIFilter(name: "CIGaussianBlur", parameters: [kCIInputRadiusKey: blur])!] : nil
        CATransaction.commit()
        guard active != isActive else { return }
        isActive = active
        if active {
            clearAnimated()
            buildAnimated()
            resync()
        } else {
            // Lit words fade back to dim over 0.5 s once the next line starts.
            let lit = (litHost.sublayers ?? []) + (glowHost.sublayers ?? [])
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.33)
            CATransaction.setCompletionBlock { [weak self] in
                guard let self, !self.isActive else { return }
                self.clearAnimated()
            }
            for l in lit { l.removeAllAnimations(); l.mask?.removeAllAnimations(); l.actions = nil; l.opacity = 0 }
            CATransaction.commit()
        }
    }

    private func clearAnimated() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        glowHost.sublayers?.forEach { $0.removeFromSuperlayer() }
        litHost.sublayers?.forEach { $0.removeFromSuperlayer() }
        letters = []; words = []
        CATransaction.commit()
    }

    private func buildAnimated() {
        guard let look, let image, let timing, layoutSize.width > 0 else { return }
        let size = layoutSize, scale = self.scale, rects = self.rects
        CATransaction.begin(); CATransaction.setDisableActions(true)
        func contentsRect(_ r: CGRect) -> CGRect {
            CGRect(x: r.minX / size.width, y: r.minY / size.height, width: r.width / size.width, height: r.height / size.height)
        }

        // Words = runs of letters sharing a timing (syllables of one word join).
        let chars = Array(timing.text)
        var i = 0
        while i < timing.count {
            if chars[i].isWhitespace { i += 1; continue }
            var j = i
            while j + 1 < timing.count, !chars[j + 1].isWhitespace, timing.wordStarts[j + 1] == timing.wordStarts[i] { j += 1 }
            let ws = timing.wordStarts[i], we = max(timing.wordEnds[i], ws + 0.05)
            let dur = we - ws
            // Better Lyrics sweep: starts 10 % early, runs 1.6× the word, edge from -0.15w to 1.45w.
            let sweepStart = ws - 0.1 * dur, sweepDur = 1.6 * dur
            let wordRects = (i...j).compactMap { rects[$0] }
            guard let first = wordRects.first else { i = j + 1; continue }
            let wr = wordRects.dropFirst().reduce(first) { $0.union($1) }
            let w = max(wr.width, 1)
            if look.glow {
                let g = CALayer()
                g.contents = image; g.contentsScale = scale
                g.contentsRect = contentsRect(wr)
                g.frame = wr
                g.opacity = 0
                g.shadowColor = NSColor.white.cgColor
                g.shadowOffset = .zero
                g.shadowRadius = 8 * look.size / 30        // 0.8 rem
                g.shadowOpacity = 1
                g.actions = ["opacity": NSNull()]
                glowHost.addSublayer(g)
                words.append(Word(layer: g, start: ws, end: we, decay: max(1.2 * dur, 1.2)))
            }
            for k in i...j {
                guard let r = rects[k] else { continue }
                let l = CALayer()
                l.contents = image; l.contentsScale = scale
                l.contentsRect = contentsRect(r)
                l.frame = r
                l.actions = ["transform": NSNull(), "position": NSNull()]
                // Soft-edged sweep mask (edge width 0.1 word), positioned in word space.
                let m = CAGradientLayer()
                m.startPoint = CGPoint(x: 0, y: 0.5); m.endPoint = CGPoint(x: 1, y: 0.5)
                m.colors = [NSColor.black.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor, NSColor.clear.cgColor]
                let span = 4 * w
                m.locations = [0, NSNumber(value: Double((2 * w - 0.05 * w) / span)), NSNumber(value: Double((2 * w + 0.05 * w) / span)), 1]
                m.bounds = CGRect(x: 0, y: 0, width: span, height: r.height)
                m.anchorPoint = CGPoint(x: 0.5, y: 0.5)
                m.actions = ["position": NSNull()]
                l.mask = m
                litHost.addSublayer(l)
                let xIn = r.minX - wr.minX
                let centre = (xIn + r.width / 2) / w
                let hit = sweepStart + sweepDur * Double((centre + 0.15) / 1.6)
                letters.append(Letter(layer: l, mask: m, xInWord: xIn, wordWidth: w,
                                      sweepStart: sweepStart, sweepDur: sweepDur, hit: hit, held: dur >= 1.5))
            }
            i = j + 1
        }
        CATransaction.commit()
    }

// MARK: Timeline


    private func ease(_ x: Double) -> Double { let t = max(0, min(1, x)); return t * t * (3 - 2 * t) }

    /// Sweep edge in the word's own coordinates at song time t.
    private func edge(_ L: Letter, at t: Double) -> CGFloat {
        let p = CGFloat(max(0, min(1, (t - L.sweepStart) / max(L.sweepDur, 0.01))))
        return L.wordWidth * (-0.15 + 1.6 * p)
    }

    private func maskX(_ L: Letter, edge e: CGFloat) -> CGFloat { e - L.xInWord }

    private var crest: CGFloat { (look?.size ?? 30) * 0.05 }
    private var settle: CGFloat { (look?.size ?? 30) * 0.02 }

    private func lift(_ L: Letter, at t: Double) -> (CGFloat, CGFloat) {
        guard t >= L.hit else { return (0, 1) }
        let x = (t - L.hit) / 0.9
        if x >= 1 { return (-settle, L.held ? 1.04 : 1) }
        let up = x < 0.35 ? ease(x / 0.35) : 1 - ease((x - 0.35) / 0.65) * (1 - Double(settle / crest))
        let sc = L.held ? 1 + 0.11 * (x < 0.35 ? ease(x / 0.35) : 1 - ease((x - 0.35) / 0.65) * 0.64) : 1
        return (-crest * CGFloat(up), CGFloat(sc))
    }

    private func glowState(_ W: Word, at t: Double) -> Float {
        if t < W.start { return 0 }
        let x = (t - W.start) / W.decay
        return Float(0.5 * (1 - ease(x)))
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
        if look.style == .line {
            for L in letters { L.layer.removeAllAnimations(); L.mask.removeAllAnimations(); L.layer.mask = nil; L.layer.transform = CATransform3DIdentity }
            for W in words { W.layer.removeAllAnimations(); W.layer.opacity = 0 }
            CATransaction.commit(); return
        }
        for L in letters {
            L.layer.removeAllAnimations(); L.mask.removeAllAnimations()
            let e = edge(L, at: songNow)
            L.mask.position = CGPoint(x: maskX(L, edge: e), y: L.layer.bounds.midY)
            let (dy, sc) = lift(L, at: songNow)
            L.layer.transform = CATransform3DScale(CATransform3DMakeTranslation(0, dy, 0), sc, sc, 1)
            guard playing else { continue }
            if songNow < L.sweepStart + L.sweepDur {
                let a = CABasicAnimation(keyPath: "position.x")
                a.fromValue = maskX(L, edge: -0.15 * L.wordWidth)
                a.toValue = maskX(L, edge: 1.45 * L.wordWidth)
                a.beginTime = media(L.sweepStart); a.duration = L.sweepDur / rate
                a.timingFunction = CAMediaTimingFunction(name: .linear)
                a.fillMode = .both; a.isRemovedOnCompletion = false
                L.mask.add(a, forKey: "sweep")
            }
            if songNow < L.hit + 0.9 {
                let up = CAKeyframeAnimation(keyPath: "transform.translation.y")
                up.values = [0, -crest, -settle]
                up.keyTimes = [0, 0.35, 1]
                up.timingFunctions = [CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(name: .easeInEaseOut)]
                let anims: [CAKeyframeAnimation] = L.held ? {
                    let s = CAKeyframeAnimation(keyPath: "transform.scale")
                    s.values = [1, 1.11, 1.04]; s.keyTimes = [0, 0.35, 1]
                    s.timingFunctions = up.timingFunctions
                    return [up, s]
                }() : [up]
                for x in anims {
                    x.beginTime = media(L.hit); x.duration = 0.9 / rate
                    x.fillMode = .both; x.isRemovedOnCompletion = false
                    L.layer.add(x, forKey: x.keyPath)
                }
            }
        }
        for W in words {
            W.layer.removeAllAnimations()
            W.layer.opacity = glowState(W, at: songNow)
            guard playing, songNow < W.start + W.decay else { continue }
            let a = CAKeyframeAnimation(keyPath: "opacity")
            a.values = [0, 0.5, 0]
            a.keyTimes = [0, NSNumber(value: min(0.08, W.decay * 0.1) / (W.decay + 0.08)), 1]
            a.timingFunctions = [CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(name: .easeInEaseOut)]
            a.beginTime = media(W.start - 0.08); a.duration = (W.decay + 0.08) / rate
            a.fillMode = .both; a.isRemovedOnCompletion = false
            W.layer.add(a, forKey: "glow")
        }
        CATransaction.commit()
    }
}
