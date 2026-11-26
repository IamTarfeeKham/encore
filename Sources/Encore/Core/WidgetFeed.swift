import AppKit
import Combine
import CoreImage
import WidgetKit

/// Feeds the desktop widgets: writes what's playing, the cover and a softened
/// backdrop to a small shared folder, then asks WidgetKit to refresh (only when
/// something visible changes: the song, play/pause, a seek, Up Next). Also acts on
/// the widgets' play/pause/next/previous buttons.
@MainActor
final class WidgetFeed {
    static let shared = WidgetFeed()

    private struct Track: Codable { var title: String; var artist: String }
    private struct Snapshot: Codable {
        var title: String
        var artist: String
        var album: String?
        var isPlaying: Bool
        var position: Double
        var duration: Double
        var updated: Date
        var upNext: [Track]
    }

    private var bag = Set<AnyCancellable>()
    private var lastKey = ""
    private var lastArt: URL?
    private var lastPosition = 0.0, lastWrite = Date.distantPast

    static var folder: URL {
        let home = getpwuid(getuid()).flatMap { String(validatingCString: $0.pointee.pw_dir) } ?? NSHomeDirectory()
        return URL(fileURLWithPath: home).appendingPathComponent("Library/Application Support/Encore Widget")
    }

    func start() {
        try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        let player = PlayerController.shared
        player.objectWillChange
            .debounce(for: .milliseconds(400), scheduler: RunLoop.main)
            .sink { [weak self] in self?.update() }
            .store(in: &bag)
        let dnc = DistributedNotificationCenter.default()
        for (name, action) in [("playPause", { player.togglePlayPause() }), ("next", { player.next() }),
                               ("previous", { player.previous() })] as [(String, () -> Void)] {
            dnc.addObserver(forName: .init("local.ytmusicmac.widget.\(name)"), object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { action() }
            }
        }
        update()
    }

    private func update() {
        let player = PlayerController.shared
        guard let t = player.current else { return }
        let time = player.clock.time, duration = player.clock.duration
        let upNext = player.upNext.prefix(4).map { Track(title: $0.title, artist: $0.artistLine) }
        // Refresh only on visible changes; a steady play doesn't need any (the
        // widget's progress bar runs by itself), but a seek does.
        let key = "\(t.videoId)|\(player.isPlaying)|\(upNext.map(\.title).joined(separator: "/"))"
        let expected = lastPosition + (player.isPlaying ? Date().timeIntervalSince(lastWrite) : 0)
        let seeked = abs(time - expected) > 4
        guard key != lastKey || seeked else { return }
        lastKey = key; lastPosition = time; lastWrite = Date()

        let snap = Snapshot(title: t.title, artist: t.artistLine, album: t.album?.name, isPlaying: player.isPlaying,
                            position: time, duration: duration > 0 ? duration : Double(t.duration ?? 0),
                            updated: Date(), upNext: Array(upNext))
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .secondsSince1970
        if let d = try? enc.encode(snap) { try? d.write(to: Self.folder.appendingPathComponent("now.json"), options: .atomic) }

        let art = t.largeArtwork
        if art != lastArt, let art {
            lastArt = art
            Task {
                guard let img = await ImageLoader.shared.cgImage(for: art, maxPixel: 600) else { return }
                Self.writeJPEG(img, "cover.jpg")
                if let soft = Self.backdrop(img) { Self.writeJPEG(soft, "backdrop.jpg") }
                WidgetCenter.shared.reloadAllTimelines()
            }
        } else {
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    private static func writeJPEG(_ img: CGImage, _ name: String) {
        let rep = NSBitmapImageRep(cgImage: img)
        if let d = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) {
            try? d.write(to: folder.appendingPathComponent(name), options: .atomic)
        }
    }

    /// The cover, heavily blurred and a little darker: the widgets' background.
    private static func backdrop(_ img: CGImage) -> CGImage? {
        let ci = CIImage(cgImage: img).clampedToExtent()
            .applyingGaussianBlur(sigma: 40)
            .applyingFilter("CIColorControls", parameters: [kCIInputBrightnessKey: -0.12, kCIInputSaturationKey: 1.3])
            .cropped(to: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        return CIContext().createCGImage(ci, from: ci.extent)
    }
}
