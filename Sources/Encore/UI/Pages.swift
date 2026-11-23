import SwiftUI

private let pageInset: CGFloat = 28

/// Space reserved so page content starts below the top bar and can scroll
/// fully clear of the floating player bar.
enum PageInsets {
    static let top: CGFloat = ContentView.topBarHeight + 18
    static let bottom: CGFloat = PlayerBar.height + 40
}

extension View {
    /// Row styling for pages built on the native List: transparent, no separators, page insets.
    func listChrome(top: CGFloat = 0, bottom: CGFloat = 0) -> some View {
        self.listRowInsets(EdgeInsets(top: top, leading: 28, bottom: bottom, trailing: 28))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }

    /// Leaves room at the top for the floating back/forward buttons.
    func pagePadding() -> some View {
        padding(.horizontal, 28).padding(.top, PageInsets.top).padding(.bottom, PageInsets.bottom)
    }
}

// MARK: - Shelf pages (Home / Explore / Charts / Moods / generic browse)

struct ShelvesPage: View {
    let title: String
    let id: String
    let loader: (Chip?) async throws -> BrowsePage
    var showChips = false
    var header: AnyView? = nil
    @State private var page: BrowsePage?
    @State private var extra: [Shelf] = []
    @State private var continuation: String?
    @State private var loadingMore = false
    @State private var chip: Chip?
    @State private var error: String?
    @State private var reload = 0
    @ObservedObject private var prefs = Prefs.shared

    var body: some View {
        ScrollView {
            // Eager VStack: shelves are built once up front instead of being
            // created mid-scroll, which is what caused hitches.
            VStack(alignment: .leading, spacing: 34) {
                Text(title).font(.system(size: 30, weight: .bold)).padding(.bottom, -14)
                if let header { header }
                if showChips, Prefs.shared.showHomeChips, let chips = page?.chips, !chips.isEmpty {
                    // One full-width row when they fit; otherwise a single swipeable row
                    // with arrows (never a second row).
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 8) { chipButtons(chips) }
                        ChipScroller(chips: chips, selected: chip?.title) { c in
                            chip = chip?.title == c.title ? nil : c
                        }
                    }
                }
                if let page {
                    let hidden = id == "home" ? Set(Prefs.shared.hiddenHomeSections) : []
                    ForEach((page.shelves + extra).filter { !hidden.contains($0.title) }) { s in
                        ShelfView(shelf: s, hideable: id == "home")
                    }
                    // Keeps going like YouTube: YouTube's own pages first, then an
                    // endless "Because you listened to…" feed (see loadMore).
                    if continuation != nil || canDiscover {
                        ProgressView().frame(maxWidth: .infinity).padding()
                            .onAppear { loadMore() }
                            .id("more-\(extra.count)")
                    }
                    if id == "home", !prefs.hiddenHomeSections.isEmpty {
                        HStack(spacing: 12) {
                            Image(systemName: "eye.slash").foregroundStyle(.secondary)
                            Text("\(prefs.hiddenHomeSections.count) hidden section\(prefs.hiddenHomeSections.count == 1 ? "" : "s")")
                                .font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
                            Menu {
                                ForEach(prefs.hiddenHomeSections, id: \.self) { t in
                                    Button("Show “\(t)”") { withAnimation { prefs.hiddenHomeSections.removeAll { $0 == t } } }
                                }
                                Divider()
                                Button("Show All") { withAnimation { prefs.hiddenHomeSections = [] } }
                            } label: { Label("Show Sections", systemImage: "eye") }
                                .menuStyle(.button).buttonStyle(CapsuleButtonStyle(prominent: false)).menuIndicator(.hidden).fixedSize()
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                    }
                } else if let error {
                    ErrorView(message: error) { self.error = nil; reload += 1 }
                } else {
                    LoadingView()
                }
            }
            .pagePadding()
        }
        .task(id: "\(id)|\(chip?.title ?? "")|\(reload)") {
            do {
                let p = try await loader(chip)
                var merged = p
                if chip != nil, let old = page { merged.chips = old.chips }
                page = merged; extra = []; continuation = p.continuation; error = nil
                usedSeeds = []; discoveryExhausted = false
            } catch is CancellationError {
            } catch { if page == nil { self.error = error.localizedDescription } }
        }
        .refreshable { reload += 1 }
    }

    @ViewBuilder private func chipButtons(_ chips: [Chip]) -> some View {
        ForEach(chips) { c in
            let selected = chip?.title == c.title
            Button(c.title) { chip = selected ? nil : c }
                .buttonStyle(ChipStyle(selected: selected, fill: true))
                // A floor on each chip's width: when they can't all get it, the
                // single-row layout no longer "fits" and the swipeable row is used
                // instead of squeezing labels into "Roma…".
                .frame(minWidth: 104)
        }
    }

    /// Home and Explore never run out: after YouTube's own feed ends, keep adding
    /// "Because you listened to…" sections built from YouTube's related-music page
    /// for songs you've played or that appear in the feed.
    private var discovers: Bool { id == "home" || id == "explore" }
    private var canDiscover: Bool { discovers && !discoveryExhausted && extra.count < 80 }
    @State private var usedSeeds = Set<String>()
    @State private var discoveryExhausted = false

    private func loadMore() {
        guard !loadingMore else { return }
        if let token = continuation {
            loadingMore = true
            Task {
                defer { loadingMore = false }
                if let more = try? await InnerTube.shared.continuation(token) {
                    extra += more.shelves
                    continuation = more.continuation
                } else { continuation = nil }
            }
        } else if canDiscover {
            loadingMore = true
            Task {
                defer { loadingMore = false }
                await discoverMore()
            }
        }
    }

    /// Adds one or two sections related to a song not used before.
    private func discoverMore() async {
        // Seeds: your recent plays first, then songs shown on this page.
        var seeds: [(id: String, title: String)] = PlayStats.shared.recent(40).map { ($0.videoId, $0.title) }
        let shown = ((page?.shelves ?? []) + extra).flatMap(\.items).compactMap { i in i.videoId.map { ($0, i.title) } }
        seeds += shown.shuffled()
        let shownTitles = Set(((page?.shelves ?? []) + extra).map { $0.title + ($0.strapline ?? "") })
        for seed in seeds where !usedSeeds.contains(seed.id) {
            usedSeeds.insert(seed.id)
            guard let q = try? await InnerTube.shared.watchQueue(videoId: seed.id, playlistId: nil),
                  let related = q.relatedBrowseId,
                  let rp = try? await InnerTube.shared.browse(related) else { continue }
            let fresh = Parser.browsePage(rp).shelves
                .filter { !$0.items.isEmpty && $0.style != .moods }
                .prefix(2)
                .map { sh -> Shelf in
                    var sh = sh
                    sh.strapline = "Because you listened to \(seed.title)"
                    sh.moreBrowseId = nil
                    return sh
                }
                .filter { !shownTitles.contains($0.title + ($0.strapline ?? "")) }
            if !fresh.isEmpty { extra += fresh; return }
        }
        discoveryExhausted = true
    }
}

struct ChipStyle: ButtonStyle {
    var selected: Bool
    var fill = false
    func makeBody(configuration: Configuration) -> some View { ChipBody(configuration: configuration, selected: selected, fill: fill) }

    private struct ChipBody: View {
        let configuration: ButtonStyleConfiguration
        let selected: Bool
        let fill: Bool
        @State private var hover = false
        var body: some View {
            configuration.label
                .font(.system(size: 12.5, weight: .medium))
                .lineLimit(1)
                .padding(.horizontal, 14).padding(.vertical, fill ? 9 : 6)
                .frame(maxWidth: fill ? .infinity : nil)
                .foregroundStyle(selected ? Color(nsColor: .windowBackgroundColor) : .primary)
                .background(Capsule().fill(selected ? Color.primary : Color.primary.opacity(configuration.isPressed ? 0.2 : (hover ? 0.14 : 0.08))))
                .overlay(Capsule().strokeBorder(Color.white.opacity(hover ? 0.2 : 0.06), lineWidth: 0.6))
                .cursorSheen(Capsule(), strength: selected ? 0.1 : 0.22)
                .contentShape(Capsule())
                .scaleEffect(configuration.isPressed ? 0.96 : (hover ? 1.02 : 1))
                .animation(.spring(duration: 0.22, bounce: 0.3), value: hover)
                .animation(.spring(duration: 0.18, bounce: 0.3), value: configuration.isPressed)
                .onHover { hover = $0 }
        }
    }
}

struct HomeView: View {
    var body: some View {
        ShelvesPage(title: "Home", id: "home", loader: { chip in
            if let chip { return try await InnerTube.shared.homeChip(chip) }
            return try await InnerTube.shared.home()
        }, showChips: true, header: AnyView(SpeedDialView()))
    }
}

struct BrowseView: View {
    let title: String
    let browseId: String
    let params: String?
    var body: some View {
        ShelvesPage(title: title, id: browseId + (params ?? ""), loader: { chip in
            if let chip { return try await InnerTube.shared.homeChip(chip) }
            return try await InnerTube.shared.genericPage(browseId, params: params)
        }, showChips: true)
    }
}

// MARK: - Album / playlist

struct CollectionView: View {
    let browseId: String
    private var player: PlayerController { .shared }
    private var model: AppModel { .shared }
    @State private var page: CollectionPage?
    @State private var tracks: [MediaItem] = []
    @State private var continuation: String?
    @State private var error: String?
    @State private var reload = 0
    @State private var filter = ""
    @State private var descExpanded = false
    @State private var saved: Bool?
    @State private var pageWidth: CGFloat = 900

    var body: some View {
        Group {
            if let page {
                // Native list (NSTableView): rows are recycled as you scroll, so
                // even thousands of songs scroll at the display's full frame rate.
                List {
                    // Spacing as padding inside the row: the native list applies a row's
                    // large top inset below it too, which left a ~70 pt gap above the songs.
                    header(page)
                        .padding(.top, PageInsets.top)
                        .padding(.bottom, 18)
                        .listChrome()
                        .background(GeometryReader { g in Color.clear.onAppear { pageWidth = g.size.width }
                            .onChange(of: g.size.width) { pageWidth = g.size.width } })
                    trackRows(page)
                    ForEach(page.otherShelves) { ShelfView(shelf: $0).listChrome(top: 28) }
                    Color.clear.frame(height: PageInsets.bottom).listChrome()
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .environment(\.defaultMinListRowHeight, 1)
            } else if let error {
                ErrorView(message: error) { self.error = nil; reload += 1 }
            } else { LoadingView() }
        }
        .task(id: "\(browseId)#\(reload)") { await load() }
        .navigationTitle(page?.title ?? "")
    }

    private func load() async {
        do {
            let p = try await InnerTube.shared.collection(browseId)
            page = p; tracks = p.tracks; continuation = p.continuation; saved = p.isSaved; error = nil
            if browseId == "VLLM" { LikeStore.shared.seedLiked(p.tracks.compactMap(\.videoId)) }
        } catch is CancellationError {
        } catch { if page == nil { self.error = error.localizedDescription } }
    }

    private var playableTracks: [Track] { tracks.compactMap(\.track) }

    /// Header adapts to the page width: side-by-side when there's room,
    /// stacked (cover above details) when the window or pane is narrow.
    @ViewBuilder private func header(_ p: CollectionPage) -> some View {
        let compact = pageWidth < 700
        let side: CGFloat = compact ? 168 : (pageWidth > 1100 ? 260 : 220)
        let cover = Artwork(url: p.thumbnail.map { Thumbs.upscale($0, size: 600) }, cornerRadius: 16, aspect: 1, size: side)
            .frame(width: side, height: side)
            .shadow(color: .black.opacity(0.3), radius: 18, y: 10)
        if compact {
            VStack(alignment: .leading, spacing: 16) {
                cover
                details(p, compact: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            // A definite width for the details: the list sizes this row from it, so
            // wrapped text can't be measured at another width and leave a tall gap.
            // Explicit height (the cover's): the native list otherwise sizes this row
            // ~46 pt taller than its content, leaving a gap above the songs.
            HStack(alignment: .bottom, spacing: 26) {
                cover
                details(p, compact: false)
                    .frame(width: max(240, pageWidth - side - 26), alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: side, alignment: .bottom)
        }
    }

    @ViewBuilder private func details(_ p: CollectionPage, compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(p.title)
                .font(.system(size: compact ? 24 : 30, weight: .bold))
                .lineLimit(2).minimumScaleFactor(0.7)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            if !p.artists.isEmpty {
                ArtistLinks(artists: p.artists)
                    .font(.system(size: compact ? 16 : 19, weight: .semibold))
                    .foregroundStyle(Color.accentColor).lineLimit(1)
            }
            let meta = [p.subtitle, p.secondSubtitle].filter { !$0.isEmpty }.joined(separator: " · ")
            if !meta.isEmpty {
                Text(meta).font(.system(size: 11.5, weight: .medium)).foregroundStyle(.secondary)
                    .textCase(.uppercase).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            if let d = p.description, !d.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text(d).font(.system(size: 12.5)).foregroundStyle(.secondary)
                        .lineLimit(descExpanded ? nil : 2)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    if d.count > 120 {
                        Button(descExpanded ? "Less" : "More") { withAnimation(.spring(duration: 0.3)) { descExpanded.toggle() } }
                            .buttonStyle(.plain).font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.accentColor)
                    }
                }
                .frame(maxWidth: 620, alignment: .leading)
            }
            // Full labels when they fit, icon-only buttons when they don't; the song
            // filter sits at the end of the same row (long lists only).
            HStack(spacing: 12) {
                ViewThatFits(in: .horizontal) {
                    actionButtons(p, labels: true)
                    actionButtons(p, labels: false)
                }
                Spacer(minLength: 0)
                if tracks.count > 15 {
                    FilterField(text: $filter)
                        .frame(width: compact ? 170 : 210)
                        .padding(.trailing, 10)   // lines up with the rows' ⋯ column
                }
            }
            .padding(.top, 8)
        }
    }

    @ViewBuilder private func actionButtons(_ p: CollectionPage, labels: Bool) -> some View {
        HStack(spacing: 10) {
            Button { player.play(tracks: playableTracks) } label: {
                Label("Play", systemImage: "play.fill").frame(minWidth: labels ? 84 : nil)
            }
            .glassButton(prominent: true).controlSize(.large)
            Button { player.play(tracks: playableTracks, shuffle: true) } label: {
                if labels { Label("Shuffle", systemImage: "shuffle").frame(minWidth: 84) } else { Image(systemName: "shuffle") }
            }
            .glassButton().controlSize(.large).help("Shuffle")
            if let radio = p.radioPlaylistId {
                Button { Task { await player.playPlaylist(radio) } } label: {
                    if labels { Label("Radio", systemImage: "dot.radiowaves.left.and.right") } else { Image(systemName: "dot.radiowaves.left.and.right") }
                }
                .glassButton().controlSize(.large).help("Start Radio")
            }
            if !p.isEditable, browseId != "VLLM", !(p.playlistId ?? "").hasPrefix("RD"), let pid = p.playlistId, let s = saved {
                Button {
                    saved = !s
                    Task {
                        try? await InnerTube.shared.ratePlaylist(playlistId: pid, saved: !s)
                        model.flash(!s ? "Added to Library" : "Removed from Library")
                        model.refreshPlaylists()
                    }
                } label: { Image(systemName: s ? "checkmark" : "plus") }
                    .glassButton().controlSize(.large).help(s ? "Remove from Library" : "Add to Library")
            }
            Menu {
                Button("Play Next") { player.playNext(playableTracks) }
                Button("Add to Queue") { player.addToQueue(playableTracks) }
                Divider()
                Menu("Add All to Playlist") {
                    ForEach(model.playlists) { pl in Button(pl.title) { model.addToPlaylist(pl, videoIds: playableTracks.map(\.videoId)) } }
                }
                Button("Copy Link") {
                    model.copyLink(p.playlistId.map { URL(string: "https://music.youtube.com/playlist?list=\($0)")! })
                }
                if p.isEditable, let pid = p.playlistId {
                    Divider()
                    Button("Delete Playlist", role: .destructive) {
                        Task {
                            try? await InnerTube.shared.deletePlaylist(playlistId: pid)
                            model.refreshPlaylists()
                            model.selection = .home
                        }
                    }
                }
            } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 30)
        }
        .fixedSize()
    }

    @ViewBuilder private func trackRows(_ p: CollectionPage) -> some View {
        let shown = filter.isEmpty ? tracks : tracks.filter {
            $0.title.localizedCaseInsensitiveContains(filter) || $0.artistLine.localizedCaseInsensitiveContains(filter)
        }
        ForEach(Array(shown.enumerated()), id: \.element.id) { i, item in
            TrackRow(item: item, index: i + 1, showArtwork: !p.isAlbum, showAlbum: !p.isAlbum && pageWidth > 760,
                     playlistContext: p.playlistId.map { ($0, p.isEditable) },
                     onRemoved: { tracks.removeAll { $0.id == item.id } }) {
                let list = shown.compactMap(\.track)
                player.play(tracks: list, startAt: list.firstIndex { $0.videoId == item.videoId } ?? 0)
            }
            .listChrome(top: 1, bottom: 1)
        }
        if continuation != nil {
            ProgressView().frame(maxWidth: .infinity).padding().onAppear { loadMore() }.listChrome()
        }
        if !tracks.isEmpty {
            let total = tracks.compactMap(\.duration).reduce(0, +)
            Text("\(tracks.count) songs\(total > 0 ? ", \(Int(total / 60)) minutes" : "")")
                .font(.system(size: 12)).foregroundStyle(.secondary).listChrome(top: 12)
        }
    }

    private func loadMore() {
        guard let token = continuation else { return }
        continuation = nil
        Task {
            if let (more, next) = try? await InnerTube.shared.collectionContinuation(token) {
                tracks += more.filter { $0.videoId != nil }
                if browseId == "VLLM" { LikeStore.shared.seedLiked(more.compactMap(\.videoId)) }
                continuation = more.isEmpty ? nil : next
            }
        }
    }
}

// MARK: - Artist

struct ArtistView: View {
    let browseId: String
    private var player: PlayerController { .shared }
    private var model: AppModel { .shared }
    @State private var subscribed: Bool?

    var body: some View {
        AsyncPage(id: browseId, load: { try await InnerTube.shared.artist(browseId) }) { page, _ in
            ScrollView {
                VStack(alignment: .leading, spacing: 34) {
                    hero(page).padding(.top, ContentView.topBarHeight + 8)
                    VStack(alignment: .leading, spacing: 34) {
                        ForEach(page.shelves) { ShelfView(shelf: $0) }
                        if let d = page.description, !d.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("About").font(.system(size: 22, weight: .bold))
                                Text(d).font(.system(size: 13)).foregroundStyle(.secondary).frame(maxWidth: 760, alignment: .leading)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                    // Room for the floating player bar, like every other page.
                    .padding(.horizontal, pageInset).padding(.bottom, PageInsets.bottom)
                }
            }
            .navigationTitle(page.name)
        }
    }

    @ViewBuilder private func hero(_ page: ArtistPage) -> some View {
        ZStack(alignment: .bottomLeading) {
            GeometryReader { g in
                Artwork(url: page.thumbnail.map { Thumbs.upscale($0, size: 1600) }, cornerRadius: 0, aspect: 16 / 7, symbol: "person.fill", size: 1200)
                    .frame(width: g.size.width, height: g.size.height)
                    .clipped()
            }
            .frame(height: 380)
            LinearGradient(stops: [.init(color: .clear, location: 0.35), .init(color: .black.opacity(0.75), location: 1)],
                           startPoint: .top, endPoint: .bottom)
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 14) {
                    // Big display name that shrinks to fit long names / narrow windows.
                    Text(page.name)
                        .font(.system(size: 92, weight: .black))
                        .tracking(-1.5)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.4)
                        .shadow(color: .black.opacity(0.35), radius: 12, y: 4)
                    HStack(spacing: 10) {
                        if let s = page.shufflePlaylistId {
                            Button { Task { await player.playPlaylist(s) } } label: { Label("Shuffle", systemImage: "shuffle").frame(width: 90) }
                                .glassButton(prominent: true).controlSize(.large)
                        }
                        if let r = page.radioPlaylistId {
                            Button { Task { await player.playPlaylist(r) } } label: { Label("Radio", systemImage: "dot.radiowaves.left.and.right") }
                                .glassButton().controlSize(.large)
                        }
                        if let cid = page.channelId {
                            // Subscribe: bright, solid call to action. Subscribed: quiet
                            // glass with a checkmark (tap to unsubscribe).
                            let isSub = subscribed ?? page.isSubscribed
                            let toggle = {
                                withAnimation(.easeInOut(duration: 0.2)) { subscribed = !isSub }
                                model.flash(isSub ? "Unsubscribed" : "Subscribed")
                                Task { try? await InnerTube.shared.subscribe(channelId: cid, !isSub) }
                            }
                            if isSub {
                                Button(action: toggle) {
                                    Label { Text("Subscribed") + Text(page.subscribers.map { "  \($0)" } ?? "").foregroundColor(.secondary) }
                                          icon: { Image(systemName: "checkmark") }
                                }
                                .glassButton().controlSize(.large)
                                .help("Unsubscribe")
                            } else {
                                Button(action: toggle) {
                                    Label { Text("Subscribe") + Text(page.subscribers.map { "  \($0)" } ?? "").foregroundColor(.black.opacity(0.55)) }
                                          icon: { Image(systemName: "plus") }
                                }
                                .buttonStyle(SolidPillStyle())
                            }
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            // Anchored to the photo's bottom edge (no page-level insets here).
            .padding(.horizontal, 32)
            .padding(.bottom, 28)
        }
        .frame(height: 380)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

// MARK: - Library

struct LibraryView: View {
    let section: InnerTube.LibrarySection
    private var player: PlayerController { .shared }

    var body: some View {
        AsyncPage(id: section.rawValue, load: { try await InnerTube.shared.library(section) }) { page, _ in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text(section.rawValue).font(.system(size: 30, weight: .bold))
                    let items = page.shelves.flatMap(\.items).filter { $0.browseId != nil || $0.videoId != nil }
                    if items.isEmpty {
                        ContentUnavailableView("Nothing Here Yet", systemImage: section.symbol,
                                               description: Text("Items you add to your YouTube Music library appear here."))
                    } else if section == .history {
                        ForEach(page.shelves) { shelf in
                            Text(shelf.title).font(.system(size: 17, weight: .semibold)).padding(.top, 8)
                            trackList(shelf.items)
                        }
                    } else if items.allSatisfy({ $0.videoId != nil }) {
                        HStack {
                            Button { player.play(tracks: items.compactMap(\.track)) } label: { Label("Play", systemImage: "play.fill") }
                                .glassButton(prominent: true)
                            Button { player.play(tracks: items.compactMap(\.track), shuffle: true) } label: { Label("Shuffle", systemImage: "shuffle") }
                                .glassButton()
                        }
                        trackList(items)
                    } else if section == .artists || section == .subscriptions {
                        LazyVStack(spacing: 0) { ForEach(items) { CollectionRow(item: $0) } }
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 20, alignment: .top)], spacing: 26) {
                            ForEach(items) { CardView(item: $0, width: 170) }
                        }
                    }
                }
                .pagePadding()
            }
        }
    }

    private func trackList(_ items: [MediaItem]) -> some View {
        LazyVStack(spacing: 0) {
            ForEach(items) { item in
                TrackRow(item: item, showAlbum: true) {
                    let list = items.compactMap(\.track)
                    player.play(tracks: list, startAt: list.firstIndex { $0.videoId == item.videoId } ?? 0)
                }
            }
        }
    }
}

// MARK: - Search

struct SearchView: View {
    let query: String
    private var player: PlayerController { .shared }
    private var model: AppModel { .shared }
    @State private var filter: Filter = .all
    @State private var results: SearchResults?
    @State private var items: [MediaItem] = []
    @State private var continuation: String?
    @State private var error: String?

    enum Filter: String, CaseIterable, Identifiable {
        case all = "All", songs = "Songs", videos = "Videos", albums = "Albums", artists = "Artists",
             playlists = "Community Playlists", featured = "Featured Playlists", podcasts = "Podcasts"
        var id: String { rawValue }
        var params: String? {
            switch self {
            case .all: return nil
            case .songs: return "EgWKAQIIAWoKEAkQBRAKEAMQBA%3D%3D"
            case .videos: return "EgWKAQIQAWoKEAkQChAFEAMQBA%3D%3D"
            case .albums: return "EgWKAQIYAWoKEAkQChAFEAMQBA%3D%3D"
            case .artists: return "EgWKAQIgAWoKEAkQChAFEAMQBA%3D%3D"
            case .playlists: return "EgeKAQQoAEABagoQAxAEEAoQCRAF"
            case .featured: return "EgeKAQQoADgBagwQDhAKEAMQBRAJEAQ%3D"
            case .podcasts: return "EgWKAQJQAWoIEBAQERADEBU%3D"
            }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Filter.allCases) { f in
                            Button(f.rawValue) { filter = f }.buttonStyle(ChipStyle(selected: filter == f))
                        }
                    }
                }
                if let error {
                    ErrorView(message: error) { self.error = nil }
                } else if let results {
                    if filter == .all { allResults(results) } else { filtered }
                } else { LoadingView() }
            }
            .pagePadding()
        }
        .task(id: query + filter.rawValue) {
            results = nil; items = []; continuation = nil
            guard !query.isEmpty else { return }
            do {
                let r = try await InnerTube.shared.search(query, params: filter.params?.removingPercentEncoding)
                results = r; items = r.items; continuation = r.continuation; error = nil
            } catch is CancellationError {
            } catch { self.error = error.localizedDescription }
        }
        .navigationTitle("Results for “\(query)”")
    }

    @ViewBuilder private func allResults(_ r: SearchResults) -> some View {
        if r.top == nil && r.shelves.isEmpty {
            ContentUnavailableView.search(text: query)
        } else {
            SearchOverview(results: r)
        }
    }

    @ViewBuilder private var filtered: some View {
        let isGrid = filter == .albums || filter == .playlists || filter == .featured || filter == .podcasts
        if items.isEmpty {
            ContentUnavailableView.search(text: query)
        } else if isGrid {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 20, alignment: .top)], spacing: 26) {
                ForEach(items) { CardView(item: $0, width: 170) }
            }
        } else {
            LazyVStack(spacing: 0) {
                ForEach(items) { item in
                    if item.videoId != nil {
                        TrackRow(item: item) { player.play(item) }
                    } else { CollectionRow(item: item) }
                }
            }
        }
        if continuation != nil {
            ProgressView().frame(maxWidth: .infinity).padding().onAppear { loadMore() }
        }
    }

    private func loadMore() {
        guard let token = continuation else { return }
        continuation = nil
        Task {
            if let (more, next) = try? await InnerTube.shared.searchContinuation(token) {
                let known = Set(items.map(\.id))
                items += more.filter { !known.contains($0.id) }
                continuation = more.isEmpty ? nil : next
            }
        }
    }
}

struct TopResultCard: View {
    let item: MediaItem
    private var player: PlayerController { .shared }
    private var model: AppModel { .shared }
    @State private var hover = false
    var body: some View {
        HStack(spacing: 18) {
            Artwork(url: item.thumbnail.map { Thumbs.upscale($0, size: 400) }, cornerRadius: item.kind == .artist ? 60 : 10, aspect: 1,
                    symbol: item.kind == .artist ? "person.fill" : "music.note", size: 120)
                .frame(width: 120, height: 120)
            VStack(alignment: .leading, spacing: 6) {
                Text(item.title).font(.system(size: 24, weight: .bold)).lineLimit(2)
                Text(item.subtitle).foregroundStyle(.secondary).lineLimit(1)
                HStack {
                    Button { player.play(item) } label: { Label("Play", systemImage: "play.fill") }.glassButton(prominent: true)
                    if item.kind.isCollection || item.kind == .artist {
                        Button("Open") { model.open(item) }.glassButton()
                    } else {
                        Button { player.startRadio(item) } label: { Label("Radio", systemImage: "dot.radiowaves.left.and.right") }.glassButton()
                    }
                }
                .padding(.top, 4)
            }
            Spacer()
        }
        .padding(16)
        .frame(maxWidth: 620)
        .cardSurface(16)
        .scaleEffect(hover ? 1.01 : 1)
        .animation(.spring(duration: 0.25), value: hover)
        .onHover { hover = $0 }
        .onTapGesture { model.open(item) }
        .contextMenu { ItemMenu(item: item) }
    }
}


// MARK: - Search overview ("All" tab)

/// Uses the full width: a large top result beside the top songs, then (for
/// artists) their popular songs, albums, singles, videos and bio, then the
/// remaining results. Song lists flow into two columns on wide windows.
struct SearchOverview: View {
    let results: SearchResults
    @State private var artist: ArtistPage?
    @State private var width: CGFloat = 1000
    private var player: PlayerController { .shared }

    private var topSongs: [MediaItem] {
        let songs = results.shelves.flatMap(\.items).filter { $0.videoId != nil }
        return Array(songs.prefix(5))
    }
    private var otherShelves: [Shelf] {
        results.shelves.filter { !$0.title.isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 36) {
            if let top = results.top {
                if width > 960 {
                    HStack(alignment: .top, spacing: 28) {
                        TopResultHero(item: top, artist: artist).frame(width: min(520, width * 0.42))
                        topSongsColumn.frame(maxWidth: .infinity)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 24) {
                        TopResultHero(item: top, artist: artist)
                        topSongsColumn
                    }
                }
            }
            if let artist, let top = results.top {
                ForEach(artist.shelves) { shelf in
                    if shelf.style == .list {
                        SongGrid(title: shelf.title.isEmpty ? "Popular" : shelf.title,
                                 strapline: top.title.uppercased(), items: shelf.items, twoColumns: width > 900)
                    } else {
                        ShelfView(shelf: Shelf(title: shelf.title, strapline: top.title.uppercased(), thumbnail: nil,
                                               style: shelf.style, items: shelf.items,
                                               moreBrowseId: shelf.moreBrowseId, moreParams: shelf.moreParams))
                    }
                }
                if let about = artist.description, !about.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("About \(artist.name)").font(.system(size: 22, weight: .bold))
                        if let subs = artist.subscribers { Text(subs).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary) }
                        Text(about).font(.system(size: 13)).foregroundStyle(.secondary)
                            .lineLimit(6).frame(maxWidth: 820, alignment: .leading).textSelection(.enabled)
                    }
                }
                Text("More results").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary).padding(.bottom, -24)
            }
            ForEach(otherShelves) { shelf in
                if shelf.style == .list {
                    SongGrid(title: shelf.title, strapline: nil, items: shelf.items, twoColumns: width > 900)
                } else {
                    ShelfView(shelf: shelf)
                }
            }
        }
        .background(GeometryReader { g in Color.clear.onAppear { width = g.size.width }.onChange(of: g.size.width) { width = g.size.width } })
        .task(id: results.top?.id) {
            artist = nil
            guard let top = results.top, top.kind == .artist, let bid = top.browseId else { return }
            artist = try? await InnerTube.shared.artist(bid)
        }
    }

    private var topSongsColumn: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Top Songs").font(.system(size: 22, weight: .bold))
            VStack(spacing: 2) {
                ForEach(topSongs) { item in
                    TrackRow(item: item, showAlbum: false) { player.play(item) }
                }
            }
        }
    }
}

/// Large top result: big artwork, name, details and actions over a soft tint.
struct TopResultHero: View {
    let item: MediaItem
    let artist: ArtistPage?
    @State private var hover = false
    private var player: PlayerController { .shared }
    private var model: AppModel { .shared }

    var body: some View {
        let round = item.kind == .artist
        VStack(alignment: .leading, spacing: 16) {
            Text("Top Result").font(.system(size: 22, weight: .bold))
            VStack(alignment: .leading, spacing: 18) {
                Artwork(url: (artist?.thumbnail ?? item.thumbnail).map { Thumbs.upscale($0, size: 600) },
                        cornerRadius: round ? 80 : 14, symbol: round ? "person.fill" : "music.note", size: 160)
                    .frame(width: 160, height: 160)
                    .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
                VStack(alignment: .leading, spacing: 5) {
                    Text(item.title).font(.system(size: 32, weight: .heavy)).lineLimit(2).minimumScaleFactor(0.7)
                    Text(artist?.subscribers.map { "Artist · \($0)" } ?? item.subtitle)
                        .font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary).lineLimit(1)
                }
                HStack(spacing: 10) {
                    Button { player.play(item) } label: { Label("Play", systemImage: "play.fill") }
                        .glassButton(prominent: true).controlSize(.large)
                    if round || item.kind.isCollection {
                        Button { player.play(item, shuffle: true) } label: { Label("Shuffle", systemImage: "shuffle") }
                            .glassButton().controlSize(.large)
                        Button { model.open(item) } label: { Label("Open", systemImage: "arrow.up.right") }
                            .glassButton().controlSize(.large)
                    } else {
                        Button { player.startRadio(item) } label: { Label("Radio", systemImage: "dot.radiowaves.left.and.right") }
                            .glassButton().controlSize(.large)
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardSurface(20)
            .scaleEffect(hover ? 1.005 : 1)
            .animation(.easeOut(duration: 0.2), value: hover)
            .onHover { hover = $0 }
            .contextMenu { ItemMenu(item: item) }
        }
    }
}

/// A song list that flows into two columns when there's room.
struct SongGrid: View {
    let title: String
    let strapline: String?
    let items: [MediaItem]
    let twoColumns: Bool
    private var player: PlayerController { .shared }
    private var model: AppModel { .shared }

    var body: some View {
        let rows = Array(items.prefix(twoColumns ? 10 : 6))
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                if let strapline { Text(strapline).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary) }
                Text(title).font(.system(size: 22, weight: .bold))
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 24, alignment: .top), count: twoColumns ? 2 : 1),
                      alignment: .leading, spacing: 2) {
                ForEach(rows) { item in
                    if item.videoId != nil {
                        TrackRow(item: item, showAlbum: false) {
                            let list = rows.compactMap(\.track)
                            player.play(tracks: list, startAt: list.firstIndex { $0.videoId == item.videoId } ?? 0)
                        }
                    } else {
                        CollectionRow(item: item)
                    }
                }
            }
        }
    }
}

/// Compact search capsule for filtering a list in place.
struct FilterField: View {
    @Binding var text: String
    var prompt = "Filter songs"
    @FocusState private var focused: Bool
    @State private var hover = false

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "line.3.horizontal.decrease")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(focused ? Color.accentColor : .secondary)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($focused)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 12))
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .transition(.opacity.combined(with: .scale(scale: 0.8)))
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 32)
        .background(Capsule().fill(Color.primary.opacity(focused ? 0.12 : (hover ? 0.1 : 0.07))))
        .overlay(Capsule().strokeBorder(focused ? Color.accentColor.opacity(0.55) : Color.primary.opacity(0.08), lineWidth: focused ? 1 : 0.6))
        .contentShape(Capsule())
        .onHover { hover = $0 }
        .onTapGesture { focused = true }
        .animation(.easeOut(duration: 0.15), value: focused)
        .animation(.easeOut(duration: 0.15), value: text.isEmpty)
    }
}

/// Mood/genre chips in one row that scrolls sideways (trackpad swipe or arrows).
struct ChipScroller: View {
    let chips: [Chip]
    let selected: String?
    let onTap: (Chip) -> Void
    @State private var pos: String?
    static let chipWidth: CGFloat = 128

    var body: some View {
        GeometryReader { g in
            let perPage = max(1, Int((g.size.width - 80) / (Self.chipWidth + 8)))
            let index = chips.firstIndex { $0.title == pos } ?? 0
            HStack(spacing: 10) {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(chips) { c in
                            Button(c.title) { onTap(c) }
                                .buttonStyle(ChipStyle(selected: selected == c.title, fill: true))
                                .frame(width: Self.chipWidth)
                                .id(c.title)
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollIndicators(.never)
                .scrollPosition(id: $pos, anchor: .leading)
                .scrollTargetBehavior(.viewAligned)
                // Soft fade where chips run off the edge.
                .mask(HStack(spacing: 0) {
                    LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing)
                        .frame(width: index > 0 ? 18 : 0)
                    Color.black
                    LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: index + perPage < chips.count ? 18 : 0)
                })
                HStack(spacing: 2) {
                    Button { scroll(to: max(0, index - perPage)) } label: { Image(systemName: "chevron.left") }
                        .disabled(index == 0)
                    Button { scroll(to: min(chips.count - 1, index + perPage)) } label: { Image(systemName: "chevron.right") }
                        .disabled(index + perPage >= chips.count)
                }
                .buttonStyle(BarIconStyle(size: 13))
            }
        }
        .frame(height: 34)
    }

    private func scroll(to i: Int) {
        withAnimation(.timingCurve(0.25, 0.1, 0.25, 1, duration: 0.45)) { pos = chips[i].title }
    }
}

/// High-contrast white pill (e.g. "Subscribe"): clearly different from the quiet
/// glass "Subscribed" state.
struct SolidPillStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.black)
            .padding(.horizontal, 16).padding(.vertical, 8)
            .background(Capsule().fill(.white.opacity(configuration.isPressed ? 0.8 : 0.95)))
            .contentShape(Capsule())
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.spring(duration: 0.2), value: configuration.isPressed)
    }
}
