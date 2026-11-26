import AppIntents
import SwiftUI
import WidgetKit

// Desktop widgets for Encore. The app writes what's playing (and the cover) to a
// small shared folder and asks WidgetKit to refresh; the buttons send a notice the
// app acts on.

// MARK: - Shared data (mirrors WidgetFeed in the app)

struct WidgetTrack: Codable, Hashable {
    var title: String
    var artist: String
}

struct WidgetSnapshot: Codable {
    var title: String
    var artist: String
    var album: String?
    var isPlaying: Bool
    var position: Double
    var duration: Double
    var updated: Date
    var upNext: [WidgetTrack]
}

enum WidgetStore {
    static var folder: URL {
        let home = getpwuid(getuid()).flatMap { String(validatingCString: $0.pointee.pw_dir) } ?? NSHomeDirectory()
        return URL(fileURLWithPath: home).appendingPathComponent("Library/Application Support/Encore Widget")
    }
    static func snapshot() -> WidgetSnapshot? {
        guard let d = try? Data(contentsOf: folder.appendingPathComponent("now.json")) else { return nil }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .secondsSince1970
        return try? dec.decode(WidgetSnapshot.self, from: d)
    }
    static func image(_ name: String) -> NSImage? { NSImage(contentsOf: folder.appendingPathComponent(name)) }
}

// MARK: - Buttons

private func tell(_ action: String) {
    DistributedNotificationCenter.default().postNotificationName(
        .init("local.ytmusicmac.widget.\(action)"), object: nil, userInfo: nil, deliverImmediately: true)
}

struct PlayPauseIntent: AppIntent {
    static let title: LocalizedStringResource = "Play or Pause"
    func perform() async throws -> some IntentResult { tell("playPause"); return .result() }
}
struct NextTrackIntent: AppIntent {
    static let title: LocalizedStringResource = "Next Song"
    func perform() async throws -> some IntentResult { tell("next"); return .result() }
}
struct PreviousTrackIntent: AppIntent {
    static let title: LocalizedStringResource = "Previous Song"
    func perform() async throws -> some IntentResult { tell("previous"); return .result() }
}

// MARK: - Timeline

struct NowEntry: TimelineEntry {
    let date: Date
    let snap: WidgetSnapshot?
    let cover: NSImage?
    let backdrop: NSImage?

    static let placeholder = NowEntry(
        date: .now,
        snap: WidgetSnapshot(title: "Song Title", artist: "Artist", album: nil, isPlaying: true, position: 40,
                             duration: 200, updated: .now, upNext: [.init(title: "Next Song", artist: "Artist")]),
        cover: nil, backdrop: nil)
}

struct NowProvider: TimelineProvider {
    func placeholder(in context: Context) -> NowEntry { .placeholder }
    func getSnapshot(in context: Context, completion: @escaping (NowEntry) -> Void) {
        completion(load() ?? .placeholder)
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<NowEntry>) -> Void) {
        let entry = load() ?? NowEntry(date: .now, snap: nil, cover: nil, backdrop: nil)
        // The app refreshes us on every change; as a fallback, look again when the song should end.
        var next = Date().addingTimeInterval(30 * 60)
        if let s = entry.snap, s.isPlaying, s.duration > 0 {
            next = s.updated.addingTimeInterval(max(15, s.duration - s.position + 2))
        }
        completion(Timeline(entries: [entry], policy: .after(next)))
    }
    private func load() -> NowEntry? {
        guard let s = WidgetStore.snapshot() else { return nil }
        return NowEntry(date: .now, snap: s, cover: WidgetStore.image("cover.jpg"), backdrop: WidgetStore.image("backdrop.jpg"))
    }
}

// MARK: - Views

private struct CoverImage: View {
    let image: NSImage?
    var radius: CGFloat = 10
    var body: some View {
        Group {
            if let image { Image(nsImage: image).resizable().aspectRatio(contentMode: .fill) }
            else { ZStack { Color.white.opacity(0.12); Image(systemName: "music.note").font(.title2).foregroundStyle(.white.opacity(0.6)) } }
        }
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

private struct Backdrop: View {
    let entry: NowEntry
    var body: some View {
        ZStack {
            if let b = entry.backdrop { Image(nsImage: b).resizable().aspectRatio(contentMode: .fill) }
            else { LinearGradient(colors: [Color(red: 0.35, green: 0.12, blue: 0.4), Color(red: 0.1, green: 0.1, blue: 0.3)],
                                  startPoint: .topLeading, endPoint: .bottomTrailing) }
            LinearGradient(colors: [.black.opacity(0.05), .black.opacity(0.45)], startPoint: .top, endPoint: .bottom)
        }
    }
}

private struct Progress: View {
    let snap: WidgetSnapshot
    var body: some View {
        Group {
            if snap.isPlaying, snap.duration > 0 {
                let start = snap.updated.addingTimeInterval(-snap.position)
                ProgressView(timerInterval: start...start.addingTimeInterval(snap.duration), countsDown: false) {
                    EmptyView()
                } currentValueLabel: { EmptyView() }
            } else {
                ProgressView(value: snap.duration > 0 ? min(snap.position / snap.duration, 1) : 0)
            }
        }
        .progressViewStyle(.linear)
        .tint(.white)
        .labelsHidden()
    }
}

private struct Controls: View {
    let playing: Bool
    var size: CGFloat = 15
    var body: some View {
        HStack(spacing: size * 1.4) {
            Button(intent: PreviousTrackIntent()) { Image(systemName: "backward.fill") }
            Button(intent: PlayPauseIntent()) {
                Image(systemName: playing ? "pause.fill" : "play.fill").font(.system(size: size * 1.35, weight: .bold))
            }
            Button(intent: NextTrackIntent()) { Image(systemName: "forward.fill") }
        }
        .buttonStyle(.plain)
        .font(.system(size: size, weight: .semibold))
        .foregroundStyle(.white)
    }
}

struct NowPlayingView: View {
    @Environment(\.widgetFamily) private var family
    let entry: NowEntry

    var body: some View {
        if let s = entry.snap {
            switch family {
            case .systemSmall: small(s)
            case .systemLarge: large(s)
            default: medium(s)
            }
        } else {
            VStack(spacing: 6) {
                Image(systemName: "music.note").font(.title)
                Text("Nothing playing").font(.headline)
                Text("Play something in Encore").font(.caption).opacity(0.7)
            }
            .foregroundStyle(.white)
        }
    }

    private func titles(_ s: WidgetSnapshot, big: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(s.title).font(.system(size: big ? 17 : 14, weight: .bold)).lineLimit(1)
            Text(s.artist).font(.system(size: big ? 13.5 : 12, weight: .medium)).opacity(0.75).lineLimit(1)
        }
        .foregroundStyle(.white)
    }

    private func small(_ s: WidgetSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                CoverImage(image: entry.cover, radius: 10)
                    .frame(width: 64, height: 64)
                    .shadow(color: .black.opacity(0.35), radius: 6, y: 3)
                Spacer(minLength: 0)
                Button(intent: PlayPauseIntent()) {
                    Image(systemName: s.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 30)).symbolRenderingMode(.hierarchical)
                }
                .buttonStyle(.plain).foregroundStyle(.white)
            }
            Spacer(minLength: 0)
            titles(s)
            Progress(snap: s)
        }
    }

    private func medium(_ s: WidgetSnapshot) -> some View {
        HStack(spacing: 14) {
            CoverImage(image: entry.cover, radius: 12)
                .aspectRatio(1, contentMode: .fit)
                .shadow(color: .black.opacity(0.35), radius: 8, y: 4)
            VStack(alignment: .leading, spacing: 8) {
                titles(s, big: true)
                Spacer(minLength: 0)
                Progress(snap: s)
                Controls(playing: s.isPlaying)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private func large(_ s: WidgetSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                CoverImage(image: entry.cover, radius: 14)
                    .frame(width: 128, height: 128)
                    .shadow(color: .black.opacity(0.35), radius: 10, y: 5)
                VStack(alignment: .leading, spacing: 10) {
                    titles(s, big: true)
                    if let a = s.album { Text(a).font(.caption).foregroundStyle(.white.opacity(0.55)).lineLimit(1) }
                    Spacer(minLength: 0)
                    Progress(snap: s)
                    Controls(playing: s.isPlaying, size: 17).frame(maxWidth: .infinity)
                }
            }
            if !s.upNext.isEmpty {
                Text("UP NEXT").font(.system(size: 10.5, weight: .bold)).tracking(0.6).foregroundStyle(.white.opacity(0.55))
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(Array(s.upNext.prefix(4).enumerated()), id: \.offset) { _, t in
                        HStack(spacing: 8) {
                            Image(systemName: "music.note").font(.system(size: 10)).opacity(0.5)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(t.title).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                                Text(t.artist).font(.system(size: 11)).opacity(0.6).lineLimit(1)
                            }
                        }
                    }
                }
                .foregroundStyle(.white)
            }
            Spacer(minLength: 0)
        }
    }
}

struct CoverOnlyView: View {
    let entry: NowEntry
    var body: some View {
        ZStack(alignment: .bottomLeading) {
            if let c = entry.cover { Image(nsImage: c).resizable().aspectRatio(contentMode: .fill) }
            else { Backdrop(entry: entry) }
            if let s = entry.snap {
                LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .center, endPoint: .bottom)
                VStack(alignment: .leading, spacing: 1) {
                    Text(s.title).font(.system(size: 13, weight: .bold)).lineLimit(1)
                    Text(s.artist).font(.system(size: 11, weight: .medium)).opacity(0.8).lineLimit(1)
                }
                .foregroundStyle(.white)
                .padding(12)
            }
        }
    }
}

// MARK: - Widgets

struct NowPlayingWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "NowPlaying", provider: NowProvider()) { entry in
            NowPlayingView(entry: entry)
                .containerBackground(for: .widget) { Backdrop(entry: entry) }
        }
        .configurationDisplayName("Now Playing")
        .description("What's playing in Encore, with its cover colours and controls.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct CoverWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "Cover", provider: NowProvider()) { entry in
            CoverOnlyView(entry: entry)
                .containerBackground(for: .widget) { Color.black }
        }
        .configurationDisplayName("Cover")
        .description("The current song's artwork, edge to edge.")
        .supportedFamilies([.systemSmall, .systemLarge])
        .contentMarginsDisabled()
    }
}

@main
struct EncoreWidgets: WidgetBundle {
    var body: some Widget {
        NowPlayingWidget()
        CoverWidget()
    }
}
