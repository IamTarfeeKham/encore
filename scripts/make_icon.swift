// Static app icon (Finder / first launch): red music note on a dark tile. The Dock icon
// then follows light/dark mode at runtime (App/AppIcon.swift).
import AppKit
let size: CGFloat = 1024
let img = NSImage(size: NSSize(width: size, height: size), flipped: false) { r in
    let inset = size * 0.098
    let tile = r.insetBy(dx: inset, dy: inset)
    let path = NSBezierPath(roundedRect: tile, xRadius: tile.width * 0.225, yRadius: tile.width * 0.225)
    NSGraphicsContext.current?.saveGraphicsState()
    let sh = NSShadow(); sh.shadowBlurRadius = 28; sh.shadowOffset = NSSize(width: 0, height: -10)
    sh.shadowColor = NSColor.black.withAlphaComponent(0.3); sh.set()
    NSGradient(colors: [NSColor(white: 0.21, alpha: 1), NSColor(white: 0.06, alpha: 1)])!.draw(in: path, angle: -90)
    NSGraphicsContext.current?.restoreGraphicsState()
    let cfg = NSImage.SymbolConfiguration(pointSize: tile.width * 0.52, weight: .bold)
        .applying(.init(paletteColors: [NSColor(red: 1, green: 0, blue: 0, alpha: 1)]))
    if let note = NSImage(systemSymbolName: "music.note", accessibilityDescription: nil)?.withSymbolConfiguration(cfg) {
        let s = note.size
        note.draw(in: NSRect(x: r.midX - s.width / 2 - 10, y: r.midY - s.height / 2, width: s.width, height: s.height))
    }
    return true
}
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
