import Foundation

struct ArtistRef: Hashable, Codable, Sendable {
    var name: String
    var browseId: String?
}

struct AlbumRef: Hashable, Codable, Sendable {
    var name: String
    var browseId: String?
}

enum ItemKind: String, Hashable, Codable, Sendable {
    case song, video, album, single, ep, playlist, artist, episode, podcast, mood, unknown

    var isPlayable: Bool { self == .song || self == .video || self == .episode }
    var isCollection: Bool { self == .album || self == .single || self == .ep || self == .playlist || self == .podcast }
}

/// Any item that can appear in a shelf, grid or list.
struct MediaItem: Identifiable, Hashable, Codable, Sendable {
    var id: String
    var kind: ItemKind
    var title: String
    var subtitle: String = ""
    var thumbnail: URL?
    var videoId: String?
    var playlistId: String?
    var browseId: String?
    var params: String?
    var artists: [ArtistRef] = []
    var album: AlbumRef?
    var duration: TimeInterval?
    var isExplicit: Bool = false
    /// Used to start a radio for collections / artists.
    var radioPlaylistId: String?
    var shufflePlaylistId: String?
    /// Playlist item id for edit_playlist removals.
    var setVideoId: String?
    /// Mood/genre tile colour (ARGB int) when present.
    var tileColor: UInt32?

    var artistLine: String {
        artists.isEmpty ? subtitle : artists.map(\.name).joined(separator: ", ")
    }

    var shareURL: URL? {
        if let v = videoId { return URL(string: "https://music.youtube.com/watch?v=\(v)") }
        if let p = playlistId { return URL(string: "https://music.youtube.com/playlist?list=\(p)") }
        if let b = browseId { return URL(string: "https://music.youtube.com/browse/\(b)") }
        return nil
    }

    var track: Track? {
        guard let v = videoId else { return nil }
        return Track(videoId: v, title: title, artists: artists, album: album,
                     thumbnail: thumbnail, duration: duration, isExplicit: isExplicit,
                     isVideo: kind == .video, setVideoId: setVideoId)
    }
}

/// A playable entry in the queue.
struct Track: Identifiable, Hashable, Codable, Sendable {
    var videoId: String
    var title: String
    var artists: [ArtistRef]
    var album: AlbumRef?
    var thumbnail: URL?
    var duration: TimeInterval?
    var isExplicit: Bool = false
    var isVideo: Bool = false
    var setVideoId: String?
    /// The "other half" of a song/video pair (ATV <-> OMV), if known.
    var counterpartVideoId: String?
    /// Unique per queue entry so the same song can appear twice.
    var uid: UUID = UUID()

    var id: UUID { uid }
    var artistLine: String { artists.map(\.name).joined(separator: ", ") }

    /// Highest-resolution thumbnail we can derive (YouTube image URLs encode size).
    var largeArtwork: URL? { thumbnail.map { Thumbs.upscale($0) } }

    func hash(into h: inout Hasher) { h.combine(uid) }
    static func == (a: Track, b: Track) -> Bool { a.uid == b.uid }
}

enum ShelfStyle: Hashable, Sendable {
    case cards          // horizontal carousel of square cards
    case quickPicks     // grid of compact song rows
    case list           // vertical list of songs
    case moods          // coloured mood/genre buttons
}

struct Shelf: Identifiable, Hashable, Sendable {
    var id = UUID()
    var title: String
    var strapline: String?
    var thumbnail: URL?
    var style: ShelfStyle
    var items: [MediaItem]
    var moreBrowseId: String?
    var moreParams: String?
}

struct CollectionPage: Sendable {
    var title: String
    var subtitle: String
    var secondSubtitle: String
    var description: String?
    var thumbnail: URL?
    var tracks: [MediaItem]
    var playlistId: String?
    var radioPlaylistId: String?
    var shufflePlaylistId: String?
    var isAlbum: Bool
    var artists: [ArtistRef]
    var continuation: String?
    var otherShelves: [Shelf] = []
    var isEditable: Bool = false
    var isSaved: Bool?
}

struct ArtistPage: Sendable {
    var name: String
    var description: String?
    var thumbnail: URL?
    var subscribers: String?
    var channelId: String?
    var isSubscribed: Bool
    var shufflePlaylistId: String?
    var radioPlaylistId: String?
    var shelves: [Shelf]
}

struct BrowsePage: Sendable {
    var title: String
    var shelves: [Shelf]
    var continuation: String?
    var chips: [Chip] = []
}

struct Chip: Hashable, Identifiable, Sendable {
    var id: String { title }
    var title: String
    var params: String?
    var browseId: String?
    var isSelected: Bool
}

struct SearchResults: Sendable {
    var top: MediaItem?
    var shelves: [Shelf]
    var items: [MediaItem]   // used for filtered searches
    var continuation: String?
}

struct WatchQueue: Sendable {
    var tracks: [Track]
    var lyricsBrowseId: String?
    var relatedBrowseId: String?
    var continuation: String?
    var playlistId: String?
}

enum LikeStatus: String, Sendable { case like = "LIKE", dislike = "DISLIKE", indifferent = "INDIFFERENT" }

enum Thumbs {
    /// Picks the largest thumbnail from a renderer's thumbnail list.
    static func best(_ json: JSON) -> URL? {
        var list = json.find("thumbnails").array
        if list.isEmpty { return nil }
        list.sort { ($0.width.double ?? 0) < ($1.width.double ?? 0) }
        guard var s = list.last?.url.string else { return nil }
        if s.hasPrefix("//") { s = "https:" + s }
        return URL(string: s)
    }

    /// Best URL for an image shown at `px` pixels: Google image servers resize on
    /// request, video thumbnails have an HD (1280×720) variant.
    static func sized(_ url: URL, px: Int) -> URL {
        let s = url.absoluteString
        if s.contains("googleusercontent.com") || s.contains("ggpht.com") { return upscale(url, size: max(px, 120)) }
        if s.contains("i.ytimg.com") || s.contains("img.youtube.com") {
            if px > 320, let r = s.range(of: #"/(default|mqdefault|hqdefault|sddefault)\.jpg"#, options: .regularExpression) {
                return URL(string: String(s[..<r.lowerBound]) + "/hq720.jpg") ?? url
            }
        }
        return url
    }

    /// Rewrites googleusercontent size suffixes (=w120-h120-...) to a large size.
    static func upscale(_ url: URL, size: Int = 1200) -> URL {
        let s = url.absoluteString
        if s.contains("googleusercontent.com") || s.contains("ggpht.com") {
            if let r = s.range(of: "=w\\d+-h\\d+", options: .regularExpression) {
                return URL(string: s.replacingCharacters(in: r, with: "=w\(size)-h\(size)")) ?? url
            }
            if let r = s.range(of: "=s\\d+", options: .regularExpression) {
                return URL(string: s.replacingCharacters(in: r, with: "=s\(size)")) ?? url
            }
        }
        if s.contains("i.ytimg.com") {
            // hqdefault always exists; maxres often 404s.
            for q in ["mqdefault", "default"] where s.contains("/\(q).jpg") {
                return URL(string: s.replacingOccurrences(of: "/\(q).jpg", with: "/hqdefault.jpg")
                    .components(separatedBy: "?").first ?? s) ?? url
            }
        }
        return url
    }
}

func parseDuration(_ s: String?) -> TimeInterval? {
    guard let s, !s.isEmpty else { return nil }
    let parts = s.split(separator: ":").compactMap { Double($0) }
    guard !parts.isEmpty, parts.count == s.split(separator: ":").count else { return nil }
    return parts.reduce(0) { $0 * 60 + $1 }
}

func formatTime(_ t: TimeInterval) -> String {
    guard t.isFinite, t >= 0 else { return "0:00" }
    let s = Int(t.rounded(.down))
    if s >= 3600 { return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60) }
    return String(format: "%d:%02d", s / 60, s % 60)
}
