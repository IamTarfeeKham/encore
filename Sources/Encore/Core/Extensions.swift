import Foundation
import CryptoKit
import Combine

// MARK: - SponsorBlock

/// Skips crowd-sourced segments (non-music parts of music videos, sponsor reads…)
/// using the public SponsorBlock database. Privacy: only the first 4 hex
/// characters of the video ID's SHA-256 are sent; matching happens locally.
@MainActor
final class SponsorBlock {
    static let shared = SponsorBlock()

    struct Segment { let start: Double; let end: Double; let category: String }
    private(set) var segments: [Segment] = []
    private var forVideo: String?
    private var skipped = Set<Double>()

    func load(videoId: String) {
        forVideo = videoId
        segments = []
        skipped = []
        let prefs = Prefs.shared
        guard prefs.sponsorBlock, !prefs.sponsorCategories.isEmpty else { return }
        let hash = SHA256.hash(data: Data(videoId.utf8)).map { String(format: "%02x", $0) }.joined()
        var c = URLComponents(string: "https://sponsor.ajay.app/api/skipSegments/\(hash.prefix(4))")!
        let cats = "[" + prefs.sponsorCategories.map { "\"\($0)\"" }.joined(separator: ",") + "]"
        c.queryItems = [URLQueryItem(name: "categories", value: cats)]
        let url = c.url!
        Task {
            var req = URLRequest(url: url, timeoutInterval: 8)
            req.setValue("\(AppInfo.name)/\(AppInfo.version)", forHTTPHeaderField: "User-Agent")
            guard let (data, resp) = try? await URLSession.shared.data(for: req),
                  (resp as? HTTPURLResponse)?.statusCode == 200,
                  let json = try? JSON(data: data) else { return }
            let mine = json.array.first { $0.videoID.string == videoId }
            let segs: [Segment] = (mine?.segments.array ?? []).compactMap { s in
                let r = s.segment.array.compactMap(\.double)
                guard r.count == 2, r[1] - r[0] > 1, s.actionType.string ?? "skip" == "skip" else { return nil }
                return Segment(start: r[0], end: r[1], category: s.category.string ?? "")
            }
            guard self.forVideo == videoId else { return }
            self.segments = segs.sorted { $0.start < $1.start }
        }
    }

    /// Called with the playback position; returns where to jump if inside a segment.
    func check(time: Double, videoId: String?) -> Segment? {
        guard Prefs.shared.sponsorBlock, videoId == forVideo else { return nil }
        for s in segments where time >= s.start && time < s.end - 0.5 && !skipped.contains(s.start) {
            skipped.insert(s.start)
            return s
        }
        return nil
    }

    static func label(_ category: String) -> String {
        switch category {
        case "music_offtopic": return "Skipped non-music section"
        case "sponsor": return "Skipped sponsor"
        case "selfpromo": return "Skipped self-promotion"
        case "intro": return "Skipped intro"
        case "outro": return "Skipped outro"
        case "interaction": return "Skipped reminder"
        default: return "Skipped segment"
        }
    }
}

// MARK: - Equalizer

/// Routes YouTube's audio through a Web Audio equaliser inside the player page.
@MainActor
final class Equalizer {
    static let shared = Equalizer()
    private var bag = Set<AnyCancellable>()

    func start() {
        let p = Prefs.shared
        p.$eqEnabled.combineLatest(p.$eqGains)
            .debounce(for: .milliseconds(60), scheduler: RunLoop.main)
            .sink { [weak self] _, _ in self?.apply() }
            .store(in: &bag)
        NotificationCenter.default.publisher(for: .ytBridgeReady)
            .sink { [weak self] _ in self?.apply() }.store(in: &bag)
        NotificationCenter.default.publisher(for: .trackChanged)
            .delay(for: .seconds(1.5), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.apply() }.store(in: &bag)
    }

    func apply() {
        let p = Prefs.shared
        let gains = p.eqEnabled ? p.eqGains : Array(repeating: 0, count: Prefs.eqBands.count)
        let bands = Prefs.eqBands.map { String($0) }.joined(separator: ",")
        let g = gains.map { String(format: "%.2f", $0) }.joined(separator: ",")
        Task { await WebBridge.shared.js("window.__ytmac && window.__ytmac.eq([\(bands)], [\(g)], \(p.eqEnabled))") }
    }
}
