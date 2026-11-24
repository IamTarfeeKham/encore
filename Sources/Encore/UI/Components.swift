import SwiftUI

// MARK: - Context menu shared by every item

struct ItemMenu: View {
    let item: MediaItem
    var playlistContext: (playlistId: String, editable: Bool)? = nil
    var onRemoved: (() -> Void)? = nil
    private var player: PlayerController { .shared }
    private var model: AppModel { .shared }

    var body: some View {
        Button { player.play(item) } label: { Label("Play", systemImage: "play") }
        if item.kind.isCollection || item.kind == .artist {
            Button { player.play(item, shuffle: true) } label: { Label("Shuffle", systemImage: "shuffle") }
        }
        Button { player.playNext(item) } label: { Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") }
            .disabled(item.kind == .artist)
        Button { player.addToQueue(item) } label: { Label("Add to Queue", systemImage: "text.line.last.and.arrowtriangle.forward") }
            .disabled(item.kind == .artist)
        Button { player.startRadio(item) } label: { Label("Start Radio", systemImage: "dot.radiowaves.left.and.right") }
        Divider()
        if let vid = item.videoId {
            if LikeStore.shared.liked.contains(vid) {
                Button { player.setLike(.indifferent, for: vid); model.flash("Removed from Liked Music") } label: { Label("Remove Like", systemImage: "hand.thumbsup.fill") }
            } else {
                Button { player.setLike(.like, for: vid); model.flash("Added to Liked Music") } label: { Label("Like", systemImage: "hand.thumbsup") }
            }
            Menu {
                Button("New Playlist…") { model.newPlaylistFor = [vid] }
                Divider()
                ForEach(model.playlists) { pl in Button(pl.title) { model.addToPlaylist(pl, videoIds: [vid]) } }
            } label: { Label("Add to Playlist", systemImage: "text.badge.plus") }
            if let ctx = playlistContext, ctx.editable, let set = item.setVideoId {
                Button(role: .destructive) {
                    Task {
                        try? await InnerTube.shared.removeFromPlaylist(playlistId: ctx.playlistId, videoId: vid, setVideoId: set)
                        onRemoved?()
                    }
                } label: { Label("Remove from Playlist", systemImage: "minus.circle") }
            }
        }
        if let album = item.album, album.browseId != nil {
            Button { model.openAlbum(album) } label: { Label("Go to Album", systemImage: "square.stack") }
        }
        if let artist = item.artists.first(where: { $0.browseId != nil }) {
            Button { model.openArtist(artist) } label: { Label("Go to Artist", systemImage: "music.mic") }
        }
        if item.kind.isCollection || item.kind == .artist {
            Button { model.open(item) } label: { Label("Open", systemImage: "arrow.up.forward.square") }
        }
        Divider()
        let dial = SpeedDialStore.shared
        Button { dial.toggle(item); model.flash(dial.contains(item) ? "Added to Speed Dial" : "Removed from Speed Dial") } label: {
            Label(dial.contains(item) ? "Remove from Speed Dial" : "Add to Speed Dial", systemImage: "square.grid.3x3.topleft.filled")
        }
        if item.kind != .song && item.kind != .video && item.kind != .episode {
            let sb = SidebarStore.shared
            if sb.isPinned(item) {
                Button { sb.unpin(item.id) } label: { Label("Unpin from Sidebar", systemImage: "pin.slash") }
            } else {
                Button { sb.pin(item); model.flash("Pinned to Sidebar") } label: { Label("Pin to Sidebar", systemImage: "pin") }
            }
        }
        Divider()
        Button { model.copyLink(item.shareURL) } label: { Label("Copy Link", systemImage: "link") }
        if let url = item.shareURL {
            ShareLink(item: url) { Label("Share…", systemImage: "square.and.arrow.up") }
        }
    }
}

// MARK: - Card (album / playlist / artist / video tile)

struct CardView: View {
    let item: MediaItem
    var width: CGFloat = 180
    @State private var hover = false
    private var player: PlayerController { .shared }
    private var model: AppModel { .shared }

    private var isRound: Bool { item.kind == .artist }
    private var aspect: CGFloat { item.kind == .video ? 16 / 9 : 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .bottomTrailing) {
                Artwork(url: item.thumbnail, cornerRadius: isRound ? width / 2 : 12, aspect: aspect,
                        symbol: isRound ? "person.fill" : "music.note", size: width)
                    .frame(width: width)
                if hover && item.kind != .artist {
                    Button { player.play(item) } label: {
                        Image(systemName: "play.fill")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 36, height: 36)
                            .background(.black.opacity(0.5), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .padding(8)
                    .transition(.opacity.combined(with: .scale(scale: 0.8)))
                }
            }
            .scaleEffect(hover ? 1.025 : 1)
            VStack(alignment: isRound ? .center : .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(item.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    if item.isExplicit { ExplicitBadge() }
                }
                if !item.subtitle.isEmpty {
                    Text(item.subtitle).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            .frame(width: width, alignment: isRound ? .center : .leading)
        }
        .contentShape(Rectangle())
        .onHover { h in
            // Ignore hover changes caused by content scrolling under a still pointer.
            if h && ScrollActivity.isScrolling { return }
            withAnimation(.spring(duration: 0.25, bounce: 0.2)) { hover = h }
        }
        .onTapGesture { model.open(item) }
        .contextMenu { ItemMenu(item: item) }
    }
}

struct ExplicitBadge: View {
    var body: some View {
        Text("E")
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(.background)
            .frame(width: 11, height: 11)
            .background(.secondary, in: RoundedRectangle(cornerRadius: 2))
    }
}

// MARK: - Animated "now playing" bars

/// "Now playing" bars, animated by Core Animation (no per-frame app work).
struct PlayingBars: NSViewRepresentable {
    var animating: Bool

    final class BarsView: NSView {
        let bars = (0..<3).map { _ in CALayer() }
        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            bars.forEach { $0.anchorPoint = CGPoint(x: 0.5, y: 0); $0.cornerRadius = 1; layer?.addSublayer($0) }
        }
        required init?(coder: NSCoder) { fatalError() }
        override var intrinsicContentSize: NSSize { NSSize(width: 12, height: 12) }
        override var isFlipped: Bool { false }
        func update(color: CGColor, animating: Bool) {
            CATransaction.begin(); CATransaction.setDisableActions(true)
            for (i, b) in bars.enumerated() {
                b.backgroundColor = color
                b.bounds = CGRect(x: 0, y: 0, width: 2.5, height: 4)
                b.position = CGPoint(x: 1.25 + CGFloat(i) * 4, y: 0)
                if animating {
                    if b.animation(forKey: "h") == nil {
                        let a = CABasicAnimation(keyPath: "bounds.size.height")
                        a.fromValue = 3; a.toValue = 12
                        a.duration = 0.32 + Double(i) * 0.11
                        a.autoreverses = true; a.repeatCount = .infinity
                        a.timeOffset = Double(i) * 0.13
                        a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                        b.add(a, forKey: "h")
                    }
                } else {
                    b.removeAnimation(forKey: "h")
                }
            }
            CATransaction.commit()
        }
    }

    func makeNSView(context: Context) -> BarsView { BarsView() }
    func updateNSView(_ v: BarsView, context: Context) {
        v.update(color: NSColor(Prefs.shared.accentColor).cgColor, animating: animating)
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: BarsView, context: Context) -> CGSize? { CGSize(width: 12, height: 12) }
}

// MARK: - Track row

struct TrackRow: View {
    /// Fits "100:00:00" at 12 pt monospaced digits.
    static let timeColumn: CGFloat = 64
    let item: MediaItem
    var index: Int? = nil
    var showArtwork = true
    var showAlbum = true
    var playlistContext: (playlistId: String, editable: Bool)? = nil
    var onRemoved: (() -> Void)? = nil
    var onPlay: () -> Void
    @ObservedObject private var now = PlayerController.shared.now
    @ObservedObject private var durations = DurationCache.shared
    @ObservedObject private var likes = LikeStore.shared
    @State private var hover = false
    private var player: PlayerController { .shared }
    private var model: AppModel { .shared }

    private var duration: TimeInterval? { item.duration ?? item.videoId.flatMap(durations.duration) }

    private var isCurrent: Bool { item.videoId != nil && now.videoId == item.videoId }

    private var titleLine: some View {
        HStack(spacing: 5) {
            Text(item.title).font(.system(size: 13, weight: isCurrent ? .semibold : .regular))
                .foregroundStyle(isCurrent ? Color.accentColor : .primary)
                .lineLimit(1)
            if item.isExplicit { ExplicitBadge() }
            if item.kind == .video { Image(systemName: "play.rectangle").font(.system(size: 10)).foregroundStyle(.secondary) }
        }
    }

    /// "62M plays" / "4.6M views" from the subtitle, when YouTube gives one.
    private var playsText: String? {
        item.subtitle.components(separatedBy: " • ").first { $0.contains("plays") || $0.contains("views") }?
            .trimmingCharacters(in: .whitespaces)
    }

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                if showArtwork {
                    Artwork(url: item.thumbnail, cornerRadius: 6, aspect: 1, size: 40)
                        .frame(width: 40, height: 40)
                        .overlay {
                            if hover || isCurrent {
                                RoundedRectangle(cornerRadius: 4).fill(.black.opacity(0.45))
                                if hover && !isCurrent {
                                    Image(systemName: "play.fill").foregroundStyle(.white)
                                } else { PlayingBars(animating: now.isPlaying).foregroundStyle(.white) }
                            }
                        }
                } else {
                    Group {
                        if isCurrent { PlayingBars(animating: now.isPlaying) }
                        else if hover { Image(systemName: "play.fill").font(.system(size: 11)) }
                        else { Text(index.map { "\($0)" } ?? "").font(.system(size: 13).monospacedDigit()).foregroundStyle(.secondary) }
                    }
                    .frame(width: 24)
                }
            }
            if showAlbum {
                // Wide lists: Apple Music-style columns that share the row's width.
                // No layoutPriority: the three columns split the width evenly
                // (a priority let the title swallow the artist/album columns).
                titleLine
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                ArtistLinks(artists: item.artists, fallback: item.subtitle)
                    .font(.system(size: 12.5)).foregroundStyle(.secondary).lineLimit(1)
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                Group {
                    if let album = item.album {
                        Text(album.name)
                            .underlineOnHover()
                            .onTapGesture { if album.browseId != nil { model.openAlbum(album) } }
                    } else {
                        Text(playsText ?? "")
                    }
                }
                .font(.system(size: 12.5)).foregroundStyle(.secondary).lineLimit(1)
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    titleLine
                    ArtistLinks(artists: item.artists, fallback: item.subtitle)
                        .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if let plays = playsText {
                    Text(plays).font(.system(size: 12)).foregroundStyle(.tertiary).lineLimit(1).fixedSize()
                }
            }
            // Like · length · more as one evenly spaced cluster. The length sits
            // centred in a column wide enough for "100:00:00", so the gaps on both
            // sides of it are equal and nothing moves, however long a track is.
            HStack(spacing: 4) {
                if let vid = item.videoId {
                    // Filled and in the accent colour when liked; tap again to unlike.
                    let isLiked = likes.liked.contains(vid)
                    Button {
                        player.setLike(isLiked ? .indifferent : .like, for: vid)
                        model.flash(isLiked ? "Removed from Liked Music" : "Added to Liked Music")
                    } label: {
                        Image(systemName: isLiked ? "hand.thumbsup.fill" : "hand.thumbsup")
                            .foregroundStyle(isLiked ? Color.accentColor : .primary)
                    }
                    .buttonStyle(BarIconStyle(size: 12, diameter: 26)).help(isLiked ? "Remove like" : "Like")
                    .opacity(hover || isLiked ? 1 : 0.4)
                } else {
                    Color.clear.frame(width: 26, height: 26)
                }
                Text(duration.map(formatTime) ?? "")
                    .font(.system(size: 12).monospacedDigit()).foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(width: TrackRow.timeColumn, alignment: .center)
                Menu {
                    ItemMenu(item: item, playlistContext: playlistContext, onRemoved: onRemoved)
                } label: {
                    Image(systemName: "ellipsis").frame(width: 26, height: 26).contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 26, height: 26)
                .opacity(hover ? 1 : 0.4)
            }
            .fixedSize()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(isCurrent ? 0.1 : (hover ? 0.09 : 0)))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.primary.opacity(hover || isCurrent ? 0.1 : 0), lineWidth: 0.5))
        }
        // Hairline between rows (hidden under the hover/current highlight).
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.primary.opacity(hover || isCurrent ? 0 : 0.07)).frame(height: 0.5)
                .padding(.leading, showArtwork ? 62 : 46).padding(.trailing, 10)
                .offset(y: 1)
        }
        .contentShape(Rectangle())
        .onAppear { if item.duration == nil, let v = item.videoId { durations.request(v) } }
        .onHover { h in if !(h && ScrollActivity.isScrolling) { hover = h } }
        .onTapGesture(count: 2) { onPlay() }
        .contextMenu {
            ItemMenu(item: item, playlistContext: playlistContext, onRemoved: onRemoved)
                
        }
        .overlay(alignment: .leading) {
            // Single click on the artwork / number plays, like Apple Music.
            Color.clear.frame(width: showArtwork ? 50 : 34).contentShape(Rectangle()).onTapGesture { onPlay() }
        }
    }
}

struct ArtistLinks: View {
    let artists: [ArtistRef]
    var fallback: String = ""
    private var model: AppModel { .shared }

    var body: some View {
        if artists.isEmpty {
            Text(fallback)
        } else {
            HStack(spacing: 0) {
                ForEach(Array(artists.enumerated()), id: \.offset) { i, a in
                    if a.browseId != nil {
                        Text(a.name).underlineOnHover().onTapGesture { model.openArtist(a) }
                    } else {
                        Text(a.name)
                    }
                    if i < artists.count - 1 { Text(", ") }
                }
            }
        }
    }
}

struct UnderlineOnHover: ViewModifier {
    @State private var hover = false
    func body(content: Content) -> some View {
        content.underline(hover).onHover { hover = $0 }
    }
}
extension View { func underlineOnHover() -> some View { modifier(UnderlineOnHover()) } }

// MARK: - Shelves

struct ShelfView: View {
    let shelf: Shelf
    var hideable = false
    @State private var headerHover = false
    private var player: PlayerController { .shared }
    private var model: AppModel { .shared }
    /// Only changes when an arrow is clicked (never while scrolling), so swiping a
    /// carousel doesn't re-render the shelf every frame.
    @State private var pageIndex = 0
    @State private var scrollRequest: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            switch shelf.style {
            case .cards: cards
            case .quickPicks: quickPicks
            case .list: list
            case .moods: moods
            }
        }
    }

    private var header: some View {
        headerContent
            .contentShape(Rectangle())
            .onHover { h in withAnimation(.easeOut(duration: 0.15)) { headerHover = h } }
            .contextMenu {
                if hideable && !shelf.title.isEmpty {
                    Button("Hide “\(shelf.title)” from Home") { Prefs.shared.hideHomeSection(shelf.title) }
                }
            }
    }

    private var headerContent: some View {
        HStack(alignment: .center) {
            if let thumb = shelf.thumbnail {
                Artwork(url: thumb, cornerRadius: 20, aspect: 1).frame(width: 40, height: 40)
            }
            VStack(alignment: .leading, spacing: 1) {
                if let s = shelf.strapline { Text(s.uppercased()).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary) }
                if !shelf.title.isEmpty {
                    Text(shelf.title).font(.system(size: 22, weight: .bold)).lineLimit(1)
                }
            }
            Spacer()
            HStack(spacing: 2) {
                if hideable && !shelf.title.isEmpty {
                    Button { withAnimation(.easeInOut(duration: 0.3)) { Prefs.shared.hideHomeSection(shelf.title) } } label: {
                        Image(systemName: "eye.slash")
                    }
                    .buttonStyle(BarIconStyle(size: 12))
                    .hoverTip("Hide section")
                    .opacity(headerHover ? 1 : 0)
                }
                if let more = shelf.moreBrowseId {
                    Button { model.push(more.hasPrefix("VL") || more.hasPrefix("MPRE") ? .collection(more) : .browse(more, shelf.moreParams, shelf.title)) } label: {
                        HStack(spacing: 3) { Text("See All"); Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)) }
                    }
                    .buttonStyle(TextLinkStyle())
                }
                if shelf.style == .cards || shelf.style == .quickPicks {
                    Button { page(-1) } label: { Image(systemName: "chevron.left") }.hoverTip("Previous")
                    Button { page(1) } label: { Image(systemName: "chevron.right") }.hoverTip("Next")
                }
            }
            .buttonStyle(BarIconStyle(size: 12))
        }
    }

    private func page(_ dir: Int) {
        let step = shelf.style == .quickPicks ? 1 : 4
        let maxIndex = shelf.style == .quickPicks ? max(0, (shelf.items.count - 1) / 4) : max(0, shelf.items.count - 1)
        pageIndex = min(max(0, pageIndex + dir * step), maxIndex)
        scrollRequest = pageIndex
    }

    private var cards: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 18) {
                    ForEach(Array(shelf.items.enumerated()), id: \.element.id) { i, item in
                        CardView(item: item, width: item.kind == .video ? Prefs.shared.cardWidth * 1.66 : Prefs.shared.cardWidth).id(i)
                    }
                }
                .padding(.vertical, 4)
            }
            // Scroll edge-to-edge inside the panel; cards start aligned with the page text.
            .contentMargins(.horizontal, 28, for: .scrollContent)
            .padding(.horizontal, -28)
            .onChange(of: scrollRequest) {
                guard let r = scrollRequest else { return }
                withAnimation(.timingCurve(0.25, 0.1, 0.25, 1, duration: 0.45)) { proxy.scrollTo(r, anchor: .leading) }
                scrollRequest = nil
            }
        }
    }

    private var quickPicks: some View {
        let columns = stride(from: 0, to: shelf.items.count, by: 4).map { Array(shelf.items[$0..<min($0 + 4, shelf.items.count)]) }
        return ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 16) {
                    ForEach(Array(columns.enumerated()), id: \.offset) { ci, col in
                        VStack(spacing: 2) {
                            ForEach(col) { item in
                                TrackRow(item: item, showAlbum: false) { player.play(item) }
                                    .frame(width: 380)
                            }
                        }
                        .id(ci)
                    }
                }
            }
            .contentMargins(.horizontal, 28, for: .scrollContent)
            .padding(.horizontal, -28)
            .onChange(of: scrollRequest) {
                guard let r = scrollRequest else { return }
                withAnimation(.timingCurve(0.25, 0.1, 0.25, 1, duration: 0.45)) { proxy.scrollTo(r, anchor: .leading) }
                scrollRequest = nil
            }
        }
    }

    private var list: some View {
        let tracks = shelf.items
        return VStack(spacing: 0) {
            ForEach(Array(tracks.prefix(8).enumerated()), id: \.element.id) { i, item in
                if item.videoId != nil {
                    TrackRow(item: item) {
                        let playable = tracks.compactMap(\.track)
                        let idx = playable.firstIndex { $0.videoId == item.videoId } ?? 0
                        player.play(tracks: playable, startAt: idx)
                    }
                } else {
                    CollectionRow(item: item)
                }
            }
        }
    }

    private var moods: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 12)], spacing: 12) {
            ForEach(shelf.items) { item in MoodTile(item: item) }
        }
    }
}

/// Row for albums / artists / playlists in list-style search results.
struct CollectionRow: View {
    let item: MediaItem
    private var model: AppModel { .shared }
    @State private var hover = false
    var body: some View {
        HStack(spacing: 12) {
            Artwork(url: item.thumbnail, cornerRadius: item.kind == .artist ? 20 : 6, aspect: 1,
                    symbol: item.kind == .artist ? "person.fill" : "music.note", size: 40)
                .frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(.system(size: 13)).lineLimit(1)
                Text(item.subtitle).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 6).fill(hover ? Color.primary.opacity(0.06) : .clear))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { model.open(item) }
        .contextMenu { ItemMenu(item: item) }
    }
}

struct MoodTile: View {
    let item: MediaItem
    private var model: AppModel { .shared }
    @State private var hover = false
    var color: Color {
        guard let c = item.tileColor else { return .accentColor }
        return Color(red: Double((c >> 16) & 0xFF) / 255, green: Double((c >> 8) & 0xFF) / 255, blue: Double(c & 0xFF) / 255)
    }
    var body: some View {
        HStack(spacing: 0) {
            Rectangle().fill(color).frame(width: 6)
            Text(item.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                .padding(.horizontal, 12)
            Spacer(minLength: 0)
        }
        .frame(height: 46)
        .background(hover ? Color.primary.opacity(0.16) : Color.primary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .contextMenu { ItemMenu(item: item) }
        .onHover { hover = $0 }
        .onTapGesture { model.open(item) }
    }
}

// MARK: - Loading / error states

struct LoadingView: View {
    var body: some View {
        ProgressView().controlSize(.large).frame(maxWidth: .infinity, maxHeight: .infinity).padding(80)
    }
}

struct ErrorView: View {
    let message: String
    let retry: () -> Void
    var body: some View {
        ContentUnavailableView {
            Label("Couldn't Load", systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        } actions: {
            Button("Try Again", action: retry).buttonStyle(.borderedProminent)
        }
        .padding(60)
    }
}

/// Generic async page loader with retry.
struct AsyncPage<T, Content: View>: View {
    let id: String
    let load: () async throws -> T
    @ViewBuilder let content: (T, @escaping () -> Void) -> Content
    @State private var value: T?
    @State private var error: String?
    @State private var reloadToken = 0

    var body: some View {
        Group {
            if let value { content(value, { reloadToken += 1 }) }
            else if let error { ErrorView(message: error) { self.error = nil; reloadToken += 1 } }
            else { LoadingView() }
        }
        .task(id: "\(id)#\(reloadToken)") {
            do { let v = try await load(); value = v; error = nil }
            catch is CancellationError {}
            catch { if value == nil { self.error = error.localizedDescription } }
        }
    }
}


/// Quiet text action (e.g. "See All"): secondary text that brightens, with a
/// soft rounded highlight and sheen on hover.
struct TextLinkStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { LinkBody(configuration: configuration) }
    private struct LinkBody: View {
        let configuration: ButtonStyleConfiguration
        @State private var hover = false
        var body: some View {
            configuration.label
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(hover ? .primary : .secondary)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(configuration.isPressed ? 0.2 : (hover ? 0.12 : 0))))
                .cursorSheen(RoundedRectangle(cornerRadius: 8, style: .continuous), strength: 0.14)
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .animation(.easeOut(duration: 0.15), value: hover)
                .onHover { hover = $0 }
        }
    }
}
