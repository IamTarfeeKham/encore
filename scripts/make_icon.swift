// Static app icon (Finder / first launch): the Note in its dark look. The Dock icon then
// follows the user's choice and macOS's appearance at runtime (App/AppIcon.swift).
// build.sh compiles this together with Sources/Encore/App/IconArt.swift.
import AppKit
let cg = IconArt.cgImage(symbol: .note, look: .dark, size: 1024)!
try! NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])!
    .write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
