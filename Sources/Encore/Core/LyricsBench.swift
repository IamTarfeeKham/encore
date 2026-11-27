import Foundation

/// Developer check of lyrics coverage, using the exact song details the player gets.
///
///     defaults write local.ytmusicmac lyricsBench "Blinding Lights The Weeknd|Yellow Coldplay"
///
/// On launch, each query is searched (songs only), its first result is opened as a queue
/// the way the player does it, and every lyrics source is asked. Results go to
/// `$TMPDIR/lyrics-bench.log`. The key is cleared once it has run.
enum LyricsBench {
    static func runIfRequested() {
        guard let spec = UserDefaults.standard.string(forKey: "lyricsBench"), !spec.isEmpty else { return }
        UserDefaults.standard.removeObject(forKey: "lyricsBench")
        let queries = spec.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("lyrics-bench.log")
        try? "".write(to: url, atomically: true, encoding: .utf8)
        func log(_ s: String) {
            if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(Data((s + "\n").utf8)); try? h.close() }
        }
        Task.detached {
            for q in queries {
                guard let found = try? await InnerTube.shared.search(q, params: "EgWKAQIIAWoKEAkQBRAKEAMQBA%3D%3D"),
                      let vid = (found.items.first ?? found.shelves.first?.items.first)?.videoId,
                      let queue = try? await InnerTube.shared.watchQueue(videoId: vid, playlistId: nil),
                      let t = queue.tracks.first else { log("\(q)\tNOT FOUND"); continue }
                async let b = LyricsService.wordSynced(t)
                async let u = LyricsService.unison(t)
                async let k = LyricsService.kugou(t)
                async let n = LyricsService.netease(t)
                async let l = LyricsService.lrclib(t)
                let (bb, uu, kk, nn, ll) = await (b, u, k, n, l)
                func kind(_ x: Lyrics?) -> String { x == nil ? "-" : (x!.wordTimed ? "word" : "line") }
                let t0 = Date()
                let ext = await BetterLyricsExtension.shared.lyrics(for: t.videoId)
                let extInfo = "ext:\(kind(ext)) \(String(format: "%.1fs", Date().timeIntervalSince(t0))) \(ext?.source ?? "") lines:\(ext?.lines.filter { !$0.text.isEmpty }.count ?? 0)"
                let meta = "\(t.title) | \(t.artists.map(\.name).joined(separator: ", ")) | \(t.album?.name ?? "") | \(t.duration.map { String(Int($0)) } ?? "?")s | video:\(t.isVideo)"
                log("\(q)\t\(meta)\tbetter:\(kind(bb)) unison:\(kind(uu)) kugou:\(kind(kk)) netease:\(kind(nn)) lrclib:\(kind(ll))  \(extInfo)")
            }
            log("DONE")
        }
    }
}
