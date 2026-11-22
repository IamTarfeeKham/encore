import AppKit

/// Draws the app icon (red music note on a light or dark tile) and keeps the
/// Dock icon in step with the system's light/dark appearance.
@MainActor
enum AppIcon {
    private static var observer: NSKeyValueObservation?

    static func start() {
        update()
        observer = NSApp.observe(\.effectiveAppearance, options: [.new]) { _, _ in
            DispatchQueue.main.async { update() }
        }
    }

    static func update() {
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        NSApp.applicationIconImage = render(dark: dark, size: 512)
    }

    static func render(dark: Bool, size: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { r in
            let inset = size * 0.098
            let tile = r.insetBy(dx: inset, dy: inset)
            let path = NSBezierPath(roundedRect: tile, xRadius: tile.width * 0.225, yRadius: tile.width * 0.225)
            NSGraphicsContext.current?.saveGraphicsState()
            let sh = NSShadow(); sh.shadowBlurRadius = size * 0.028; sh.shadowOffset = NSSize(width: 0, height: -size * 0.01)
            sh.shadowColor = NSColor.black.withAlphaComponent(0.3); sh.set()
            let colors = dark ? [NSColor(white: 0.21, alpha: 1), NSColor(white: 0.06, alpha: 1)]
                              : [NSColor.white, NSColor(white: 0.9, alpha: 1)]
            NSGradient(colors: colors)!.draw(in: path, angle: -90)
            NSGraphicsContext.current?.restoreGraphicsState()
            let cfg = NSImage.SymbolConfiguration(pointSize: tile.width * 0.52, weight: .bold)
                .applying(.init(paletteColors: [NSColor(red: 1, green: 0, blue: 0, alpha: 1)]))
            if let note = NSImage(systemSymbolName: "music.note", accessibilityDescription: nil)?.withSymbolConfiguration(cfg) {
                let s = note.size
                note.draw(in: NSRect(x: r.midX - s.width / 2 - size * 0.01, y: r.midY - s.height / 2, width: s.width, height: s.height))
            }
            return true
        }
    }

    /// Writes the static (Finder) icon PNG — used by build.sh.
    static func writePNG(to path: String, dark: Bool) {
        let img = render(dark: dark, size: 1024)
        guard let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: URL(fileURLWithPath: path))
    }
}
