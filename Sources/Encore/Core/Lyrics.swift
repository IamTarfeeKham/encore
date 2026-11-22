import Foundation

struct LyricWord: Hashable, Sendable {
    var text: String
    var start: Double
    var end: Double
    /// False when the next piece is a syllable of the same word (no space between).
    var trailingSpace = true
}

struct LyricLine: Identifiable, Hashable, Sendable {
    var id: Int
    var start: Double
    var end: Double
    var text: String
    var words: [LyricWord]
    /// True when word timings came from the source (enhanced LRC), not estimated.
    var exactWords: Bool
}

struct Lyrics: Sendable {
    var lines: [LyricLine]
    var synced: Bool
    var source: String
}

/// Synced lyrics from LRCLIB (free, open database), falling back to YouTube
/// Music's own plain lyrics.
@MainActor
final class LyricsService: ObservableObject {
    static let shared = LyricsService()

    enum State { case idle, loading, loaded(Lyrics), unavailable }
    @Published private(set) var state: State = .idle
    private var loadedFor: String?
    private var cache: [String: Lyrics] = [:]

    private var source: Prefs.LyricsSource { Prefs.shared.lyricsSource }

    /// Forget cached lyrics (e.g. after changing the lyrics source).
    func reload(for track: Track?, ytLyricsBrowseId: String?) {
        cache = [:]; loadedFor = nil
        load(for: track, ytLyricsBrowseId: ytLyricsBrowseId)
    }

    func load(for track: Track?, ytLyricsBrowseId: String?) {
        guard let track else { state = .idle; loadedFor = nil; return }
        let key = track.videoId
        if loadedFor == key, case .loaded = state { return }
        if loadedFor == key, case .loading = state { return }
        if loadedFor == key, case .unavailable = state, ytLyricsBrowseId == nil { return }
        loadedFor = key
        if let c = cache[key] { state = .loaded(c); return }
        state = .loading
        Task {
            var result: Lyrics?
            let src = source
            if src == .auto || src == .wordSynced { result = await Self.wordSynced(track) }
            if result == nil, src == .auto || src == .lineSynced { result = await Self.lrclib(track) }
            if result == nil, let bid = ytLyricsBrowseId,
               let yt = try? await InnerTube.shared.lyrics(browseId: bid) {
                let lines = yt.text.components(separatedBy: "\n").enumerated().map {
                    LyricLine(id: $0.offset, start: 0, end: 0, text: $0.element, words: [], exactWords: false)
                }
                result = Lyrics(lines: lines, synced: false, source: yt.source ?? "YouTube Music")
            }
            guard loadedFor == key else { return }
            if let result { cache[key] = result; state = .loaded(result) }
            else { state = .unavailable }
        }
    }

    // MARK: Word-synced (Better Lyrics open lyrics API, TTML with per-word timing)

    nonisolated static func wordSynced(_ t: Track) async -> Lyrics? {
        var c = URLComponents(string: "https://lyrics-api.boidu.dev/getLyrics")!
        c.queryItems = [URLQueryItem(name: "s", value: cleanTitle(t.title)),
                        URLQueryItem(name: "a", value: t.artists.first?.name ?? "")]
        if let d = t.duration { c.queryItems?.append(URLQueryItem(name: "d", value: String(Int(d)))) }
        if let al = t.album?.name { c.queryItems?.append(URLQueryItem(name: "al", value: al)) }
        guard let j = await fetch(c.url!), let ttml = j.ttml.string, !ttml.isEmpty else { return nil }
        guard var lines = TTMLParser.parse(ttml), !lines.isEmpty else { return nil }
        // Sanity check against the track length: a different version would be badly out of sync.
        if let d = t.duration, let last = lines.last, last.end > d + 8 { return nil }
        lines = withBreaks(lines)
        return Lyrics(lines: lines, synced: true, source: "Better Lyrics (word-synced)")
    }

    /// Inserts instrumental-break lines (shown as breathing dots) into long gaps.
    nonisolated static func withBreaks(_ lines: [LyricLine]) -> [LyricLine] {
        var out: [LyricLine] = []
        if let first = lines.first, first.start > 4 {
            out.append(LyricLine(id: 0, start: 0.5, end: first.start - 0.2, text: "", words: [], exactWords: true))
        }
        for (i, l) in lines.enumerated() {
            out.append(l)
            if i + 1 < lines.count, lines[i + 1].start - l.end > 4.5 {
                out.append(LyricLine(id: 0, start: l.end + 0.3, end: lines[i + 1].start - 0.2, text: "", words: [], exactWords: true))
            }
        }
        for i in out.indices { out[i].id = i }
        return out
    }

    // MARK: LRCLIB

    nonisolated static func cleanTitle(_ s: String) -> String {
        var t = s
        for pattern in [#"\s*[\(\[][^\)\]]*(official|video|audio|lyrics?|visuali[sz]er|remaster|from|feat\.?|ft\.)[^\)\]]*[\)\]]"#,
                        #"\s+-\s+(official|lyrics?).*$"#] {
            t = t.replacingOccurrences(of: pattern, with: "", options: [.regularExpression, .caseInsensitive])
        }
        return t.trimmingCharacters(in: .whitespaces)
    }

    nonisolated static func lrclib(_ t: Track) async -> Lyrics? {
        let artist = t.artists.first?.name ?? ""
        let title = cleanTitle(t.title)
        var comps = URLComponents(string: "https://lrclib.net/api/get")!
        comps.queryItems = [URLQueryItem(name: "track_name", value: title),
                            URLQueryItem(name: "artist_name", value: artist)]
        if let a = t.album?.name { comps.queryItems?.append(URLQueryItem(name: "album_name", value: a)) }
        if let d = t.duration { comps.queryItems?.append(URLQueryItem(name: "duration", value: String(Int(d)))) }
        if let j = await fetch(comps.url!), let lrc = j.syncedLyrics.string, var l = parseLRC(lrc) {
            l.lines = withBreaks(l.lines); return l
        }

        // Fuzzy search fallback, picking the closest duration with synced lyrics.
        var s = URLComponents(string: "https://lrclib.net/api/search")!
        s.queryItems = [URLQueryItem(name: "track_name", value: title), URLQueryItem(name: "artist_name", value: artist)]
        guard let list = await fetch(s.url!)?.array, !list.isEmpty else { return nil }
        let candidates = list.filter { $0.syncedLyrics.string != nil }
        let best = candidates.min { a, b in
            abs((a.duration.double ?? 0) - (t.duration ?? 0)) < abs((b.duration.double ?? 0) - (t.duration ?? 0))
        }
        if let best, let d = t.duration, let bd = best.duration.double, abs(bd - d) > 8 { return nil }
        guard var l = best?.syncedLyrics.string.flatMap(parseLRC) else { return nil }
        l.lines = withBreaks(l.lines)
        return l
    }

    nonisolated private static func fetch(_ url: URL) async -> JSON? {
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue("\(AppInfo.name)/\(AppInfo.version) (macOS desktop client)", forHTTPHeaderField: "User-Agent")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSON(data: data)
    }

    // MARK: LRC parsing (incl. enhanced <mm:ss.xx> word timestamps)

    nonisolated static func timestamp(_ s: Substring) -> Double? {
        let parts = s.split(separator: ":")
        guard parts.count == 2, let m = Double(parts[0]), let sec = Double(parts[1].replacingOccurrences(of: ",", with: ".")) else { return nil }
        return m * 60 + sec
    }

    nonisolated static func parseLRC(_ lrc: String) -> Lyrics? {
        var raw: [(Double, String)] = []
        let lineTag = try! NSRegularExpression(pattern: #"\[(\d{1,3}:\d{1,2}(?:[.,]\d{1,3})?)\]"#)
        for line in lrc.components(separatedBy: .newlines) {
            let ns = line as NSString
            let matches = lineTag.matches(in: line, range: NSRange(location: 0, length: ns.length))
            guard let last = matches.last else { continue }
            let text = ns.substring(from: last.range.upperBound)
            for m in matches {
                if let t = timestamp(Substring(ns.substring(with: m.range(at: 1)))) { raw.append((t, text)) }
            }
        }
        guard !raw.isEmpty else { return nil }
        raw.sort { $0.0 < $1.0 }

        let wordTag = try! NSRegularExpression(pattern: #"<(\d{1,3}:\d{1,2}(?:[.,]\d{1,3})?)>"#)
        var lines: [LyricLine] = []
        for (i, (start, text)) in raw.enumerated() {
            let nextStart = i + 1 < raw.count ? raw[i + 1].0 : start + 6
            let ns = text as NSString
            let wm = wordTag.matches(in: text, range: NSRange(location: 0, length: ns.length))
            var words: [LyricWord] = []
            var clean: String
            var exact = false
            if !wm.isEmpty {
                exact = true
                clean = wordTag.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: ns.length), withTemplate: "")
                for (k, m) in wm.enumerated() {
                    let ws = timestamp(Substring(ns.substring(with: m.range(at: 1)))) ?? start
                    let textEnd = k + 1 < wm.count ? wm[k + 1].range.location : ns.length
                    let w = ns.substring(with: NSRange(location: m.range.upperBound, length: textEnd - m.range.upperBound))
                    if w.trimmingCharacters(in: .whitespaces).isEmpty { continue }
                    words.append(LyricWord(text: w, start: ws, end: ws))
                }
                for k in words.indices { words[k].end = k + 1 < words.count ? words[k + 1].start : nextStart }
            } else {
                clean = text
            }
            clean = clean.trimmingCharacters(in: .whitespaces)
            if words.isEmpty, !clean.isEmpty {
                words = estimateWords(clean, start: start, nextStart: nextStart)
            }
            let end = exact ? (words.last?.end ?? nextStart) : (words.last?.end ?? nextStart)
            lines.append(LyricLine(id: i, start: start, end: min(end, nextStart), text: clean, words: words, exactWords: exact))
        }
        return Lyrics(lines: lines, synced: true, source: "LRCLIB")
    }

    /// Spreads a line's words over the time it is likely being sung.
    nonisolated static func estimateWords(_ text: String, start: Double, nextStart: Double) -> [LyricWord] {
        let tokens = text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard !tokens.isEmpty else { return [] }
        let chars = Double(tokens.reduce(0) { $0 + $1.count + 1 })
        let gap = max(nextStart - start, 0.4)
        // Long gaps usually include an instrumental tail; assume ~13 chars/s singing.
        let sung = min(gap * 0.92, max(chars / 13.0, 1.2))
        var t = start
        return tokens.map { w in
            let d = sung * Double(w.count + 1) / chars
            defer { t += d }
            return LyricWord(text: w, start: t, end: t + d)
        }
    }
}


/// Parses Apple-style TTML lyrics (<p> lines with <span begin end> words/syllables).
final class TTMLParser: NSObject, XMLParserDelegate {
    private var lines: [LyricLine] = []
    private var inP = false
    private var pStart = 0.0, pEnd = 0.0
    private var words: [LyricWord] = []
    private var spanStack: [(begin: Double, end: Double, isBG: Bool)] = []
    private var text = ""
    private var pendingSpace = false

    static func parse(_ ttml: String) -> [LyricLine]? {
        let p = TTMLParser()
        let x = XMLParser(data: Data(ttml.utf8))
        x.delegate = p
        guard x.parse() else { return nil }
        return p.lines
    }

    static func time(_ s: String?) -> Double? {
        guard let s, !s.isEmpty else { return nil }
        let parts = s.split(separator: ":").map(String.init)
        var t = 0.0
        for part in parts {
            guard let v = Double(part.replacingOccurrences(of: "s", with: "")) else { return nil }
            t = t * 60 + v
        }
        return t
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                attributes a: [String: String] = [:]) {
        switch name {
        case "p":
            inP = true; words = []; text = ""
            pStart = Self.time(a["begin"]) ?? 0; pEnd = Self.time(a["end"]) ?? pStart
        case "span" where inP:
            let role = a["ttm:role"] ?? a["role"] ?? ""
            let parentBG = spanStack.last?.isBG ?? false
            spanStack.append((Self.time(a["begin"]) ?? -1, Self.time(a["end"]) ?? -1, parentBG || role == "x-bg"))
            text = ""
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard inP else { return }
        if string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // Whitespace between spans marks a word boundary.
            if text.trimmingCharacters(in: .whitespaces).isEmpty, !words.isEmpty { words[words.count - 1].trailingSpace = true }
            if !spanStack.isEmpty { text += string }
        } else if !spanStack.isEmpty {
            text += string
        }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        switch name {
        case "span" where inP:
            guard let span = spanStack.popLast() else { return }
            let w = text.trimmingCharacters(in: .whitespacesAndNewlines)
            text = ""
            guard !w.isEmpty, span.begin >= 0 else { return }
            if span.isBG {
                // Background vocals: keep them, in parentheses, after the main line.
                let piece = LyricWord(text: w, start: span.begin, end: max(span.end, span.begin + 0.05), trailingSpace: false)
                if let last = words.last, last.text.hasPrefix("("), !last.text.hasSuffix(")") {
                    words.append(piece)
                } else {
                    if !words.isEmpty { words[words.count - 1].trailingSpace = true }
                    words.append(LyricWord(text: "(" + w, start: piece.start, end: piece.end, trailingSpace: false))
                }
            } else {
                words.append(LyricWord(text: w, start: span.begin, end: max(span.end, span.begin + 0.05), trailingSpace: false))
            }
        case "p":
            inP = false
            if let i = words.lastIndex(where: { $0.text.hasPrefix("(") }), !words[words.count - 1].text.hasSuffix(")") , i >= 0 {
                words[words.count - 1].text += ")"
            }
            if words.isEmpty { return }
            if !words.isEmpty { words[words.count - 1].trailingSpace = false }
            let lineText = words.map { $0.text + ($0.trailingSpace ? " " : "") }.joined()
            lines.append(LyricLine(id: lines.count, start: words.first?.start ?? pStart, end: max(pEnd, words.last?.end ?? pEnd),
                                   text: lineText, words: words, exactWords: true))
        default: break
        }
    }
}
