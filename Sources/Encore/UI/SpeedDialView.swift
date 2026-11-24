import SwiftUI

/// "Speed Dial": your go-to songs, albums, playlists and artists at the top of
/// Home. One click plays. Pin anything via right-click → Add to Speed Dial;
/// your last 3 played songs follow your pins (optional).
struct SpeedDialView: View {
    @StateObject private var store = SpeedDialStore.shared
    @StateObject private var stats = PlayStats.shared
    @State private var editing = false

    var body: some View {
        let tiles = store.tiles(stats: stats)
        if store.visible {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Speed Dial").font(.system(size: 22, weight: .bold))
                    Spacer()
                    Button("Edit") { editing = true }.buttonStyle(.borderless).foregroundStyle(.secondary)
                }
                if tiles.isEmpty {
                    HStack(spacing: 14) {
                        Image(systemName: "square.grid.3x3.topleft.filled").font(.system(size: 26)).foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Put your classics one click away").font(.system(size: 14, weight: .semibold))
                            Text("Right-click any song, album, playlist or artist and choose “Add to Speed Dial”. Your last 3 played songs also appear here.")
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .cardSurface(16)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 136, maximum: 136), spacing: 14, alignment: .top)],
                              alignment: .leading, spacing: 16) {
                        ForEach(tiles) { item in
                            SpeedDialTile(item: item, pinned: store.contains(item))
                        }
                    }
                }
            }
            .sheet(isPresented: $editing) { EditSpeedDialView().appAccent() }
        }
    }
}

struct SpeedDialTile: View {
    let item: MediaItem
    let pinned: Bool
    @ObservedObject private var now = PlayerController.shared.now
    @State private var hover = false

    var body: some View {
        let playing = item.videoId != nil && now.videoId == item.videoId
        VStack(alignment: .leading, spacing: 6) {
            Artwork(url: item.thumbnail, cornerRadius: item.kind == .artist ? 999 : 14, aspect: 1,
                    symbol: item.kind == .artist ? "person.fill" : "music.note", size: 140)
                .overlay(alignment: .bottomTrailing) {
                    if hover || playing {
                        Group {
                            if playing { PlayingBars(animating: now.isPlaying).foregroundStyle(.white) }
                            else { Image(systemName: "play.fill").font(.system(size: 12, weight: .bold)).foregroundStyle(.white) }
                        }
                        .frame(width: 30, height: 30)
                        .background(.black.opacity(0.45), in: Circle())
                        .padding(7)
                        .transition(.scale(scale: 0.7).combined(with: .opacity))
                    }
                }
                .overlay(alignment: .topLeading) {
                    if pinned {
                        Image(systemName: "pin.fill").font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                            .padding(5).background(.black.opacity(0.35), in: Circle()).padding(6)
                    }
                }
                .scaleEffect(hover ? 1.04 : 1)
                .shadow(color: .black.opacity(hover ? 0.3 : 0), radius: 12, y: 6)
            Text(item.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
            Text(item.kind == .song || item.kind == .video ? item.artistLine : item.kind.rawValue.capitalized)
                .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
        }
        .contentShape(Rectangle())
        .onHover { h in withAnimation(.spring(duration: 0.28, bounce: 0.25)) { hover = h } }
        .onTapGesture { PlayerController.shared.play(item) }
        .contextMenu {
            Button("Play") { PlayerController.shared.play(item) }
            if item.kind != .song && item.kind != .video {
                Button("Open") { AppModel.shared.open(item) }
                Button("Shuffle") { PlayerController.shared.play(item, shuffle: true) }
            }
            Divider()
            if pinned {
                Button("Remove from Speed Dial") { SpeedDialStore.shared.remove(item) }
            } else {
                Button("Pin to Speed Dial") { SpeedDialStore.shared.toggle(item) }
            }
        }
    }
}

struct EditSpeedDialView: View {
    @StateObject private var store = SpeedDialStore.shared
    @Environment(\.dismiss) var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Edit Speed Dial").font(.title2.bold())
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(20)
            Form {
                Toggle("Show Speed Dial on Home", isOn: $store.visible)
                Toggle("Also show my last 3 played songs", isOn: $store.autoFill)
                Section("Pinned — drag to reorder") {
                    if store.pinned.isEmpty {
                        Text("Right-click anything and choose “Add to Speed Dial”.").foregroundStyle(.secondary)
                    }
                    List {
                        ForEach(store.pinned) { item in
                            HStack(spacing: 10) {
                                Artwork(url: item.thumbnail, cornerRadius: item.kind == .artist ? 14 : 5, size: 28).frame(width: 28, height: 28)
                                VStack(alignment: .leading) {
                                    Text(item.title).lineLimit(1)
                                    Text(item.kind.rawValue.capitalized).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button { store.remove(item) } label: { Image(systemName: "minus.circle.fill").foregroundStyle(.red) }
                                    .buttonStyle(.plain)
                            }
                        }
                        .onMove { store.move(from: $0, to: $1) }
                    }
                    .frame(minHeight: 260)
                }
                Section {
                    Button("Clear Listening Stats", role: .destructive) { PlayStats.shared.clear() }
                } footer: {
                    Text("Play counts are kept only on this Mac.").font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
        }
        .frame(width: 460, height: 600)
    }
}
