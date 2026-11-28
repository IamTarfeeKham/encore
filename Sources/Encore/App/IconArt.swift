import AppKit
import CoreGraphics
import CoreImage

/// The app icon artwork: four symbols in crisp tinted glass, in several looks that match
/// macOS's icon styles (Default light/dark, Clear, Tinted) plus Graphite and Red.
/// Shared by the Dock icon and Settings (App/AppIcon.swift) and the Finder icon
/// (scripts/make_icon.swift). The symbols are drawn here on a 100-unit grid (no SF
/// Symbols: their licence doesn't allow them in app icons).
enum IconSymbol: String, CaseIterable, Identifiable, Sendable {
    case spotlight = "Spotlight", note = "Note", cutout = "Cut-out", wave = "Wave"
    var id: String { rawValue }
}

enum IconLook: String, CaseIterable, Sendable {
    case dark, pearl, graphite, red, clearDark, clearLight, tintedDark, tintedLight
}

enum IconArt {
    private static let ciContext = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.displayP3)!])
    private static let cs = CGColorSpace(name: CGColorSpace.displayP3)!

    // MARK: Looks

    private struct Palette {
        var bgTop: CGColor, bgBottom: CGColor
        var glyphTop: CGColor, glyphBottom: CGColor
        var discTop: CGColor, discBottom: CGColor
        var tileShadow: CGFloat = 0.32, tileRim: CGFloat = 1, clear = false
    }

    private static func c(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
        CGColor(colorSpace: cs, components: [CGFloat((hex >> 16) & 0xff) / 255, CGFloat((hex >> 8) & 0xff) / 255, CGFloat(hex & 0xff) / 255, a])!
    }
    private static func mix(_ a: CGColor, _ b: CGColor, _ t: CGFloat) -> CGColor {
        let x = a.converted(to: cs, intent: .defaultIntent, options: nil)?.components ?? [0, 0, 0, 1]
        let y = b.converted(to: cs, intent: .defaultIntent, options: nil)?.components ?? [0, 0, 0, 1]
        return CGColor(colorSpace: cs, components: (0..<4).map { x[$0] + (y[$0] - x[$0]) * t })!
    }

    private static func palette(_ look: IconLook, tint: CGColor) -> Palette {
        let red = (c(0xff5c62), c(0xd61f30)), white = (c(0xffffff, 0.96), c(0xf1eeea, 0.9))
        let darkDisc = (c(0xffffff, 0.12), c(0xffffff, 0.05))
        switch look {
        case .dark: return Palette(bgTop: c(0x2e2e32), bgBottom: c(0x161618), glyphTop: red.0, glyphBottom: red.1, discTop: darkDisc.0, discBottom: darkDisc.1)
        case .pearl: return Palette(bgTop: c(0xfcfbf9), bgBottom: c(0xe9e6e1), glyphTop: red.0, glyphBottom: red.1,
                                    discTop: c(0xffffff, 0.92), discBottom: c(0xf3f0eb, 0.92), tileShadow: 0.26)
        case .graphite: return Palette(bgTop: c(0x48484d), bgBottom: c(0x26262a), glyphTop: white.0, glyphBottom: white.1, discTop: darkDisc.0, discBottom: darkDisc.1)
        case .red: return Palette(bgTop: c(0xf23d47), bgBottom: c(0xb5142b), glyphTop: white.0, glyphBottom: white.1, discTop: darkDisc.0, discBottom: darkDisc.1)
        case .clearDark:
            return Palette(bgTop: c(0xffffff, 0.20), bgBottom: c(0xffffff, 0.07), glyphTop: c(0xffffff, 0.96), glyphBottom: c(0xffffff, 0.78),
                           discTop: c(0xffffff, 0.16), discBottom: c(0xffffff, 0.06), tileShadow: 0.18, tileRim: 1.2, clear: true)
        case .clearLight:
            return Palette(bgTop: c(0xffffff, 0.62), bgBottom: c(0xffffff, 0.36), glyphTop: c(0x3c3c40, 0.92), glyphBottom: c(0x1c1c1f, 0.88),
                           discTop: c(0xffffff, 0.7), discBottom: c(0xffffff, 0.45), tileShadow: 0.14, tileRim: 1.2, clear: true)
        case .tintedDark:
            return Palette(bgTop: mix(c(0x1c1c1f), tint, 0.32), bgBottom: mix(c(0x0e0e10), tint, 0.12),
                           glyphTop: mix(tint, c(0xffffff), 0.35), glyphBottom: tint, discTop: c(0xffffff, 0.12), discBottom: c(0xffffff, 0.05))
        case .tintedLight:
            return Palette(bgTop: mix(c(0xffffff), tint, 0.10), bgBottom: mix(c(0xf1f0ee), tint, 0.18),
                           glyphTop: mix(tint, c(0xffffff), 0.15), glyphBottom: mix(tint, c(0x000000), 0.15),
                           discTop: c(0xffffff, 0.85), discBottom: c(0xffffff, 0.6), tileShadow: 0.24)
        }
    }

    // MARK: Rendering

    /// The finished icon (square, transparent around the tile), `size` pixels.
    static func cgImage(symbol: IconSymbol, look: IconLook, size: Int, tint: CGColor? = nil) -> CGImage? {
        let S = CGFloat(size)
        let p = palette(look, tint: tint ?? c(0xff3b54))
        let full = CGRect(x: 0, y: 0, width: S, height: S)
        let bg = linear(p.bgTop, p.bgBottom, from: S * 0.95, to: S * 0.05, in: full)
        var art: CIImage
        switch symbol {
        case .note:
            art = glass(bg, mask: mask(S) { ctx, u in drawNote(ctx, u, S: S, scale: 1.12) }, S: S, top: p.glyphTop, bottom: p.glyphBottom)
        case .cutout:
            art = glass(bg, mask: mask(S) { ctx, u in
                ctx.addPath(CGPath(roundedRect: CGRect(x: S / 2 - 57 * u, y: S / 2 - 57 * u, width: 114 * u, height: 114 * u),
                                   cornerWidth: 47 * u, cornerHeight: 47 * u, transform: nil))
                ctx.fillPath()
                ctx.setFillColor(gray: 0, alpha: 1); drawNote(ctx, u, S: S, scale: 0.78); ctx.setFillColor(gray: 1, alpha: 1)
            }, S: S, top: p.glyphTop, bottom: p.glyphBottom)
        case .wave:
            art = glass(bg, mask: mask(S) { ctx, u in drawWave(ctx, u, S: S, scale: 1.1) }, S: S, top: p.glyphTop, bottom: p.glyphBottom)
        case .spotlight:
            // The brand mark: the e, its tail ending in the pink spotlight. Dark and light looks use the
            // brand colours (white or ink e, pink spotlight); the others stay one colour, like macOS.
            let pink = (c(0xff6a93), c(0xf23a6e)), ink = (c(0x2c2b30), c(0x151417)), white = (c(0xffffff), c(0xf1eeea))
            let (e, dot): ((CGColor, CGColor), (CGColor, CGColor)) = switch look {
                case .dark: (white, pink)
                case .pearl: (ink, pink)
                default: ((p.glyphTop, p.glyphBottom), (p.glyphTop, p.glyphBottom))
            }
            art = glass(bg, mask: mask(S) { ctx, u in drawSpotlightE(ctx, u, S: S) }, S: S, top: e.0, bottom: e.1)
            art = glass(art, mask: mask(S) { ctx, u in drawSpotlightDot(ctx, u, S: S) }, S: S, top: dot.0, bottom: dot.1)
        }
        guard let artImage = ciContext.createCGImage(art, from: full, format: .RGBA8, colorSpace: cs) else { return nil }
        return tile(artImage, S: S, palette: p)
    }

    static func nsImage(symbol: IconSymbol, look: IconLook, size: Int, tint: CGColor? = nil) -> NSImage? {
        guard let cg = cgImage(symbol: symbol, look: look, size: size, tint: tint) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: size, height: size))
    }

    /// The squircle tile (Apple's grid: 9.8 % inset), its drop shadow, the art and a light rim.
    private static func tile(_ art: CGImage, S: CGFloat, palette p: Palette) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: Int(S), height: Int(S), bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let k = S / 1024
        let t = CGRect(x: 0, y: 0, width: S, height: S).insetBy(dx: S * 0.098, dy: S * 0.098)
        let shape = CGPath(roundedRect: t, cornerWidth: t.width * 0.225, cornerHeight: t.width * 0.225, transform: nil)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -12 * k), blur: 30 * k, color: c(0x000000, p.tileShadow))
        ctx.addPath(shape); ctx.setFillColor(c(0x000000, p.clear ? 0.02 : 1)); ctx.fillPath()
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addPath(shape); ctx.clip()
        if p.clear { ctx.clear(t) }   // clear tiles: only the glass, no solid underlay
        ctx.draw(art, in: t)
        ctx.restoreGState()
        // Rim: bright at the top, fading round the sides.
        ctx.saveGState()
        let inset = 2 * k
        ctx.addPath(CGPath(roundedRect: t.insetBy(dx: inset, dy: inset), cornerWidth: t.width * 0.225 - inset,
                           cornerHeight: t.width * 0.225 - inset, transform: nil))
        ctx.setLineWidth(max(1, 4 * k)); ctx.replacePathWithStrokedPath(); ctx.clip()
        let a = min(1, 0.5 * p.tileRim)
        let g = CGGradient(colorsSpace: cs, colors: [c(0xffffff, a), c(0xffffff, 0.06 * p.tileRim), c(0xffffff, 0.2 * p.tileRim)] as CFArray,
                           locations: [0, 0.45, 1])!
        ctx.drawLinearGradient(g, start: CGPoint(x: t.midX, y: t.maxY), end: CGPoint(x: t.midX, y: t.minY), options: [])
        ctx.restoreGState()
        return ctx.makeImage()
    }

    // MARK: Symbols (100-unit grid, centred)

    private static func U(_ x: CGFloat, _ y: CGFloat, _ u: CGFloat, S: CGFloat) -> CGPoint {
        CGPoint(x: S / 2 + (x - 50) * u, y: S / 2 + (y - 50) * u)
    }

    /// Oval head tilted 20°, a stem tangent to its right side, and a flag of the stem's
    /// own thickness that sweeps right and tapers. Joins are rounded by the mask.
    private static func drawNote(_ ctx: CGContext, _ u: CGFloat, S: CGFloat, scale: CGFloat = 1) {
        let s = u * scale
        func P(_ x: CGFloat, _ y: CGFloat) -> CGPoint { U(x, y, s, S: S) }
        let stemW: CGFloat = 9.5
        ctx.saveGState()
        let hc = P(36, 21)
        ctx.translateBy(x: hc.x, y: hc.y); ctx.rotate(by: 20 * .pi / 180)
        ctx.fillEllipse(in: CGRect(x: -17.5 * s, y: -12.5 * s, width: 35 * s, height: 25 * s))
        ctx.restoreGState()
        let stemX: CGFloat = 52 - stemW + 1.2
        ctx.fill(CGRect(origin: P(stemX, 22), size: CGSize(width: stemW * s, height: 72 * s)))
        let f = CGMutablePath()
        f.move(to: P(stemX, 94))
        f.addLine(to: P(stemX + stemW, 94))
        f.addCurve(to: P(78, 62), control1: P(stemX + stemW + 4, 84), control2: P(80, 78))
        f.addCurve(to: P(73, 50), control1: P(77.5, 57), control2: P(75.5, 53))
        f.addCurve(to: P(stemX + stemW, 74), control1: P(72, 62), control2: P(66, 70))
        f.closeSubpath()
        ctx.addPath(f); ctx.fillPath()
    }

    /// The Spotlight mark, drawn in the wordmark's own units (x-height 60, stroke 14, round ends)
    /// around its centre (62, 128), y down, then scaled onto the grid.
    private static func spotlightSpace(_ ctx: CGContext, _ u: CGFloat, S: CGFloat) {
        let s = u * 1.14
        ctx.translateBy(x: S / 2, y: S / 2 + 3 * s)   // optically a touch above centre
        ctx.scaleBy(x: s, y: -s)
        ctx.translateBy(x: -62, y: -128)
    }
    private static func drawSpotlightE(_ ctx: CGContext, _ u: CGFloat, S: CGFloat) {
        ctx.saveGState(); spotlightSpace(ctx, u, S: S)
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 30, y: 128)); path.addLine(to: CGPoint(x: 90, y: 128))
        path.addArc(center: CGPoint(x: 60, y: 128), radius: 30, startAngle: 0, endAngle: -320 * .pi / 180, clockwise: true)
        ctx.addPath(path.copy(strokingWithWidth: 14, lineCap: .round, lineJoin: .round, miterLimit: 10)); ctx.fillPath()
        ctx.restoreGState()
    }
    private static func drawSpotlightDot(_ ctx: CGContext, _ u: CGFloat, S: CGFloat) {
        ctx.saveGState(); spotlightSpace(ctx, u, S: S)
        ctx.fillEllipse(in: CGRect(x: 92 - 10, y: 155.3 - 10, width: 20, height: 20))
        ctx.restoreGState()
    }

    private static func drawWave(_ ctx: CGContext, _ u: CGFloat, S: CGFloat, scale: CGFloat = 1) {
        let s = u * scale
        let hs: [CGFloat] = [34, 62, 86, 56, 30], w: CGFloat = 11.5, gap: CGFloat = 7.5
        let total = CGFloat(hs.count) * w + CGFloat(hs.count - 1) * gap
        for (i, h) in hs.enumerated() {
            let x = 50 - total / 2 + CGFloat(i) * (w + gap)
            ctx.addPath(CGPath(roundedRect: CGRect(origin: U(x, 50 - h / 2, s, S: S), size: CGSize(width: w * s, height: h * s)),
                               cornerWidth: w * s / 2, cornerHeight: w * s / 2, transform: nil))
        }
        ctx.fillPath()
    }

    // MARK: Glass

    /// Shapes drawn white on black, then blurred and sharply thresholded: smooth, rounded joins.
    private static func mask(_ S: CGFloat, smooth: CGFloat = 7, _ build: (CGContext, CGFloat) -> Void) -> CIImage {
        let n = Int(S)
        let ctx = CGContext(data: nil, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n, space: CGColorSpaceCreateDeviceGray(),
                            bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        ctx.setFillColor(gray: 0, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: n, height: n))
        ctx.setFillColor(gray: 1, alpha: 1)
        build(ctx, S / 100 * 0.6)
        let raw = CIImage(cgImage: ctx.makeImage()!)
        let blurred = raw.clampedToExtent().applyingGaussianBlur(sigma: Double(smooth * S / 1024)).cropped(to: raw.extent)
        let k: CGFloat = 9
        return blurred.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: k, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: k, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: k, w: 0),
            "inputBiasVector": CIVector(x: -(k - 1) / 2, y: -(k - 1) / 2, z: -(k - 1) / 2, w: 0)])
            .applyingFilter("CIColorClamp")
    }

    private static func linear(_ top: CGColor, _ bottom: CGColor, from y0: CGFloat, to y1: CGFloat, in r: CGRect) -> CIImage {
        CIFilter(name: "CILinearGradient", parameters: ["inputPoint0": CIVector(x: 0, y: y0), "inputPoint1": CIVector(x: 0, y: y1),
                                                        "inputColor0": CIColor(cgColor: top), "inputColor1": CIColor(cgColor: bottom)])!
            .outputImage!.cropped(to: r)
    }
    private static func scaled(_ m: CIImage, _ a: CGFloat) -> CIImage {
        m.applyingFilter("CIColorMatrix", parameters: ["inputRVector": CIVector(x: a, y: 0, z: 0, w: 0),
                                                       "inputGVector": CIVector(x: 0, y: a, z: 0, w: 0),
                                                       "inputBVector": CIVector(x: 0, y: 0, z: a, w: 0)])
    }
    private static func over(_ top: CIImage, _ bottom: CIImage, mask: CIImage) -> CIImage {
        top.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: bottom, kCIInputMaskImageKey: mask])
    }

    /// Crisp tinted glass: an ambient and a contact shadow, a body lighter at the top, a
    /// clean sheen across the upper part, and an even rim lit from the top-left.
    private static func glass(_ base: CIImage, mask: CIImage, S: CGFloat, top: CGColor, bottom: CGColor, rim: CGFloat = 0.85,
                              shadow: CGFloat = 1) -> CIImage {
        let full = CGRect(x: 0, y: 0, width: S, height: S)
        let black = CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: full)
        var out = base
        let ambient = mask.transformed(by: CGAffineTransform(translationX: 0, y: -S * 0.02)).clampedToExtent()
            .applyingGaussianBlur(sigma: Double(S * 0.028)).cropped(to: full)
        out = over(black, out, mask: scaled(ambient, 0.22 * shadow))
        let contact = mask.transformed(by: CGAffineTransform(translationX: 0, y: -S * 0.006)).clampedToExtent()
            .applyingGaussianBlur(sigma: Double(S * 0.006)).cropped(to: full)
        out = over(black, out, mask: scaled(contact, 0.25 * shadow))
        out = over(linear(top, bottom, from: S * 0.78, to: S * 0.22, in: full).composited(over: out), out, mask: mask)
        let sheen = linear(CGColor(red: 1, green: 1, blue: 1, alpha: 0.28), CGColor(red: 1, green: 1, blue: 1, alpha: 0), from: S * 0.8, to: S * 0.5, in: full)
        out = over(sheen.composited(over: out), out, mask: mask)
        let eroded = mask.applyingFilter("CIMorphologyMinimum", parameters: ["inputRadius": max(1, S * 0.006)])
        let rimMask = mask.applyingFilter("CISubtractBlendMode", parameters: [kCIInputBackgroundImageKey: mask, kCIInputImageKey: eroded])
        let light = CIFilter(name: "CILinearGradient", parameters: [
            "inputPoint0": CIVector(x: S * 0.3, y: S * 0.75), "inputPoint1": CIVector(x: S * 0.7, y: S * 0.25),
            "inputColor0": CIColor(red: 1, green: 1, blue: 1, alpha: 1), "inputColor1": CIColor(red: 1, green: 1, blue: 1, alpha: 0.1)])!
            .outputImage!.cropped(to: full)
        out = over(light.composited(over: out), out, mask: scaled(rimMask, rim))
        return out
    }
}
