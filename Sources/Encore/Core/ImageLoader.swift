import AppKit
import SwiftUI
import ImageIO
import CoreImage

/// Memory + disk cached image loading. Images are decoded and downsampled to
/// the size they are shown at, off the main thread, so scrolling never has to
/// decode a 1200px JPEG on the fly.
actor ImageLoader {
    static let shared = ImageLoader()

    private var inflight: [String: Task<CGImage?, Never>] = [:]
    private let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.urlCache = URLCache(memoryCapacity: 16 << 20, diskCapacity: 512 << 20,
                              directory: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                                .appendingPathComponent("images"))
        c.requestCachePolicy = .returnCacheDataElseLoad
        c.tlsMinimumSupportedProtocolVersion = .TLSv12
        return URLSession(configuration: c)
    }()

    /// Decoded-image cache (NSCache is thread-safe), ~96 MB of pixels: enough for the
    /// screen and the sections near it; anything older re-decodes from the disk cache.
    nonisolated(unsafe) static let sharedCache: NSCache<NSString, CGImageBox> = {
        let c = NSCache<NSString, CGImageBox>()
        c.totalCostLimit = 96 << 20
        return c
    }()

    /// Synchronous memory-cache lookup so cells that scroll back into view render instantly.
    nonisolated func cached(_ url: URL, maxPixel: Int) -> CGImage? {
        Self.sharedCache.object(forKey: Self.key(url, maxPixel) as NSString)?.image
    }

    nonisolated static func key(_ url: URL, _ maxPixel: Int) -> String { "\(maxPixel)|\(url.absoluteString)" }

    func cgImage(for url: URL, maxPixel: Int) async -> CGImage? {
        let key = Self.key(url, maxPixel)
        if let img = Self.sharedCache.object(forKey: key as NSString)?.image { return img }
        if let t = inflight[key] { return await t.value }
        let session = self.session
        let task = Task.detached(priority: .userInitiated) { () -> CGImage? in
            guard let (data, resp) = try? await session.data(from: url),
                  ((resp as? HTTPURLResponse)?.statusCode ?? 200) < 400 else { return nil }
            return Self.downsample(data, maxPixel: maxPixel)
        }
        inflight[key] = task
        let img = await task.value
        inflight[key] = nil
        if let img {
            Self.sharedCache.setObject(CGImageBox(img), forKey: key as NSString, cost: img.bytesPerRow * img.height)
        }
        return img
    }

    /// Full NSImage (used for Now Playing artwork in Control Center).
    func image(for url: URL) async -> NSImage? {
        guard let cg = await cgImage(for: url, maxPixel: 1200) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    /// Heavily blurred, saturated, small version of artwork for animated
    /// backgrounds. Blurring a 64px image is nearly free and it scales up smoothly.
    func ambient(for url: URL) async -> CGImage? {
        let key = "ambient|" + url.absoluteString
        if let img = Self.sharedCache.object(forKey: key as NSString)?.image { return img }
        guard let small = await cgImage(for: url, maxPixel: 96) else { return nil }
        let out = await Task.detached(priority: .utility) { Self.makeAmbient(small) }.value
        if let out { Self.sharedCache.setObject(CGImageBox(out), forKey: key as NSString, cost: out.bytesPerRow * out.height) }
        return out
    }

    nonisolated static func downsample(_ data: Data, maxPixel: Int) -> CGImage? {
        let opts = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let src = CGImageSourceCreateWithData(data as CFData, opts) else { return nil }
        let thumbOpts = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,      // decode now, off the main thread
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ] as CFDictionary
        return CGImageSourceCreateThumbnailAtIndex(src, 0, thumbOpts)
    }

    nonisolated static let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    nonisolated static func makeAmbient(_ img: CGImage) -> CGImage? {
        let input = CIImage(cgImage: img)
        let extent = input.extent
        let saturated = input.applyingFilter("CIColorControls", parameters: [
            kCIInputSaturationKey: 1.7, kCIInputBrightnessKey: -0.02, kCIInputContrastKey: 1.05,
        ])
        let blurred = saturated.clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: extent.width * 0.09])
            .cropped(to: extent)
        // Keep the artwork's overall brightness. Blurring spreads a small bright spot
        // (a light flare on a mostly black cover) over the whole picture, and the
        // saturation boost and the additive layers amplify it, so a dark cover came out
        // as a light background. Dark covers are scaled down to match their own average
        // brightness; covers of medium brightness or brighter are left as they were.
        let k = toneScale(for: input, extent: extent)
        let toned = k < 0.999
            ? blurred.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: k, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: k, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: k, w: 0),
            ])
            : blurred
        return ciContext.createCGImage(toned, from: extent)
    }

    /// Brightness factor for the ambient image: 1 for covers whose average luminance is
    /// 0.42 or more, scaling down to 0.3 for very dark covers.
    nonisolated private static func toneScale(for image: CIImage, extent: CGRect) -> CGFloat {
        let avg = image.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: extent)])
        var px = [UInt8](repeating: 0, count: 4)
        ciContext.render(avg, toBitmap: &px, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                         format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        let lum = (0.2126 * Double(px[0]) + 0.7152 * Double(px[1]) + 0.0722 * Double(px[2])) / 255
        return CGFloat(min(1, max(0.3, lum / 0.42)))
    }
}

final class CGImageBox: NSObject {
    let image: CGImage
    init(_ i: CGImage) { image = i }
}

/// Artwork view: fixed frame, image fills and is clipped to it (so 16:9 video
/// thumbnails are centre-cropped instead of spilling over neighbouring text).
struct Artwork: View {
    let url: URL?
    var cornerRadius: CGFloat = 6
    var aspect: CGFloat = 1
    var symbol: String = "music.note"
    /// Approximate on-screen width in points; used to pick the decode size.
    var size: CGFloat = 200

    @State private var image: CGImage?
    @State private var loadedKey: String?

    private var maxPixel: Int {
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let px = Int(size * scale)
        // Bucket sizes so the same artwork is reused across views.
        for b in [96, 160, 256, 400, 600, 900, 1200] where px <= b { return b }
        return 1200
    }

    @State private var fade = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let shown = image ?? url.flatMap({ ImageLoader.shared.cached($0, maxPixel: maxPixel) })
        Color.clear
            .aspectRatio(aspect, contentMode: .fit)
            .background(shape.fill(.quaternary.opacity(0.6)))
            .overlay {
                if shown == nil {
                    Image(systemName: symbol)
                        .font(.system(size: max(10, size * 0.18), weight: .light))
                        .foregroundStyle(.tertiary)
                }
            }
            // The picture itself is one Core Animation layer (rounded, clipped and
            // bordered by the layer, faded in by Core Animation): no SwiftUI image
            // resampling, clip mask or animation transaction per card.
            .overlay { ArtworkLayer(image: shown, cornerRadius: cornerRadius, fade: fade) }
            .task(id: url.map { ImageLoader.key($0, maxPixel) }) {
                guard let url else { image = nil; return }
                let key = ImageLoader.key(url, maxPixel)
                if loadedKey == key, image != nil { return }
                if let hit = ImageLoader.shared.cached(url, maxPixel: maxPixel) { image = hit; loadedKey = key; return }
                // Ask the image server for exactly the resolution we display; fall back
                // to the original if a larger variant doesn't exist.
                let hq = Thumbs.sized(url, px: maxPixel)
                var img = await ImageLoader.shared.cgImage(for: hq, maxPixel: maxPixel)
                if img == nil, hq != url { img = await ImageLoader.shared.cgImage(for: url, maxPixel: maxPixel) }
                if let img { ImageLoader.sharedCache.setObject(CGImageBox(img), forKey: key as NSString, cost: img.bytesPerRow * img.height) }
                guard !Task.isCancelled else { return }
                fade = true
                image = img
                loadedKey = key
            }
    }
}

/// A single CALayer showing artwork: aspect-fill, rounded (continuous corners),
/// hairline border, high-quality filtering, and a Core Animation cross-fade when
/// a freshly downloaded image arrives.
private struct ArtworkLayer: NSViewRepresentable {
    let image: CGImage?
    let cornerRadius: CGFloat
    let fade: Bool

    func makeNSView(context: Context) -> LayerView { LayerView() }
    func updateNSView(_ v: LayerView, context: Context) { v.update(image: image, radius: cornerRadius, fade: fade) }

    final class LayerView: NSView {
        private var current: CGImage?
        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layerContentsRedrawPolicy = .never
            guard let l = layer else { return }
            l.contentsGravity = .resizeAspectFill
            l.masksToBounds = true
            l.cornerCurve = .continuous
            l.minificationFilter = .trilinear
            l.magnificationFilter = .linear
            l.borderWidth = 0.5
            l.borderColor = NSColor.white.withAlphaComponent(0.08).cgColor
        }
        required init?(coder: NSCoder) { fatalError() }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override var wantsUpdateLayer: Bool { true }

        func update(image: CGImage?, radius: CGFloat, fade: Bool) {
            guard let l = layer else { return }
            CATransaction.begin(); CATransaction.setDisableActions(true)
            if l.cornerRadius != radius { l.cornerRadius = radius }
            CATransaction.commit()
            guard image !== current else { return }
            let animate = fade && current == nil && image != nil && window != nil
            current = image
            if animate {
                let t = CATransition()
                t.type = .fade
                t.duration = 0.18
                t.timingFunction = CAMediaTimingFunction(name: .easeOut)
                l.add(t, forKey: "fadeIn")
            }
            CATransaction.begin(); CATransaction.setDisableActions(!animate)
            l.contents = image
            CATransaction.commit()
        }
    }
}
