import SwiftUI

// MARK: - Playing Next (queue inspector)

struct QueueView: View {
    @EnvironmentObject var player: PlayerController
    @State private var tab = 0

    var body: some View {
        VStack(spacing: 0) {
            PillPicker(selection: $tab, options: [(0, "Playing Next", "list.bullet"), (1, "History", "clock")])
                .padding(12)
            if tab == 0 { upNext } else { history }
        }
    }

    private var upNext: some View {
        // Section titles are ordinary rows on frosted glass (the list's own sticky
        // section headers draw an opaque black bar and covered the current song).
        List {
            if let cur = player.current {
                QueueHeader(title: "Now Playing") { EmptyView() }
                QueueRow(track: cur, isCurrent: true)
            }
            QueueHeader(title: "Playing Next") {
                HStack(spacing: 2) {
                    Button { player.toggleShuffle() } label: { Image(systemName: "shuffle") }
                        .foregroundStyle(player.shuffle ? Color.accentColor : .secondary).help("Shuffle")
                    Button { player.repeatMode = player.repeatMode.next } label: { Image(systemName: player.repeatMode.symbol) }
                        .foregroundStyle(player.repeatMode != .off ? Color.accentColor : .secondary).help("Repeat")
                    Button { player.autoplay.toggle() } label: { Image(systemName: "infinity") }
                        .foregroundStyle(player.autoplay ? Color.accentColor : .secondary)
                        .help("Autoplay: keep playing similar music when the queue ends")
                }
                .buttonStyle(BarIconStyle(size: 11, diameter: 24))
                Button("Clear") { player.clearUpNext() }
                    .buttonStyle(TextLinkStyle())
                    .disabled(player.upNext.isEmpty)
            }
            ForEach(Array(player.upNext)) { t in
                QueueRow(track: t, isCurrent: false)
                    .onTapGesture(count: 2) { player.jump(to: t) }
                    .contextMenu {
                        Button("Play Now") { player.jump(to: t) }
                        Button("Remove from Queue", role: .destructive) { player.remove(t) }
                    }
            }
            .onMove { player.moveUpNext(from: $0, to: $1) }
            .onDelete { idx in
                let items = Array(player.upNext)
                idx.map { items[$0] }.forEach(player.remove)
            }
            if player.upNext.isEmpty {
                Text(player.autoplay ? "Similar music will play next." : "Nothing queued.")
                    .foregroundStyle(.secondary).font(.callout)
                    .listRowBackground(Color.clear)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, 1)
    }

    private var history: some View {
        List(player.history) { t in
            QueueRow(track: t, isCurrent: false)
                .onTapGesture(count: 2) { player.play(tracks: [t]) }
                .contextMenu {
                    Button("Play") { player.play(tracks: [t]) }
                    Button("Play Next") { player.playNext([t]) }
                }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .overlay { if player.history.isEmpty { Text("Songs you play appear here.").foregroundStyle(.secondary) } }
    }
}

struct QueueRow: View {
    let track: Track
    let isCurrent: Bool
    @EnvironmentObject var player: PlayerController
    @State private var hover = false
    var body: some View {
        HStack(spacing: 10) {
            Artwork(url: track.thumbnail, cornerRadius: 4).frame(width: 36, height: 36)
                .overlay { if isCurrent { RoundedRectangle(cornerRadius: 4).fill(.black.opacity(0.4)); PlayingBars(animating: player.isPlaying).foregroundStyle(.white) } }
            VStack(alignment: .leading, spacing: 1) {
                Text(track.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Text(track.artistLine).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if let d = track.duration { Text(formatTime(d)).font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary).fixedSize() }
        }
        .padding(.horizontal, 6).padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hover ? Color.primary.opacity(0.08) : .clear))
        .onHover { hover = $0 }
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 1, leading: 8, bottom: 1, trailing: 8))
        .contentShape(Rectangle())
    }
}

// MARK: - Mini player window

/// Compact always-on-top player: artwork card over the song's colour glow,
/// title, progress, transport and like — nothing else.
struct MiniPlayerView: View {
    @EnvironmentObject var player: PlayerController
    @State private var hover = false

    var body: some View {
        ZStack {
            AmbientBackground(artwork: player.current?.largeArtwork, dim: 0.38, parallax: 0.4)
            VStack(spacing: 14) {
                Artwork(url: player.current?.largeArtwork, cornerRadius: 16, size: 248)
                    .frame(width: 248, height: 248)
                    .shadow(color: .black.opacity(0.45), radius: 22, y: 12)
                    .scaleEffect(player.isPlaying ? 1 : 0.94)
                    .animation(.spring(duration: 0.5, bounce: 0.25), value: player.isPlaying)
                    .padding(.top, 30)
                VStack(spacing: 3) {
                    Text(player.current?.title ?? "Not Playing").font(.system(size: 15, weight: .bold)).lineLimit(1)
                    Text(player.current?.artistLine ?? "").font(.system(size: 12.5)).foregroundStyle(.white.opacity(0.65)).lineLimit(1)
                }
                .padding(.horizontal, 20)
                ScrubberBar().padding(.horizontal, 16)
                HStack(spacing: 18) {
                    Button { player.toggleLike() } label: {
                        Image(systemName: player.likeStatus == .like ? "hand.thumbsup.fill" : "hand.thumbsup")
                    }
                    .buttonStyle(BarIconStyle(size: 13))
                    .hoverTip("Like")
                    TransportControls(size: .regular, showShuffleRepeat: false)
                    Button { NSApp.activate(ignoringOtherApps: true); NSApp.windows.first { $0.identifier?.rawValue.contains("main") == true }?.makeKeyAndOrderFront(nil) } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                    }
                    .buttonStyle(BarIconStyle(size: 12))
                    .hoverTip("Open full player")
                }
                .padding(.bottom, 18)
            }
            .foregroundStyle(.white)
        }
        .frame(width: 300, height: 470)
        .environment(\.colorScheme, .dark)
        .background(FloatingWindow())
    }
}

/// Keeps the mini player above other windows and draggable by its background.
struct FloatingWindow: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async {
            guard let w = v.window else { return }
            w.level = .floating
            w.isMovableByWindowBackground = true
            w.titlebarAppearsTransparent = true
            w.collectionBehavior.insert(.canJoinAllSpaces)
            w.backgroundColor = .black
        }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

// MARK: - Menu bar player

struct MenuBarPlayerView: View {
    @EnvironmentObject var player: PlayerController
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 12) {
                Artwork(url: player.current?.largeArtwork, cornerRadius: 10, size: 64).frame(width: 64, height: 64)
                    .shadow(color: .black.opacity(0.3), radius: 6, y: 3)
                VStack(alignment: .leading, spacing: 3) {
                    Text(player.current?.title ?? "Not Playing").font(.system(size: 13.5, weight: .semibold)).lineLimit(2)
                    Text(player.current?.artistLine ?? "").font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                Button { player.toggleLike() } label: {
                    Image(systemName: player.likeStatus == .like ? "hand.thumbsup.fill" : "hand.thumbsup")
                }
                .buttonStyle(BarIconStyle(size: 13))
            }
            ScrubberBar()                                    // one time display, same bar as the main window
            TransportControls(size: .regular, spread: true)
            VolumeControl()
            Divider()
            HStack {
                Button { NSApp.activate(ignoringOtherApps: true); openWindow(id: "main") } label: {
                    Label("Open \(AppInfo.name)", systemImage: "macwindow")
                }
                Spacer()
                Button { NSApp.terminate(nil) } label: { Label("Quit", systemImage: "power") }
            }
            .buttonStyle(TextLinkStyle())
        }
        .padding(16)
        .frame(width: 320)
    }
}

/// A queue section title on a frosted-glass bar, with optional trailing controls.
struct QueueHeader<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            trailing()
        }
        .padding(.horizontal, 12)
        .frame(height: 32)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.white.opacity(0.08), lineWidth: 0.5))
        .padding(.top, 6).padding(.bottom, 2)
        .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8))
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        .moveDisabled(true)
        .deleteDisabled(true)
    }
}
