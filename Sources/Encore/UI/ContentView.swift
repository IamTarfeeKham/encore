import SwiftUI

struct ContentView: View {
    @EnvironmentObject var player: PlayerController
    @EnvironmentObject var model: AppModel
    @ObservedObject private var search = SearchController.shared
    @Environment(\.openWindow) private var openWindow

    static let panelGap: CGFloat = 10
    static let topBarHeight: CGFloat = 52

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottom) {
                AmbientBackground(artwork: player.current?.largeArtwork, dim: 0.46)

                // Pages run the full height of the window and scroll underneath the
                // floating glass top bar and player bar, so the glass shows them through it.
                HStack(spacing: Self.panelGap) {
                    if model.sidebarVisible {
                        ResizableSidebar()
                            .padding(.top, Self.topBarHeight + 6)
                            .padding(.bottom, PlayerBar.height + Self.panelGap * 2)
                            .transition(.move(edge: .leading))
                    }
                    DetailPane()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        // Content fades out softly as it scrolls up under the top bar (no band, no border).
                        .mask {
                            VStack(spacing: 0) {
                                Color.clear.frame(height: Self.topBarHeight - 8)
                                LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                                    .frame(height: 26)
                                Color.black
                            }
                        }
                    if model.showQueue && !model.showNowPlaying {
                        // Hugs its content (a short queue gets a short panel), up to the space available.
                        QueueView(maxHeight: geo.size.height - (Self.topBarHeight + 6) - (PlayerBar.height + Self.panelGap * 2))
                            .frame(width: 320)
                            .glassPanel(20)
                            .padding(.top, Self.topBarHeight + 6)
                            .padding(.bottom, PlayerBar.height + Self.panelGap * 2)
                            .frame(maxHeight: .infinity, alignment: .top)
                            .transition(.move(edge: .trailing))
                    }
                }
                .padding(.horizontal, Self.panelGap)

                VStack {
                    TopBar()
                        .frame(height: Self.topBarHeight)
                    Spacer()
                }
                .zIndex(0.3)

                // Video mode: the song's artwork glow behind a 16:9 video with soft
                // corners and a shadow, rather than a black box.
                let showVideo = model.showNowPlaying && player.videoMode
                AmbientBackground(artwork: player.current?.largeArtwork, dim: 0.5, parallax: 0.6)
                    .opacity(showVideo ? 1 : 0)
                    .allowsHitTesting(false)
                    .zIndex(0.4)
                // Music-video surface: always mounted (so the player never moves).
                VideoHost()
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .shadow(color: .black.opacity(0.55), radius: 40, y: 18)
                    .padding(.horizontal, 48).padding(.top, 70)
                    .padding(.bottom, PlayerBar.height + 40)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .opacity(showVideo ? 1 : 0)
                    .scaleEffect(showVideo ? 1 : 0.96)
                    .allowsHitTesting(false)
                    .animation(.easeInOut(duration: 0.4), value: showVideo)
                    .zIndex(0.5)

                if model.showNowPlaying {
                    NowPlayingView()
                        .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity),
                                                removal: .move(edge: .bottom).combined(with: .opacity)))
                        .zIndex(1)
                }

                // With Now Playing open, the queue floats above it on the right
                // (it used to open underneath, hidden).
                if model.showNowPlaying && model.showQueue {
                    HStack {
                        Spacer(minLength: 0)
                        QueueView(maxHeight: geo.size.height - (Self.topBarHeight + 6) - (PlayerBar.height + Self.panelGap * 2))
                            .frame(width: 320)
                            .glassPanel(20)
                            .shadow(color: .black.opacity(0.35), radius: 24, y: 10)
                            .padding(.top, Self.topBarHeight + 6)
                            .padding(.bottom, PlayerBar.height + Self.panelGap * 2)
                            .frame(maxHeight: .infinity, alignment: .top)
                    }
                    .padding(.horizontal, Self.panelGap)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                    .zIndex(1.5)
                }

                PlayerBar()
                    .padding(.horizontal, Self.panelGap)
                    .padding(.bottom, Self.panelGap)
                    .zIndex(2)

                if search.visible {
                    // Click anywhere else to dismiss.
                    Color.black.opacity(0.001)
                        .onTapGesture { search.visible = false }
                        .zIndex(4)
                    let field = search.fieldFrame
                    VStack(alignment: .leading) {
                        SearchPanel()
                            .frame(width: max(360, field.width))
                            .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, field.width > 0 ? field.minX : 0)
                    .padding(.top, Self.topBarHeight - 2)
                    .zIndex(5)
                }

                if let toast = model.toast {
                    Text(toast)
                        .font(.system(size: 13, weight: .medium))
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .glassPanel(20)
                        .padding(.bottom, PlayerBar.height + 26)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .zIndex(3)
                }
            }
            .onContinuousHover(coordinateSpace: .local) { phase in
                if case .active(let p) = phase { PointerTracker.shared.update(p, in: geo.size) }
            }
        }
        .ignoresSafeArea()
        .background(WindowConfigurator())
        // Calm ease rather than a spring: no overshoot, so the page doesn't wobble as it resizes.
        .animation(.easeInOut(duration: 0.3), value: model.sidebarVisible)
        .animation(.easeInOut(duration: 0.3), value: model.showQueue)
        .animation(.spring(duration: 0.35), value: model.toast)
        .onReceive(NotificationCenter.default.publisher(for: .openMiniPlayer)) { _ in openWindow(id: "mini") }
        .onAppear { WindowOpener.open = openWindow }
        .animation(.spring(duration: 0.25, bounce: 0.15), value: search.visible)
        .sheet(isPresented: $model.showSignIn) { SignInView().appAccent() }
        .sheet(isPresented: $model.editingSidebar) { EditSidebarView().appAccent() }
        .sheet(isPresented: Binding(get: { model.newPlaylistFor != nil }, set: { if !$0 { model.newPlaylistFor = nil } })) {
            NewPlaylistSheet(videoIds: model.newPlaylistFor ?? []).appAccent()
        }
        .overlay {
            if model.signedIn == false && !model.showSignIn { SignInPrompt() }
        }
    }
}

// MARK: - Detail area

struct DetailPane: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            NavigationStack(path: $model.path) {
                // Pages are transparent (the artwork background shows through), so a
                // page under a pushed one would show through it. Only the top page is
                // drawn or hit-tested.
                root
                    .id(model.refreshToken)
                    .opacity(model.path.isEmpty ? 1 : 0)
                    .allowsHitTesting(model.path.isEmpty)
                    .navigationDestination(for: Route.self) { route in
                        let top = model.path.last == route
                        page(for: route)
                            .opacity(top ? 1 : 0)
                            .allowsHitTesting(top)
                            .toolbar(.hidden, for: .windowToolbar)
                    }
                    .toolbar(.hidden, for: .windowToolbar)
            }
            .scrollContentBackground(.hidden)
            // Scroll bars appear only while scrolling (thin overlay style), never a boxed track.
            .scrollIndicators(.never)
        }
    }

    @ViewBuilder func page(for route: Route) -> some View {
        switch route {
        case .collection(let id): CollectionView(browseId: id)
        case .artist(let id): ArtistView(browseId: id)
        case .browse(let id, let params, let title): BrowseView(title: title, browseId: id, params: params)
        }
    }

    @ViewBuilder private var root: some View {
        switch model.selection {
        case .home: HomeView().id("home")
        case .explore:
            ShelvesPage(title: "Explore", id: "explore", loader: { _ in try await InnerTube.shared.explore() })
        case .charts:
            ShelvesPage(title: "Charts", id: "charts", loader: { _ in try await InnerTube.shared.charts() })
        case .moods:
            ShelvesPage(title: "Moods & Genres", id: "moods", loader: { _ in try await InnerTube.shared.moodsAndGenres() })
        case .newReleases:
            ShelvesPage(title: "New Releases", id: "new", loader: { _ in try await InnerTube.shared.newReleases() })
        case .search: SearchView(query: model.submittedSearch)
        case .liked: CollectionView(browseId: "VLLM").id("liked")
        case .library(let s): LibraryView(section: s).id(s.rawValue)
        case .playlist(let id, _): CollectionView(browseId: id).id(id)
        case .pinned(let route, let id): page(for: route).id(id)
        case .settings: SettingsView()
        }
    }
}

// MARK: - Sidebar

/// The sidebar's natural content height, reported up to ResizableSidebar.
struct SidebarContentHeight: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

struct SidebarView: View {
    /// Height of the "Customise" bar under the list.
    static let footerHeight: CGFloat = 40
    @EnvironmentObject var model: AppModel
    @StateObject private var store = SidebarStore.shared

    var body: some View {
        Group {
            if model.selection == .settings {
                SettingsSidebar()
            } else {
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 2) {
                        if !model.submittedSearch.isEmpty {
                            SidebarRow(title: "Search Results", symbol: "magnifyingglass", selected: model.selection == .search) {
                                model.showNowPlaying = false; model.selection = .search
                            }
                        }
                        ForEach(store.config.sectionOrder) { section in sectionView(section) }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 10)
                    // Natural height (+ the Customise bar below) so the panel can hug it.
                    .background(GeometryReader { g in
                        Color.clear.preference(key: SidebarContentHeight.self, value: g.size.height + SidebarView.footerHeight)
                    })
                }
                .safeAreaInset(edge: .bottom) {
                    HStack {
                        Button { model.editingSidebar = true } label: {
                            Label("Customise", systemImage: "slider.horizontal.3").font(.system(size: 12, weight: .medium))
                        }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                        .hoverTip("Show, hide and reorder sidebar items")
                        Spacer()
                    }
                    .padding(.horizontal, 18).padding(.vertical, 10)
                }
            }
        }
        .animation(.easeInOut(duration: 0.25), value: model.selection == .settings)
    }

    @ViewBuilder private func sectionView(_ section: SidebarSection) -> some View {
        let collapsed = store.config.collapsed.contains(section)
        let entries = store.entries(section).filter { !$0.hidden }
        let playlists = model.playlists.filter { !store.config.hiddenPlaylists.contains($0.id) }
        let hasContent = section == .playlists ? !playlists.isEmpty || true : !entries.isEmpty
        if hasContent {
            HStack {
                Text(section.rawValue).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                if section == .playlists {
                    Button { model.newPlaylistFor = [] } label: { Image(systemName: "plus") }
                        .buttonStyle(.plain).foregroundStyle(.secondary).help("New Playlist")
                }
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold)).foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(collapsed ? -90 : 0))
            }
            .padding(.horizontal, 8).padding(.top, 14).padding(.bottom, 4)
            .contentShape(Rectangle())
            .onTapGesture { withAnimation(.spring(duration: 0.3)) { store.toggleCollapsed(section) } }
            .contextMenu { Button("Edit Sidebar…") { model.editingSidebar = true } }

            if !collapsed {
                if section == .playlists {
                    ForEach(playlists) { pl in
                        let route = SidebarItem.playlist(pl.browseId ?? "VL" + (pl.playlistId ?? ""), pl.title)
                        SidebarRow(title: pl.title, artwork: pl.thumbnail, selected: model.selection == route) {
                            model.showNowPlaying = false; model.selection = route
                        }
                        .contextMenu {
                            ItemMenu(item: pl)
                            Divider()
                            Button("Hide from Sidebar") { store.config.hiddenPlaylists.insert(pl.id) }
                        }
                    }
                } else {
                    ForEach(entries) { e in
                        row(e, section: section)
                    }
                }
            }
        }
    }

    @ViewBuilder private func row(_ e: SidebarEntry, section: SidebarSection) -> some View {
        if let key = e.builtin, let b = BuiltinDestination.find(key) {
            SidebarRow(title: b.title, symbol: b.symbol, selected: model.selection == b.item) { model.open(entry: e) }
                .contextMenu { entryMenu(e, section: section) }
        } else if let item = e.item {
            SidebarRow(title: item.title, artwork: item.thumbnail, round: item.kind == .artist,
                       selected: { if case .pinned(_, let id) = model.selection { return id == item.id }; return false }()) {
                model.open(entry: e)
            }
            .contextMenu {
                ItemMenu(item: item)
                Divider()
                entryMenu(e, section: section)
            }
        }
    }

    @ViewBuilder private func entryMenu(_ e: SidebarEntry, section: SidebarSection) -> some View {
        Button("Move Up") { withAnimation { store.moveEntry(e.id, in: section, by: -1) } }
        Button("Move Down") { withAnimation { store.moveEntry(e.id, in: section, by: 1) } }
        if section == .pinned {
            Button("Remove from Sidebar") { withAnimation { store.unpin(e.id) } }
        } else {
            Button("Hide") { withAnimation { store.setHidden(e.id, in: section, true) } }
        }
        Divider()
        Button("Edit Sidebar…") { model.editingSidebar = true }
    }
}

struct SidebarRow: View {
    let title: String
    var symbol: String? = nil
    var artwork: URL? = nil
    var round = false
    /// Taller rows with more breathing room (Settings has few entries).
    var roomy = false
    let selected: Bool
    let action: () -> Void
    @State private var hover = false
    @State private var pressed = false

    var body: some View {
        HStack(spacing: roomy ? 12 : 10) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: roomy ? 14 : 13, weight: .medium))
                    .frame(width: 20)
                    .foregroundStyle(selected ? Color.accentColor : .primary.opacity(0.8))
            } else {
                Artwork(url: artwork, cornerRadius: round ? 10 : 4, size: 20).frame(width: 20, height: 20)
            }
            Text(title).font(.system(size: roomy ? 13.5 : 13, weight: selected ? .semibold : .regular)).lineLimit(1).minimumScaleFactor(0.85)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, roomy ? 10 : 8).padding(.vertical, roomy ? 9 : 6)
        .background {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(selected ? Color.primary.opacity(0.15) : (pressed ? Color.primary.opacity(0.12) : (hover ? Color.primary.opacity(0.07) : .clear)))
        }
        .scaleEffect(pressed ? 0.97 : 1)
        .animation(.spring(duration: 0.18, bounce: 0.3), value: pressed)
        .animation(.easeOut(duration: 0.12), value: hover)
        .animation(.easeOut(duration: 0.15), value: selected)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        // Fires on mouse-down → acts on the first click, with press feedback.
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { _ in if !pressed { pressed = true } }
            .onEnded { v in
                pressed = false
                if abs(v.translation.width) < 6 && abs(v.translation.height) < 6 { action() }
            })
    }
}

// MARK: - Edit Sidebar

/// Sidebar editor: System Settings–style rows with coloured icons, a short
/// description for each page, show/hide switches and drag-to-reorder.
struct EditSidebarView: View {
    @EnvironmentObject var model: AppModel
    @StateObject private var store = SidebarStore.shared
    @Environment(\.dismiss) var dismiss
    @State private var tab: Tab = .pages

    enum Tab: String, CaseIterable, Identifiable {
        case pages = "Pages", pinned = "Pinned", playlists = "Playlists", order = "Section Order"
        var id: String { rawValue }
    }

    static let descriptions: [String: String] = [
        "home": "Your personalised mixes, Speed Dial and recommendations",
        "explore": "New albums, trending songs and music videos",
        "charts": "Top songs, videos and artists by country",
        "moods": "Playlists for every mood, activity and genre",
        "new": "The latest albums and singles",
        "liked": "Every song you've given a thumbs up",
        "lib.Playlists": "Playlists you made or saved",
        "lib.Songs": "Songs saved to your library",
        "lib.Albums": "Albums saved to your library",
        "lib.Artists": "Artists in your library",
        "lib.Subscriptions": "Artists and channels you subscribe to",
        "lib.Podcasts": "Shows you follow",
        "lib.History": "Everything you've played recently",
    ]
    static let colors: [String: Color] = [
        "home": .pink, "explore": .orange, "charts": .green, "moods": .purple, "new": .yellow,
        "liked": .red, "lib.Playlists": .blue, "lib.Songs": .pink, "lib.Albums": .indigo,
        "lib.Artists": .teal, "lib.Subscriptions": .mint, "lib.Podcasts": .brown, "lib.History": .gray,
    ]

    var body: some View {
        ZStack {
            // Same living artwork background as the main window, a bit darker.
            AmbientBackground(artwork: PlayerController.shared.current?.largeArtwork, dim: 0.62, parallax: 0.5)
            VStack(spacing: 0) {
                HStack(alignment: .center, spacing: 14) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Customise Sidebar").font(.system(size: 22, weight: .bold))
                        Text("Show, hide and reorder what's in your sidebar.")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .buttonStyle(BarIconStyle(size: 12))
                        .glassPanel(17, interactive: true)
                        .keyboardShortcut(.cancelAction)
                }
                .padding(.horizontal, 24).padding(.top, 24).padding(.bottom, 16)

                PillPicker(selection: $tab, options: [(.pages, "Pages", "square.grid.2x2"), (.pinned, "Pinned", "pin"),
                                                      (.playlists, "Playlists", "music.note.list"), (.order, "Order", "arrow.up.arrow.down")])
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 24).padding(.bottom, 12)

                List {
                    switch tab {
                    case .pages:
                        ForEach([SidebarSection.music, .library]) { section in
                            Section {
                                sectionHeader(section.rawValue)
                                ForEach(store.entries(section)) { e in builtinRow(e, section: section).editRow() }
                                    .onMove { store.move(section, from: $0, to: $1) }
                            }
                        }
                    case .pinned:
                        Section {
                            sectionHeader("Pinned")
                            if store.entries(.pinned).isEmpty {
                                emptyState("pin", "Nothing pinned yet",
                                           "Right-click any album, playlist, artist or mood and choose “Pin to Sidebar”.").editRow()
                            }
                            ForEach(store.entries(.pinned)) { e in
                                if let item = e.item {
                                    HStack(spacing: 12) {
                                        Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary)
                                        Artwork(url: item.thumbnail, cornerRadius: item.kind == .artist ? 16 : 7, size: 32).frame(width: 32, height: 32)
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(item.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                                            Text(item.kind.rawValue.capitalized).font(.system(size: 11)).foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        Button { withAnimation { store.unpin(e.id) } } label: { Image(systemName: "minus") }
                                            .buttonStyle(BarIconStyle(size: 11)).help("Unpin")
                                    }
                                    .editRow()
                                }
                            }
                            .onMove { store.move(.pinned, from: $0, to: $1) }
                        }
                    case .playlists:
                        Section {
                            sectionHeader("Show in sidebar")
                            if model.playlists.isEmpty { emptyState("music.note.list", "No playlists", "Playlists from your library appear here.").editRow() }
                            ForEach(model.playlists) { pl in
                                HStack(spacing: 12) {
                                    Artwork(url: pl.thumbnail, cornerRadius: 7, size: 32).frame(width: 32, height: 32)
                                    Text(pl.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                                    Spacer()
                                    Toggle("", isOn: Binding(get: { !store.config.hiddenPlaylists.contains(pl.id) },
                                                             set: { if $0 { store.config.hiddenPlaylists.remove(pl.id) } else { store.config.hiddenPlaylists.insert(pl.id) } }))
                                        .labelsHidden().toggleStyle(.switch).controlSize(.small)
                                }
                                .editRow()
                            }
                        }
                    case .order:
                        Section {
                            sectionHeader("Drag to reorder sections")
                            ForEach(store.config.sectionOrder) { s in
                                HStack(spacing: 12) {
                                    Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary)
                                    Text(s.rawValue).font(.system(size: 13, weight: .semibold))
                                    Spacer()
                                    Text(sectionHint(s)).font(.system(size: 11)).foregroundStyle(.secondary)
                                }
                                .editRow()
                            }
                            .onMove { store.moveSection(from: $0, to: $1) }
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .environment(\.defaultMinListRowHeight, 1)
                .padding(.horizontal, 12)

                HStack {
                    Button { withAnimation { store.reset() } } label: { Label("Reset to Default", systemImage: "arrow.counterclockwise") }
                        .buttonStyle(.plain).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                    Spacer()
                    Button { dismiss() } label: { Text("Done").frame(width: 70) }
                        .glassButton(prominent: true).controlSize(.large)
                        .keyboardShortcut(.defaultAction)
                }
                .padding(.horizontal, 24).padding(.vertical, 16)
            }
        }
        .environment(\.colorScheme, .dark)
        // Never taller than the window it's attached to.
        .frame(width: 580, height: max(420, min(680, (NSApp.mainWindow?.frame.height ?? 800) - 50)))
    }

    /// Section label as a plain row (system section headers draw a grey strip).
    private func sectionHeader(_ t: String) -> some View {
        Text(t.uppercased()).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            .padding(.leading, 8).padding(.top, 10).padding(.bottom, 2)
            .listRowInsets(EdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 12))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }

    @ViewBuilder private func builtinRow(_ e: SidebarEntry, section: SidebarSection) -> some View {
        if let key = e.builtin, let b = BuiltinDestination.find(key) {
            HStack(spacing: 12) {
                Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary)
                Image(systemName: b.symbol)
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(.secondary)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text(b.title).font(.system(size: 13, weight: .semibold))
                    Text(Self.descriptions[key] ?? "").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("", isOn: Binding(get: { !e.hidden }, set: { v in withAnimation { store.setHidden(e.id, in: section, !v) } }))
                    .labelsHidden().toggleStyle(.switch).controlSize(.small)
            }
            .opacity(e.hidden ? 0.5 : 1)
        }
    }

    private func sectionHint(_ s: SidebarSection) -> String {
        switch s {
        case .music: return "Home, Explore, Charts…"
        case .library: return "Liked Music, Albums…"
        case .pinned: return "Your pinned items"
        case .playlists: return "Your playlists"
        }
    }

    private func emptyState(_ symbol: String, _ title: String, _ detail: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 26)).foregroundStyle(.secondary)
            Text(title).font(.system(size: 13, weight: .semibold))
            Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 24)
    }
}

extension View {
    /// A row in the sidebar editor: glassy card on the app's background.
    func editRow() -> some View {
        self.padding(.horizontal, 4).padding(.vertical, 10)
            .overlay(alignment: .bottom) { Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 0.5) }
            .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }
}

struct NewPlaylistSheet: View {
    let videoIds: [String]
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    @State private var title = ""
    @State private var privacy = "PRIVATE"

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Playlist").font(.title2.bold())
            TextField("Title", text: $title).textFieldStyle(.roundedBorder)
            PillPicker(selection: $privacy, options: [("PRIVATE", "Private", "lock.fill"), ("UNLISTED", "Unlisted", "link"), ("PUBLIC", "Public", "globe")])
            if !videoIds.isEmpty { Text("\(videoIds.count) song\(videoIds.count == 1 ? "" : "s") will be added.").foregroundStyle(.secondary) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Create") {
                    model.createPlaylist(title: title, privacy: privacy, videoIds: videoIds)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 380)
    }
}


/// The sidebar panel with drag handles: right edge sets the width, bottom edge
/// the height. Sizes are remembered.
struct ResizableSidebar: View {
    // Width: dragged by the user. Read once; NOT observed. The live width is local
    // state while dragging and the preference is written once when the drag ends
    // (writing Prefs on every drag event re-rendered every glass panel: lag).
    // Height: follows the sidebar's content, up to the space available.
    @State private var width: Double = Prefs.shared.sidebarWidth
    @State private var startWidth: Double?
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        GeometryReader { g in
            let height = contentHeight > 0 ? min(g.size.height, max(160, contentHeight)) : g.size.height
            SidebarView()
                .frame(width: width, height: height)
                .glassPanel(20)
                .overlay(alignment: .trailing) {
                    ResizeHandle(cursor: .resizeLeftRight)
                        .frame(width: 18)
                        .offset(x: 9)
                        .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { v in
                                if startWidth == nil { startWidth = width }
                                var t = Transaction(); t.disablesAnimations = true
                                withTransaction(t) { width = min(380, max(190, (startWidth ?? 236) + v.translation.width)) }
                            }
                            .onEnded { _ in startWidth = nil; Prefs.shared.sidebarWidth = width })
                }
                .animation(.easeInOut(duration: 0.25), value: height)
        }
        .frame(width: width)
        .onPreferenceChange(SidebarContentHeight.self) { h in
            if abs(h - contentHeight) > 0.5 { contentHeight = h }
        }
    }
}

/// Generous drag strip that shows a resize cursor and a subtle grip line on hover.
struct ResizeHandle: View {
    let cursor: NSCursor
    @State private var hover = false
    var body: some View {
        ZStack {
            Color.clear
            Capsule()
                .fill(Color.primary.opacity(hover ? 0.35 : 0))
                .frame(width: cursor == .resizeUpDown ? 44 : 3, height: cursor == .resizeUpDown ? 3 : 44)
        }
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            switch phase {
            case .active: if !hover { withAnimation(.easeOut(duration: 0.15)) { hover = true } }; cursor.set()
            case .ended: withAnimation(.easeOut(duration: 0.2)) { hover = false }; NSCursor.arrow.set()
            }
        }
    }
}
