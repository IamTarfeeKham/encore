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
    /// Each word has its own timing from the source (not spread out by us).
    var wordTimed: Bool { lines.contains { $0.exactWords } }
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
            if src == .auto || src == .wordSynced {
                // Ask every word-timed source at once, then take the most precise answer:
                // Better Lyrics (syllables, background vocals) → KuGou → NetEase. Lyrics
                // timed only per line come after any of those.
                async let better = Self.wordSynced(track)
                async let kugou = Self.kugou(track)
                async let netease = Self.netease(track)
                let (b, k, n) = await (better, kugou, netease)
                let byWord = [b, k, n].compactMap { $0 }.first { $0.wordTimed }
                result = byWord ?? b
            }
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
        guard let parsed = TTMLParser.parseDetailed(ttml), !parsed.lines.isEmpty else { return nil }
        var lines = parsed.lines
        // Sanity check against the track length: a different version would be badly out of sync.
        if let d = t.duration, let last = lines.last, last.end > d + 8 { return nil }
        lines = withBreaks(lines)
        return Lyrics(lines: lines, synced: true, source: parsed.lineTimed ? "Better Lyrics (line-synced)" : "Better Lyrics (word-synced)")
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
        let pace = singingPace(raw)
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
                words = estimateWords(clean, start: start, nextStart: nextStart, pace: pace)
            }
            let end = exact ? (words.last?.end ?? nextStart) : (words.last?.end ?? nextStart)
            lines.append(LyricLine(id: i, start: start, end: min(end, nextStart), text: clean, words: words, exactWords: exact))
        }
        return Lyrics(lines: lines, synced: true, source: "LRCLIB")
    }

    /// How fast this singer gets through a line, in characters per second: the median over
    /// the song's lines of (characters ÷ time until the next line). A slow ballad comes out
    /// around 3–5, a fast song 12–16. Lines followed by an instrumental break are outliers
    /// that the median ignores.
    nonisolated static func singingPace(_ raw: [(Double, String)]) -> Double {
        var rates: [Double] = []
        for i in 0..<max(raw.count - 1, 0) {
            let chars = Double(raw[i].1.trimmingCharacters(in: .whitespaces).count)
            let gap = raw[i + 1].0 - raw[i].0
            if chars >= 3, gap > 0.3 { rates.append(chars / gap) }
        }
        guard !rates.isEmpty else { return 13 }
        rates.sort()
        return min(max(rates[rates.count / 2], 2.5), 16)
    }

    /// Spreads a line's words over the time it is likely being sung (at this song's pace;
    /// a gap much longer than that is taken to end in an instrumental tail).
    nonisolated static func estimateWords(_ text: String, start: Double, nextStart: Double, pace: Double = 13) -> [LyricWord] {
        let chars = Double(text.count + 1)
        let gap = max(nextStart - start, 0.4)
        let sung = min(gap * 0.94, max(chars / pace * 1.08, 1.2))
        return spreadWords(text, from: start, to: start + sung)
    }

    /// Spreads words across a known sung span, by length, with the last word held a little
    /// longer (singers usually hang on the end of a phrase).
    nonisolated static func spreadWords(_ text: String, from start: Double, to end: Double) -> [LyricWord] {
        let tokens = text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard !tokens.isEmpty else { return [] }
        let weights = tokens.enumerated().map { Double($0.element.count + 1) * ($0.offset == tokens.count - 1 && tokens.count > 1 ? 1.6 : 1) }
        let total = weights.reduce(0, +)
        let span = max(end - start, 0.3)
        var t = start
        return zip(tokens, weights).map { w, wt in
            let d = span * wt / total
            defer { t += d }
            return LyricWord(text: w, start: t, end: t + d, trailingSpace: true)
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
    /// Text directly inside <p> (line-timed lyrics have no word spans).
    private var pText = ""
    private var pendingSpace = false
    /// Whether any line came without word timing (the lyrics are then line-synced).
    private(set) var lineTimed = false

    static func parse(_ ttml: String) -> [LyricLine]? { parseDetailed(ttml)?.lines }

    static func parseDetailed(_ ttml: String) -> (lines: [LyricLine], lineTimed: Bool)? {
        let p = TTMLParser()
        let x = XMLParser(data: Data(ttml.utf8))
        x.delegate = p
        guard x.parse() else { return nil }
        return (p.lines, p.lineTimed)
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
            inP = true; words = []; text = ""; pText = ""
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
        if spanStack.isEmpty { pText += string }
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
            if words.isEmpty {
                // Line-timed: we know when the line starts and when the singing ends, so
                // the words are spread across that whole span (and wait for a slow singer).
                let clean = pText.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
                guard !clean.isEmpty, pEnd > pStart else { return }
                var ws = LyricsService.spreadWords(clean, from: pStart, to: pEnd)
                if !ws.isEmpty { ws[ws.count - 1].trailingSpace = false }
                lineTimed = true
                lines.append(LyricLine(id: lines.count, start: pStart, end: pEnd, text: clean, words: ws, exactWords: false))
                return
            }
            if !words.isEmpty { words[words.count - 1].trailingSpace = false }
            let lineText = words.map { $0.text + ($0.trailingSpace ? " " : "") }.joined()
            lines.append(LyricLine(id: lines.count, start: words.first?.start ?? pStart, end: max(pEnd, words.last?.end ?? pEnd),
                                   text: lineText, words: words, exactWords: true))
        default: break
        }
    }
}
