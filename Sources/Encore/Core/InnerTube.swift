import Foundation
import CryptoKit

enum APIError: LocalizedError {
    case http(Int, String)
    case notSignedIn
    case parse(String)

    var errorDescription: String? {
        switch self {
        case .http(let c, let m): return "YouTube Music returned an error (\(c)). \(m)"
        case .notSignedIn: return "You're not signed in to YouTube Music."
        case .parse(let m): return "Couldn't read YouTube Music's response: \(m)"
        }
    }
}

/// Client for YouTube Music's internal "InnerTube" JSON API (the same one the
/// website uses). Requests are authenticated with the cookies of the signed-in
/// web view, so there is no separate login or API key.
@MainActor
final class InnerTube {
    static let shared = InnerTube()
    private let bridge = WebBridge.shared
    private let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.httpShouldSetCookies = false
        c.httpCookieAcceptPolicy = .never
        c.httpCookieStorage = nil
        // Personal API responses are never written to the on-disk HTTP cache.
        c.urlCache = nil
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.tlsMinimumSupportedProtocolVersion = .TLSv12
        c.timeoutIntervalForRequest = 20
        return URLSession(configuration: c)
    }()

    // MARK: Low level

    func post(_ endpoint: String, _ body: [String: Any]) async throws -> JSON {
        await bridge.waitUntilReady(timeout: 15)
        let info = bridge.client
        var ctx: [String: Any] = [
            "client": [
                "clientName": "WEB_REMIX",
                "clientVersion": info.clientVersion,
                "hl": info.hl,
                "gl": info.gl,
                "visitorData": info.visitorData ?? "",
                "userAgent": WebBridge.userAgent,
                "platform": "DESKTOP",
            ] as [String: Any],
            "user": ["lockedSafetyMode": false] as [String: Any],
        ]
        if let pid = info.pageId, var user = ctx["user"] as? [String: Any] {
            user["onBehalfOfUser"] = pid; ctx["user"] = user
        }
        var payload = body
        payload["context"] = ctx

        var req = URLRequest(url: URL(string: "\(WebBridge.origin)/youtubei/v1/\(endpoint)?prettyPrint=false")!)
        req.httpMethod = "POST"
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(WebBridge.origin, forHTTPHeaderField: "Origin")
        req.setValue(WebBridge.origin, forHTTPHeaderField: "X-Origin")
        req.setValue(WebBridge.origin + "/", forHTTPHeaderField: "Referer")
        req.setValue(WebBridge.userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("67", forHTTPHeaderField: "X-Youtube-Client-Name")
        req.setValue(info.clientVersion, forHTTPHeaderField: "X-Youtube-Client-Version")
        req.setValue("0", forHTTPHeaderField: "X-Goog-AuthUser")
        if let vd = info.visitorData { req.setValue(vd, forHTTPHeaderField: "X-Goog-Visitor-Id") }
        if let pid = info.pageId { req.setValue(pid, forHTTPHeaderField: "X-Goog-PageId") }

        let cookies = await bridge.cookies()
        if !cookies.isEmpty {
            // De-duplicate by name, preferring the youtube.com-scoped cookie.
            var byName: [String: HTTPCookie] = [:]
            for c in cookies where byName[c.name] == nil || c.domain == ".youtube.com" { byName[c.name] = c }
            req.setValue(byName.values.map { "\($0.name)=\($0.value)" }.joined(separator: "; "), forHTTPHeaderField: "Cookie")
            if let sapisid = byName["SAPISID"]?.value ?? byName["__Secure-3PAPISID"]?.value {
                req.setValue(Self.sapisidHash(sapisid), forHTTPHeaderField: "Authorization")
            }
        }

        let (data, resp) = try await session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            let msg = (try? JSON(data: data))?.error.message.string ?? ""
            throw APIError.http(code, msg)
        }
        return try JSON(data: data)
    }

    static func sapisidHash(_ sapisid: String) -> String {
        let ts = Int(Date().timeIntervalSince1970)
        let digest = Insecure.SHA1.hash(data: Data("\(ts) \(sapisid) \(WebBridge.origin)".utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "SAPISIDHASH \(ts)_\(hex)"
    }

    // MARK: Browse

    func browse(_ browseId: String, params: String? = nil) async throws -> JSON {
        var body: [String: Any] = ["browseId": browseId]
        if let params { body["params"] = params }
        return try await post("browse", body)
    }

    func browseContinuation(_ token: String) async throws -> JSON {
        try await post("browse", ["continuation": token])
    }

    func home() async throws -> BrowsePage { Parser.browsePage(try await browse("FEmusic_home")) }
    func homeChip(_ chip: Chip) async throws -> BrowsePage {
        Parser.browsePage(try await browse(chip.browseId ?? "FEmusic_home", params: chip.params))
    }
    func explore() async throws -> BrowsePage { Parser.browsePage(try await browse("FEmusic_explore")) }
    func moodsAndGenres() async throws -> BrowsePage { Parser.browsePage(try await browse("FEmusic_moods_and_genres")) }
    func charts() async throws -> BrowsePage { Parser.browsePage(try await browse("FEmusic_charts")) }
    func newReleases() async throws -> BrowsePage { Parser.browsePage(try await browse("FEmusic_new_releases")) }
    func genericPage(_ browseId: String, params: String?) async throws -> BrowsePage {
        Parser.browsePage(try await browse(browseId, params: params))
    }
    func continuation(_ token: String) async throws -> BrowsePage {
        Parser.browsePage(try await browseContinuation(token))
    }

    func collection(_ browseId: String) async throws -> CollectionPage {
        let id = browseId.hasPrefix("VL") || browseId.hasPrefix("MPRE") || browseId.hasPrefix("FE") || browseId.hasPrefix("MPSP")
            ? browseId : "VL" + browseId
        return Parser.collection(try await browse(id), browseId: id)
    }

    func collectionContinuation(_ token: String) async throws -> ([MediaItem], String?) {
        let j = try await browseContinuation(token)
        return Parser.listContinuation(j)
    }

    func artist(_ browseId: String) async throws -> ArtistPage {
        var id = browseId
        if id.hasPrefix("MPLA") { id = String(id.dropFirst(4)) }
        return Parser.artist(try await browse(id))
    }

    // MARK: Library

    enum LibrarySection: String, CaseIterable, Identifiable {
        case playlists = "Playlists", songs = "Songs", albums = "Albums", artists = "Artists",
             subscriptions = "Subscriptions", podcasts = "Podcasts", history = "History"
        var id: String { rawValue }
        var browseId: String {
            switch self {
            case .playlists: return "FEmusic_liked_playlists"
            case .songs: return "FEmusic_liked_videos"
            case .albums: return "FEmusic_liked_albums"
            case .artists: return "FEmusic_library_corpus_track_artists"
            case .subscriptions: return "FEmusic_library_corpus_artists"
            case .podcasts: return "FEmusic_library_non_music_audio_list"
            case .history: return "FEmusic_history"
            }
        }
        var symbol: String {
            switch self {
            case .playlists: return "music.note.list"
            case .songs: return "music.note"
            case .albums: return "square.stack"
            case .artists: return "music.mic"
            case .subscriptions: return "person.crop.circle.badge.checkmark"
            case .podcasts: return "mic"
            case .history: return "clock.arrow.circlepath"
            }
        }
    }

    func library(_ section: LibrarySection) async throws -> BrowsePage {
        Parser.browsePage(try await browse(section.browseId))
    }

    /// The user's playlists for the sidebar (excluding the "New playlist" tile).
    func libraryPlaylists() async throws -> [MediaItem] {
        let page = try await library(.playlists)
        return page.shelves.flatMap(\.items).filter { $0.browseId != nil || $0.playlistId != nil }
    }

    // MARK: Search

    func search(_ query: String, params: String? = nil) async throws -> SearchResults {
        var body: [String: Any] = ["query": query]
        if let params { body["params"] = params }
        return Parser.search(try await post("search", body))
    }

    func searchContinuation(_ token: String) async throws -> ([MediaItem], String?) {
        Parser.listContinuation(try await post("search", ["continuation": token]))
    }

    func suggestions(_ input: String) async throws -> ([String], [MediaItem]) {
        Parser.suggestions(try await post("music/get_search_suggestions", ["input": input]))
    }

    // MARK: Watch / queue

    func watchQueue(videoId: String?, playlistId: String?, params: String? = nil) async throws -> WatchQueue {
        var body: [String: Any] = [
            "enablePersistentPlaylistPanel": true,
            "isAudioOnly": true,
            "tunerSettingValue": "AUTOMIX_SETTING_NORMAL",
        ]
        if let videoId { body["videoId"] = videoId }
        if let playlistId { body["playlistId"] = playlistId }
        if let params { body["params"] = params }
        return Parser.watchQueue(try await post("next", body), playlistId: playlistId)
    }

    func watchContinuation(_ token: String, playlistId: String?) async throws -> WatchQueue {
        var body: [String: Any] = ["continuation": token, "enablePersistentPlaylistPanel": true, "isAudioOnly": true]
        if let playlistId { body["playlistId"] = playlistId }
        return Parser.watchQueue(try await post("next", body), playlistId: playlistId)
    }

    /// Like status of a track, read from the watch-next response.
    /// Track lengths for songs whose listing omits them (artist top songs, search
    /// rows). One `get_queue` request covers many videos.
    func durations(videoIds: [String]) async -> [String: TimeInterval] {
        guard !videoIds.isEmpty, let j = try? await post("music/get_queue", ["videoIds": videoIds]) else { return [:] }
        var out: [String: TimeInterval] = [:]
        for q in j.queueDatas.array {
            let c = q.content
            let r = c.playlistPanelVideoRenderer.exists ? c.playlistPanelVideoRenderer
                : c.playlistPanelVideoWrapperRenderer.primaryRenderer.playlistPanelVideoRenderer
            if let t = Parser.panelTrack(r), let d = t.duration { out[t.videoId] = d }
        }
        return out
    }

    func likeStatus(videoId: String) async -> LikeStatus? {
        guard let j = try? await post("next", ["videoId": videoId, "isAudioOnly": true]) else { return nil }
        return j.find("likeButtonRenderer").likeStatus.string.flatMap(LikeStatus.init(rawValue:))
    }

    func lyrics(browseId: String) async throws -> (text: String, source: String?)? {
        let j = try await browse(browseId)
        let shelf = j.find("musicDescriptionShelfRenderer")
        guard let text = shelf.description.text, !text.isEmpty else { return nil }
        return (text, shelf.footer.text)
    }

    // MARK: Actions

    func rate(videoId: String, _ status: LikeStatus) async throws {
        let ep: String
        switch status {
        case .like: ep = "like/like"
        case .dislike: ep = "like/dislike"
        case .indifferent: ep = "like/removelike"
        }
        _ = try await post(ep, ["target": ["videoId": videoId]])
    }

    func ratePlaylist(playlistId: String, saved: Bool) async throws {
        _ = try await post(saved ? "like/like" : "like/removelike", ["target": ["playlistId": playlistId]])
    }

    func subscribe(channelId: String, _ on: Bool) async throws {
        _ = try await post(on ? "subscription/subscribe" : "subscription/unsubscribe", ["channelIds": [channelId]])
    }

    func createPlaylist(title: String, description: String = "", privacy: String = "PRIVATE", videoIds: [String] = []) async throws -> String? {
        let j = try await post("playlist/create", ["title": title, "description": description,
                                                   "privacyStatus": privacy, "videoIds": videoIds])
        return j.playlistId.string
    }

    func addToPlaylist(playlistId: String, videoIds: [String]) async throws {
        let pid = playlistId.hasPrefix("VL") ? String(playlistId.dropFirst(2)) : playlistId
        let actions = videoIds.map { ["action": "ACTION_ADD_VIDEO", "addedVideoId": $0, "dedupeOption": "DEDUPE_OPTION_SKIP"] }
        _ = try await post("browse/edit_playlist", ["playlistId": pid, "actions": actions])
    }

    func removeFromPlaylist(playlistId: String, videoId: String, setVideoId: String) async throws {
        let pid = playlistId.hasPrefix("VL") ? String(playlistId.dropFirst(2)) : playlistId
        _ = try await post("browse/edit_playlist", ["playlistId": pid, "actions": [
            ["action": "ACTION_REMOVE_VIDEO", "setVideoId": setVideoId, "removedVideoId": videoId]]])
    }

    func deletePlaylist(playlistId: String) async throws {
        let pid = playlistId.hasPrefix("VL") ? String(playlistId.dropFirst(2)) : playlistId
        _ = try await post("playlist/delete", ["playlistId": pid])
    }

    /// Fetches account name + avatar from the account menu.
    func accountInfo() async -> (name: String, handle: String?, avatar: URL?)? {
        guard let j = try? await post("account/account_menu", [:]) else { return nil }
        let h = j.find("activeAccountHeaderRenderer")
        guard let name = h.accountName.text else { return nil }
        return (name, h.channelHandle.text, Thumbs.best(h.accountPhoto))
    }
}
