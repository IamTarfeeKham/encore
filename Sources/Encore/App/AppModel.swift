import SwiftUI
import AppKit

enum SidebarItem: Hashable {
    case home, explore, charts, moods, newReleases
    case search
    case liked
    case library(InnerTube.LibrarySection)
    case playlist(String, String)   // browseId, title
    case pinned(Route, String)      // route, pinned item id
    case settings
}

enum Route: Hashable {
    case collection(String)               // album / playlist browseId
    case artist(String)
    case browse(String, String?, String)  // browseId, params, title
}

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    @Published var selection: SidebarItem = .home {
        didSet { if oldValue != selection { path = []; forward = [] } }
    }
    @Published var path: [Route] = []
    @Published var forward: [Route] = []
    @Published var focusSearch = false
    /// Lives in its own small object (SidebarState) so toggling it only refreshes the
    /// few views that show it, not every view watching the app model.
    var sidebarVisible: Bool {
        get { SidebarState.shared.visible }
        set { SidebarState.shared.visible = newValue }
    }
    @Published var editingSidebar = false
    @Published var settingsSection: SettingsView.Section = .appearance
    @Published var showNowPlaying = false
    @Published var showQueue = false
    @Published var searchText = ""
    @Published var submittedSearch = ""
    @Published var playlists: [MediaItem] = []
    @Published var account: (name: String, handle: String?, avatar: URL?)?
    @Published var signedIn: Bool?
    @Published var showSignIn = false
    @Published var toast: String?
    @Published var newPlaylistFor: [String]? = nil   // video ids to add to a new playlist

    private let api = InnerTube.shared

    func refreshAccount() async {
        await WebBridge.shared.waitUntilReady(timeout: 25)
        let cookies = await WebBridge.shared.hasAuthCookies()
        signedIn = WebBridge.shared.isSignedIn || cookies
        guard signedIn == true else { playlists = []; account = nil; return }
        async let acc = api.accountInfo()
        async let pls = try? api.libraryPlaylists()
        account = await acc
        if let p = await pls { playlists = p.filter { $0.browseId != "VLLM" } }
    }

    func refreshPlaylists() {
        Task { if let p = try? await api.libraryPlaylists() { playlists = p.filter { $0.browseId != "VLLM" } } }
    }

    func open(_ item: MediaItem) {
        switch item.kind {
        case .artist:
            if let b = item.browseId { push(.artist(b)) }
        case .album, .single, .ep, .playlist, .podcast:
            if let b = item.browseId ?? item.playlistId.map({ "VL" + $0 }) { push(.collection(b)) }
        case .mood:
            if let b = item.browseId { push(.browse(b, item.params, item.title)) }
        case .song, .video, .episode:
            PlayerController.shared.play(item)
        case .unknown:
            if let b = item.browseId { push(.browse(b, item.params, item.title)) }
        }
    }

    /// Every page in the Back history keeps its content in memory, so a long session
    /// of clicking through albums and artists would grow without limit. Keep the most
    /// recent ones (trimmed in batches, so this rarely happens).
    static let historyLimit = 20

    func push(_ r: Route) {
        showNowPlaying = false
        forward = []
        path.append(r)
        if path.count > Self.historyLimit + 5 { path.removeFirst(path.count - Self.historyLimit) }
    }

    /// Bumped by the Refresh button; pages reload when it changes.
    @Published var refreshToken = 0
    func refresh() { refreshToken += 1; refreshPlaylists() }
    func goHome() { showNowPlaying = false; selection = .home; path = []; forward = [] }

    var canGoBack: Bool { !path.isEmpty }
    var canGoForward: Bool { !forward.isEmpty }
    func goBack() { if let r = path.popLast() { forward.append(r) } }
    func goForward() { if let r = forward.popLast() { path.append(r) } }

    /// Opens a sidebar entry (built-in page or pinned item).
    func open(entry: SidebarEntry) {
        showNowPlaying = false
        if let key = entry.builtin, let b = BuiltinDestination.find(key) { selection = b.item; return }
        guard let item = entry.item else { return }
        switch item.kind {
        case .artist: selection = .pinned(.artist(item.browseId ?? item.id), item.id)
        case .mood, .unknown: selection = .pinned(.browse(item.browseId ?? item.id, item.params, item.title), item.id)
        default: selection = .pinned(.collection(item.browseId ?? ("VL" + (item.playlistId ?? ""))), item.id)
        }
    }

    func openArtist(_ a: ArtistRef) { if let b = a.browseId { push(.artist(b)) } }
    func openAlbum(_ a: AlbumRef) { if let b = a.browseId { push(.collection(b)) } }

    func flash(_ message: String) {
        toast = message
        Task {
            try? await Task.sleep(nanoseconds: 2_200_000_000)
            if toast == message { toast = nil }
        }
    }

    func addToPlaylist(_ playlist: MediaItem, videoIds: [String]) {
        guard let pid = playlist.playlistId ?? playlist.browseId else { return }
        Task {
            do {
                try await api.addToPlaylist(playlistId: pid, videoIds: videoIds)
                flash("Added to \(playlist.title)")
            } catch { flash(error.localizedDescription) }
        }
    }

    func createPlaylist(title: String, privacy: String, videoIds: [String]) {
        Task {
            do {
                _ = try await api.createPlaylist(title: title, privacy: privacy, videoIds: videoIds)
                flash("Created \(title)")
                try? await Task.sleep(nanoseconds: 800_000_000)
                refreshPlaylists()
            } catch { flash(error.localizedDescription) }
        }
    }

    func copyLink(_ url: URL?) {
        guard let url else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
        flash("Link copied")
    }
}

extension Notification.Name {
    /// Posted just before the page's width starts animating (sidebar shown or hidden).
    static let pageWidthWillAnimate = Notification.Name("pageWidthWillAnimate")
}

@MainActor
final class SidebarState: ObservableObject {
    static let shared = SidebarState()
    @Published var visible = true {
        // Lets wide pages (the feed) get ready before the width animation's first frame.
        willSet { if newValue != visible { NotificationCenter.default.post(name: .pageWidthWillAnimate, object: nil) } }
    }
}
