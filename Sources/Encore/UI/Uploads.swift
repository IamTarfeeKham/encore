import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Library › Uploads: music you uploaded to YouTube Music (songs, albums, artists),
/// and uploading more — with the button or by dropping audio files on the page.
struct UploadsView: View {
    @State private var tab: InnerTube.UploadsTab = .songs
    @State private var items: [MediaItem]?
    @State private var error: String?
    @State private var reload = 0
    @State private var uploading: (name: String, index: Int, count: Int)?
    @State private var dropTargeted = false
    private var player: PlayerController { .shared }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text("Uploads").font(.system(size: 30, weight: .bold))
                    Spacer(minLength: 0)
                    Button { chooseFiles() } label: { Label("Upload Music…", systemImage: "icloud.and.arrow.up") }
                        .glassButton()
                        .disabled(uploading != nil)
                }
                PillPicker(selection: $tab, options: InnerTube.UploadsTab.allCases.map { ($0, $0.rawValue, $0.symbol) })
                if let u = uploading {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text(u.count > 1 ? "Uploading “\(u.name)” (\(u.index) of \(u.count))…" : "Uploading “\(u.name)”…")
                            .font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .pagePadding()
        }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                    .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.accentColor.opacity(0.08)))
                    .overlay(Label("Drop to upload to YouTube Music", systemImage: "icloud.and.arrow.up")
                        .font(.system(size: 15, weight: .semibold)))
                    .padding(24)
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            Task { await upload(await Self.fileURLs(from: providers)) }
            return true
        }
        .task(id: "\(tab.rawValue)#\(reload)") { await load() }
    }

    @ViewBuilder private var content: some View {
        if let items {
            if items.isEmpty {
                ContentUnavailableView {
                    Label(tab == .songs ? "No Uploads Yet" : "No Uploaded \(tab.rawValue)", systemImage: "icloud.and.arrow.up")
                } description: {
                    Text("Songs you upload to YouTube Music appear here. Drop audio files on this page, or choose Upload Music… (MP3, M4A, FLAC, OGG or WMA).")
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 40)
            } else {
                switch tab {
                case .songs:
                    HStack {
                        Button { player.play(tracks: items.compactMap(\.track)) } label: { Label("Play", systemImage: "play.fill") }
                            .glassButton(prominent: true)
                        Button { player.play(tracks: items.compactMap(\.track), shuffle: true) } label: { Label("Shuffle", systemImage: "shuffle") }
                            .glassButton()
                        Text("\(items.count) song\(items.count == 1 ? "" : "s")").font(.system(size: 13)).foregroundStyle(.secondary)
                            .padding(.leading, 6)
                    }
                    LazyVStack(spacing: 0) {
                        ForEach(items) { item in
                            TrackRow(item: item, showAlbum: true) {
                                let list = items.compactMap(\.track)
                                player.play(tracks: list, startAt: list.firstIndex { $0.videoId == item.videoId } ?? 0)
                            }
                        }
                    }
                case .albums:
                    CardGrid(items: items)
                case .artists:
                    LazyVStack(spacing: 0) { ForEach(items) { CollectionRow(item: $0) } }
                }
            }
        } else if let error {
            ErrorView(message: error) { self.error = nil; reload += 1 }
        } else {
            LoadingView(inset: false)
        }
    }

    private func load() async {
        do {
            let list = try await InnerTube.shared.uploads(tab)
            items = list; error = nil
        } catch is CancellationError {
        } catch {
            if items == nil { self.error = error.localizedDescription }
        }
    }

    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.title = "Upload to YouTube Music"
        panel.prompt = "Upload"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = InnerTube.uploadExtensions.compactMap { UTType(filenameExtension: $0) }
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        Task { await upload(urls) }
    }

    private func upload(_ files: [URL]) async {
        let audio = files.filter { InnerTube.uploadExtensions.contains($0.pathExtension.lowercased()) }
        guard !audio.isEmpty else {
            if !files.isEmpty { AppModel.shared.flash("YouTube Music only accepts MP3, M4A, FLAC, OGG and WMA files") }
            return
        }
        var done = 0, failed: String?
        for (i, file) in audio.enumerated() {
            uploading = (file.deletingPathExtension().lastPathComponent, i + 1, audio.count)
            let scoped = file.startAccessingSecurityScopedResource()
            defer { if scoped { file.stopAccessingSecurityScopedResource() } }
            do { try await InnerTube.shared.upload(file); done += 1 }
            catch { failed = error.localizedDescription }
        }
        uploading = nil
        if done > 0 {
            AppModel.shared.flash(done == 1 ? "Uploaded. It appears here once YouTube Music has processed it"
                                            : "Uploaded \(done) songs. They appear here once YouTube Music has processed them")
            // Processing takes a little while; look again shortly.
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            reload += 1
        } else if let failed {
            AppModel.shared.flash(failed)
        }
    }

    private static func fileURLs(from providers: [NSItemProvider]) async -> [URL] {
        var urls: [URL] = []
        for p in providers where p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            let url: URL? = await withCheckedContinuation { cont in
                _ = p.loadObject(ofClass: URL.self) { u, _ in cont.resume(returning: u) }
            }
            if let url { urls.append(url) }
        }
        return urls
    }
}
