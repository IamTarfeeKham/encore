import Foundation

/// More sources of word-by-word timed lyrics (each word's own start and length, taken
/// from the recording), so the karaoke follows the singer, pauses and held notes included.
///
/// - KuGou: KRC lyrics. The download is base64 → 4-byte "krc1" tag → XOR with a fixed
///   16-byte key → zlib. Lines look like `[start,length]<offset,length,0>word…`, with each
///   word's offset counted from the line's start (all in milliseconds).
/// - NetEase Cloud Music: YRC lyrics. Lines look like `[start,length](start,length,0)word…`,
///   with each word's start absolute.
///
/// Only the song title, artist and length are sent. A match must be the same recording:
/// same title, same artist, and a length within a few seconds of the track's.
extension LyricsService {

    // MARK: KuGou

    nonisolated static func kugou(_ t: Track) async -> Lyrics? {
        let title = cleanTitle(t.title), artist = t.artists.first?.name ?? ""
        guard !title.isEmpty, !artist.isEmpty else { return nil }
        var c = URLComponents(string: "https://lyrics.kugou.com/search")!
        c.queryItems = [URLQueryItem(name: "ver", value: "1"), URLQueryItem(name: "man", value: "yes"),
                        URLQueryItem(name: "client", value: "pc"), URLQueryItem(name: "keyword", value: "\(artist) - \(title)")]
        if let d = t.duration { c.queryItems?.append(URLQueryItem(name: "duration", value: String(Int(d * 1000)))) }
        guard let found = await getJSON(c.url!) else { return nil }
        let match = found.candidates.array.first { cand in
            sameSong(cand.song.string, title) && sameArtist([cand.singer.string ?? ""], artist)
                && closeLength(cand.duration.double.map { $0 / 1000 }, t.duration)
        }
        guard let match, let id = match.id.string ?? match.id.double.map({ String(Int($0)) }),
              let key = match.accesskey.string else { return nil }
        var d = URLComponents(string: "https://lyrics.kugou.com/download")!
        d.queryItems = [URLQueryItem(name: "ver", value: "1"), URLQueryItem(name: "client", value: "pc"),
                        URLQueryItem(name: "id", value: id), URLQueryItem(name: "accesskey", value: key),
                        URLQueryItem(name: "fmt", value: "krc"), URLQueryItem(name: "charset", value: "utf8")]
        guard let dl = await getJSON(d.url!), let b64 = dl.content.string,
              let krc = decodeKRC(b64), var lines = parseKRC(krc, title: title, artist: artist),
              fits(lines, t.duration) else { return nil }
        lines = withBreaks(lines)
        return Lyrics(lines: lines, synced: true, source: "KuGou (word-synced)")
    }

    private nonisolated static let krcKey: [UInt8] = [64, 71, 97, 119, 94, 50, 116, 71, 81, 54, 49, 45, 206, 210, 110, 105]

    nonisolated static func decodeKRC(_ base64: String) -> String? {
        guard let raw = Data(base64Encoded: base64), raw.count > 4 else { return nil }
        let body = raw.dropFirst(4)
        var x = [UInt8](repeating: 0, count: body.count)
        for (i, b) in body.enumerated() { x[i] = b ^ krcKey[i % 16] }
        // A zlib stream: skip its 2-byte header; Foundation inflates the raw deflate data.
        guard x.count > 2, let out = try? (Data(x.dropFirst(2)) as NSData).decompressed(using: .zlib) else { return nil }
        return String(data: out as Data, encoding: .utf8)
    }

    nonisolated static func parseKRC(_ krc: String, title: String, artist: String) -> [LyricLine]? {
        let lineRx = try! NSRegularExpression(pattern: #"^\[(\d+),(\d+)\](.*)$"#)
        let wordRx = try! NSRegularExpression(pattern: #"<(\d+),(\d+),\d+>([^<]*)"#)
        var lines: [LyricLine] = []
        for raw in krc.components(separatedBy: .newlines) {
            let s = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            let ns = s as NSString
            guard let m = lineRx.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)),
                  let ls = Double(ns.substring(with: m.range(at: 1))), let ld = Double(ns.substring(with: m.range(at: 2))) else { continue }
            let body = ns.substring(with: m.range(at: 3))
            let bs = body as NSString
            var words: [LyricWord] = []
            for w in wordRx.matches(in: body, range: NSRange(location: 0, length: bs.length)) {
                guard let o = Double(bs.substring(with: w.range(at: 1))), let d = Double(bs.substring(with: w.range(at: 2))) else { continue }
                let start = (ls + o) / 1000, end = (ls + o + max(d, 30)) / 1000
                let piece = word(bs.substring(with: w.range(at: 3)), start: start, end: end, after: &words)
                words.append(piece)
            }
            words.removeAll { $0.text.isEmpty }
            if let line = finishLine(words, id: lines.count, lineEnd: (ls + ld) / 1000, title: title, artist: artist) { lines.append(line) }
        }
        return lines.count >= 2 ? lines : nil
    }

    // MARK: NetEase Cloud Music

    nonisolated static func netease(_ t: Track) async -> Lyrics? {
        let title = cleanTitle(t.title), artist = t.artists.first?.name ?? ""
        guard !title.isEmpty, !artist.isEmpty else { return nil }
        var c = URLComponents(string: "https://music.163.com/api/search/get")!
        c.queryItems = [URLQueryItem(name: "s", value: "\(title) \(artist)"), URLQueryItem(name: "type", value: "1"),
                        URLQueryItem(name: "limit", value: "10")]
        guard let found = await getJSON(c.url!) else { return nil }
        let matches = found.result.songs.array.filter { s in
            sameSong(s.name.string, title) && sameArtist(s.artists.array.compactMap { $0.name.string }, artist)
                && closeLength(s.duration.double.map { $0 / 1000 }, t.duration)
        }
        for s in matches.prefix(3) {
            guard let id = s.id.double.map({ String(Int($0)) }) else { continue }
            let u = URL(string: "https://music.163.com/api/song/lyric/v1?id=\(id)&lv=-1&yv=-1")!
            guard let l = await getJSON(u), let yrc = l.yrc.lyric.string, !yrc.isEmpty,
                  var lines = parseYRC(yrc, title: title, artist: artist), fits(lines, t.duration) else { continue }
            lines = withBreaks(lines)
            return Lyrics(lines: lines, synced: true, source: "NetEase Cloud Music (word-synced)")
        }
        return nil
    }

    nonisolated static func parseYRC(_ yrc: String, title: String, artist: String) -> [LyricLine]? {
        let lineRx = try! NSRegularExpression(pattern: #"^\[(\d+),(\d+)\](.*)$"#)
        let wordRx = try! NSRegularExpression(pattern: #"\((\d+),(\d+),\d+\)([^(]*)"#)
        var lines: [LyricLine] = []
        for raw in yrc.components(separatedBy: .newlines) {
            let s = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            guard !s.hasPrefix("{") else { continue }      // credits, as JSON
            let ns = s as NSString
            guard let m = lineRx.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)),
                  let ls = Double(ns.substring(with: m.range(at: 1))), let ld = Double(ns.substring(with: m.range(at: 2))) else { continue }
            let body = ns.substring(with: m.range(at: 3))
            let bs = body as NSString
            var words: [LyricWord] = []
            for w in wordRx.matches(in: body, range: NSRange(location: 0, length: bs.length)) {
                guard let st = Double(bs.substring(with: w.range(at: 1))), let d = Double(bs.substring(with: w.range(at: 2))) else { continue }
                let piece = word(bs.substring(with: w.range(at: 3)), start: st / 1000, end: (st + max(d, 30)) / 1000, after: &words)
                words.append(piece)
            }
            words.removeAll { $0.text.isEmpty }
            if let line = finishLine(words, id: lines.count, lineEnd: (ls + ld) / 1000, title: title, artist: artist) { lines.append(line) }
        }
        return lines.count >= 2 ? lines : nil
    }

    // MARK: Better Lyrics Unison (community lyrics, looked up by YouTube video)

    nonisolated static func unison(_ t: Track) async -> Lyrics? {
        var c = URLComponents(string: "https://unison.betterlyrics.org/lyrics")!
        c.queryItems = [URLQueryItem(name: "v", value: t.videoId)]
        guard let j = await getJSON(c.url!), let body = j.data.lyrics.string, !body.isEmpty else { return nil }
        let word = j.data.syncType.string == "richsync"
        switch j.data.format.string {
        case "ttml":
            guard let parsed = TTMLParser.parseDetailed(body), !parsed.lines.isEmpty, fits(parsed.lines, t.duration) else { return nil }
            return Lyrics(lines: withBreaks(parsed.lines), synced: true,
                          source: "Better Lyrics Unison (\(parsed.lineTimed ? "line" : "word")-synced)")
        case "lrc":
            guard var l = parseLRC(body), fits(l.lines, t.duration) else { return nil }
            l.lines = withBreaks(l.lines)
            l.source = "Better Lyrics Unison (\(word && l.wordTimed ? "word" : "line")-synced)"
            return l
        default:
            return nil
        }
    }

    // MARK: Shared

    /// One timed piece of text. A trailing space means the next piece starts a new word;
    /// a piece that is only a space marks the previous one as ending its word.
    private nonisolated static func word(_ text: String, start: Double, end: Double, after words: inout [LyricWord]) -> LyricWord {
        let lead = text.hasPrefix(" ")
        if lead, !words.isEmpty { words[words.count - 1].trailingSpace = true }
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        return LyricWord(text: trimmed, start: start, end: end, trailingSpace: text.hasSuffix(" "))
    }

    /// Builds a line, or nil for empty lines and credit lines ("Title - Artist", "作词：…").
    private nonisolated static func finishLine(_ w: [LyricWord], id: Int, lineEnd: Double, title: String, artist: String) -> LyricLine? {
        var words = w
        guard !words.isEmpty else { return nil }
        words[words.count - 1].trailingSpace = false
        let text = words.map { $0.text + ($0.trailingSpace ? " " : "") }.joined().trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        let credits = ["作词", "作曲", "编曲", "制作", "词：", "曲：", "词:", "曲:", "Lyrics by", "Composed by", "Written by"]
        if credits.contains(where: { text.contains($0) }) { return nil }
        let n = norm(text)
        if n.contains(norm(title)), n.contains(norm(artist)) { return nil }
        let start = words.first!.start
        return LyricLine(id: id, start: start, end: max(lineEnd, words.last!.end), text: text, words: words, exactWords: true)
    }

    /// The lyrics must fit the track (a different version would be out of sync).
    private nonisolated static func fits(_ lines: [LyricLine], _ duration: Double?) -> Bool {
        guard let d = duration, let last = lines.last else { return true }
        return last.start < d + 2
    }

    private nonisolated static func norm(_ s: String) -> String {
        String(s.lowercased().folding(options: .diacriticInsensitive, locale: nil).unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
    }

    private nonisolated static func sameSong(_ candidate: String?, _ title: String) -> Bool {
        guard let candidate else { return false }
        let a = norm(cleanTitle(candidate)), b = norm(title)
        guard !a.isEmpty, !b.isEmpty else { return false }
        return a == b || a.hasPrefix(b) || b.hasPrefix(a)
    }

    private nonisolated static func sameArtist(_ candidates: [String], _ artist: String) -> Bool {
        let b = norm(artist)
        guard !b.isEmpty else { return false }
        return candidates.contains { c in
            // "Coldplay、Rihanna", "A & B", "A feat. B": any part may be the artist.
            c.components(separatedBy: CharacterSet(charactersIn: "、,&/;")).map(norm).contains { $0 == b || $0.contains(b) || (!$0.isEmpty && b.contains($0)) }
        }
    }

    private nonisolated static func closeLength(_ candidate: Double?, _ track: Double?) -> Bool {
        guard let track else { return true }
        guard let candidate else { return false }
        return abs(candidate - track) <= 4
    }

    /// A private session for lyrics lookups that never keeps or sends cookies. (NetEase
    /// tags a client with a cookie on its first request and then answers searches that
    /// carry it with unrelated songs; no lyrics service needs to know who is asking.)
    nonisolated static let lyricsSession: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.httpCookieAcceptPolicy = .never
        c.httpShouldSetCookies = false
        c.httpCookieStorage = nil
        c.urlCache = nil
        return URLSession(configuration: c)
    }()

    nonisolated static func getJSON(_ url: URL) async -> JSON? {
        var req = URLRequest(url: url, timeoutInterval: 8)
        req.setValue("\(AppInfo.name)/\(AppInfo.version) (macOS desktop client)", forHTTPHeaderField: "User-Agent")
        guard let (data, resp) = try? await lyricsSession.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSON(data: data)
    }
}
