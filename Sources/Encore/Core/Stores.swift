import Foundation
import SwiftUI

/// Small JSON-in-UserDefaults persistence helper.
enum Persist {
    static func load<T: Decodable>(_ key: String, as: T.Type) -> T? {
        guard let d = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: d)
    }
    static func save<T: Encodable>(_ value: T, _ key: String) {
        if let d = try? JSONEncoder().encode(value) { UserDefaults.standard.set(d, forKey: key) }
    }
}

// MARK: - Sidebar customisation

enum SidebarSection: String, Codable, CaseIterable, Identifiable {
    case music = "Music", library = "Library", pinned = "Pinned", playlists = "Playlists"
    var id: String { rawValue }
}

/// One row in the sidebar: a built-in destination or something the user pinned.
struct SidebarEntry: Codable, Identifiable, Hashable {
    var id: String
    var builtin: String?          // key of a built-in destination
    var item: MediaItem?          // pinned album / playlist / artist / mood
    var hidden = false

    static func builtinEntry(_ key: String) -> SidebarEntry { SidebarEntry(id: "b:" + key, builtin: key) }
    static func pinned(_ item: MediaItem) -> SidebarEntry { SidebarEntry(id: "p:" + item.id, item: item) }
}

struct BuiltinDestination {
    let key: String
    let title: String
    let symbol: String
    let item: SidebarItem
    let section: SidebarSection

    static let all: [BuiltinDestination] = [
        .init(key: "home", title: "Home", symbol: "house", item: .home, section: .music),
        .init(key: "explore", title: "Explore", symbol: "square.grid.2x2", item: .explore, section: .music),
        .init(key: "charts", title: "Charts", symbol: "chart.line.uptrend.xyaxis", item: .charts, section: .music),
        .init(key: "moods", title: "Moods & Genres", symbol: "theatermasks", item: .moods, section: .music),
        .init(key: "new", title: "New Releases", symbol: "sparkles", item: .newReleases, section: .music),
        .init(key: "liked", title: "Liked Music", symbol: "hand.thumbsup", item: .liked, section: .library),
    ] + InnerTube.LibrarySection.allCases.map {
        .init(key: "lib." + $0.rawValue, title: $0.rawValue, symbol: $0.symbol, item: .library($0), section: .library)
    }

    static func find(_ key: String) -> BuiltinDestination? { all.first { $0.key == key } }
}

@MainActor
final class SidebarStore: ObservableObject {
    static let shared = SidebarStore()

    struct Config: Codable {
        var sectionOrder: [SidebarSection]
        var sections: [SidebarSection: [SidebarEntry]]
        var hiddenPlaylists: Set<String>
        var collapsed: Set<SidebarSection>
    }

    @Published var config: Config { didSet { Persist.save(config, "sidebarConfig") } }

    init() {
        var c = Persist.load("sidebarConfig", as: Config.self) ?? SidebarStore.defaultConfig
        // Add any built-ins introduced in later versions.
        let known = Set(c.sections.values.flatMap { $0 }.compactMap(\.builtin))
        for b in BuiltinDestination.all where !known.contains(b.key) {
            c.sections[b.section, default: []].append(.builtinEntry(b.key))
        }
        for s in SidebarSection.allCases where !c.sectionOrder.contains(s) { c.sectionOrder.append(s) }
        config = c
    }

    static var defaultConfig: Config {
        var sections: [SidebarSection: [SidebarEntry]] = [:]
        for b in BuiltinDestination.all { sections[b.section, default: []].append(.builtinEntry(b.key)) }
        // Less-used library pages start hidden; they can be re-enabled in Edit Sidebar.
        sections[.library] = sections[.library]?.map { e in
            var e = e
            if e.builtin == "lib.Podcasts" || e.builtin == "lib.Subscriptions" { e.hidden = true }
            return e
        }
        sections[.pinned] = []
        return Config(sectionOrder: [.music, .library, .pinned, .playlists], sections: sections,
                      hiddenPlaylists: [], collapsed: [])
    }

    func entries(_ s: SidebarSection) -> [SidebarEntry] { config.sections[s] ?? [] }

    func isPinned(_ item: MediaItem) -> Bool { entries(.pinned).contains { $0.item?.id == item.id } }

    func pin(_ item: MediaItem) {
        guard !isPinned(item) else { return }
        config.sections[.pinned, default: []].append(.pinned(item))
    }

    func unpin(_ id: String) {
        config.sections[.pinned]?.removeAll { $0.id == id || $0.item?.id == id }
    }

    func setHidden(_ entryId: String, in s: SidebarSection, _ hidden: Bool) {
        guard let i = config.sections[s]?.firstIndex(where: { $0.id == entryId }) else { return }
        config.sections[s]?[i].hidden = hidden
    }

    func move(_ s: SidebarSection, from: IndexSet, to: Int) {
        config.sections[s]?.move(fromOffsets: from, toOffset: to)
    }

    func moveEntry(_ entryId: String, in s: SidebarSection, by delta: Int) {
        guard var list = config.sections[s], let i = list.firstIndex(where: { $0.id == entryId }) else { return }
        let j = min(max(i + delta, 0), list.count - 1)
        guard i != j else { return }
        list.swapAt(i, j)
        config.sections[s] = list
    }

    func moveSection(from: IndexSet, to: Int) { config.sectionOrder.move(fromOffsets: from, toOffset: to) }

    func toggleCollapsed(_ s: SidebarSection) {
        if config.collapsed.contains(s) { config.collapsed.remove(s) } else { config.collapsed.insert(s) }
    }

    func reset() { config = SidebarStore.defaultConfig }
}

// MARK: - Speed Dial (pinned favourites on Home)

@MainActor
final class SpeedDialStore: ObservableObject {
    static let shared = SpeedDialStore()

    @Published var pinned: [MediaItem] { didSet { Persist.save(pinned, "speedDial") } }
    @Published var autoFill: Bool { didSet { UserDefaults.standard.set(autoFill, forKey: "speedDialAutoFill") } }
    @Published var visible: Bool { didSet { UserDefaults.standard.set(visible, forKey: "speedDialVisible") } }
    let capacity = 18

    init() {
        pinned = Persist.load("speedDial", as: [MediaItem].self) ?? []
        autoFill = UserDefaults.standard.object(forKey: "speedDialAutoFill") as? Bool ?? true
        visible = UserDefaults.standard.object(forKey: "speedDialVisible") as? Bool ?? true
    }

    func contains(_ item: MediaItem) -> Bool { pinned.contains { $0.id == item.id } }

    func toggle(_ item: MediaItem) {
        if contains(item) { pinned.removeAll { $0.id == item.id } }
        else {
            var i = item
            i.setVideoId = nil
            pinned.append(i)
        }
    }

    func remove(_ item: MediaItem) { pinned.removeAll { $0.id == item.id } }
    func move(from: IndexSet, to: Int) { pinned.move(fromOffsets: from, toOffset: to) }

    /// Your pinned items, then (optionally) the last 3 songs you played.
    func tiles(stats: PlayStats) -> [MediaItem] {
        var out = pinned
        guard autoFill else { return out }
        let have = Set(out.compactMap(\.videoId))
        for t in stats.recent(3, excluding: have) {
            out.append(MediaItem(id: t.videoId, kind: t.isVideo ? .video : .song, title: t.title,
                                 subtitle: t.artistLine, thumbnail: t.thumbnail, videoId: t.videoId,
                                 artists: t.artists, album: t.album, duration: t.duration))
        }
        return out
    }
}

/// Local play counts (never leave the Mac), used to suggest Speed Dial tiles.
@MainActor
final class PlayStats: ObservableObject {
    static let shared = PlayStats()

    struct Entry: Codable { var track: Track; var count: Int; var last: Date }
    @Published private(set) var entries: [String: Entry]

    init() { entries = Persist.load("playStats", as: [String: Entry].self) ?? [:] }

    func record(_ t: Track) {
        var e = entries[t.videoId] ?? Entry(track: t, count: 0, last: .distantPast)
        e.count += 1; e.last = Date(); e.track = t
        entries[t.videoId] = e
        if entries.count > 1500 {
            let keep = entries.sorted { $0.value.count > $1.value.count }.prefix(1000)
            entries = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }
        Persist.save(entries, "playStats")
    }

    /// Ranked by play count, with a gentle boost for recent plays.
    func top(_ n: Int) -> [Track] {
        let now = Date()
        return entries.values
            .filter { $0.count >= 2 }
            .sorted { a, b in
                let sa = Double(a.count) + max(0, 3 - now.timeIntervalSince(a.last) / 86400 / 7)
                let sb = Double(b.count) + max(0, 3 - now.timeIntervalSince(b.last) / 86400 / 7)
                return sa > sb
            }
            .prefix(n).map(\.track)
    }

    /// Most recently played songs, newest first.
    func recent(_ n: Int, excluding: Set<String> = []) -> [Track] {
        entries.values.filter { !excluding.contains($0.track.videoId) }
            .sorted { $0.last > $1.last }
            .prefix(n).map(\.track)
    }

    func clear() { entries = [:]; Persist.save(entries, "playStats") }
}

/// Fills in missing track lengths. Rows ask for their video ID when they appear;
/// requests made within a short window are batched into one lookup.
@MainActor
final class DurationCache: ObservableObject {
    static let shared = DurationCache()
    @Published private(set) var known: [String: TimeInterval] = [:]
    private var requested = Set<String>()
    private var pending: [String] = []
    private var scheduled = false

    func duration(_ videoId: String) -> TimeInterval? { known[videoId] }

    func request(_ videoId: String) {
        guard known[videoId] == nil, requested.insert(videoId).inserted else { return }
        pending.append(videoId)
        guard !scheduled else { return }
        scheduled = true
        Task {
            try? await Task.sleep(for: .milliseconds(150))
            let batch = pending; pending = []; scheduled = false
            for chunk in stride(from: 0, to: batch.count, by: 40).map({ Array(batch[$0..<min($0 + 40, batch.count)]) }) {
                let found = await InnerTube.shared.durations(videoIds: chunk)
                if !found.isEmpty { known.merge(found) { $1 } }
            }
        }
    }
}

/// Which songs you've liked or disliked, so every like button can show its state.
/// Filled from your Liked Music list, the playing song's status and your own taps.
@MainActor
final class LikeStore: ObservableObject {
    static let shared = LikeStore()
    @Published private(set) var liked = Set<String>()
    @Published private(set) var disliked = Set<String>()

    func status(_ videoId: String) -> LikeStatus {
        liked.contains(videoId) ? .like : (disliked.contains(videoId) ? .dislike : .indifferent)
    }

    func set(_ videoId: String, _ s: LikeStatus) {
        switch s {
        case .like: liked.insert(videoId); disliked.remove(videoId)
        case .dislike: disliked.insert(videoId); liked.remove(videoId)
        case .indifferent: liked.remove(videoId); disliked.remove(videoId)
        }
    }

    /// Songs listed in Liked Music.
    func seedLiked(_ ids: [String]) {
        let new = Set(ids).subtracting(liked)
        if !new.isEmpty { liked.formUnion(new) }
    }
}
