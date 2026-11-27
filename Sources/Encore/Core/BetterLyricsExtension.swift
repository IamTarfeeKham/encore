import CryptoKit
import Foundation
import WebKit

/// The Better Lyrics browser extension (betterlyrics.org, GPLv3), run as-is, for songs
/// Encore's own lyrics sources can't time word by word.
///
/// Better Lyrics asks many more services than Encore can (Musixmatch, QQ Music, Spicy
/// Lyrics, BiniLyrics, its community lyrics…), some through its own server, which it
/// unlocks with an invisible check that only its own code runs. So Encore doesn't call
/// those services: it runs the real extension, unchanged, in a hidden YouTube Music page
/// of its own, and reads the timed lyrics the extension puts on that page.
///
/// - The extension isn't shipped inside Encore. The first time it's needed, the official
///   release is downloaded from GitHub; it must match a fixed checksum, so a changed file
///   is never run. Updating it means updating the version and checksum here.
/// - The page never plays anything (playback needs a user action there, and there is
///   none), keeps nothing between launches (its own private website data, so it is
///   signed out and leaves no history), and goes blank once the lyrics are read.
/// - Needs macOS 15.4 or later (WebKit's web-extension support).
@MainActor
final class BetterLyricsExtension: NSObject {
    static let shared = BetterLyricsExtension()

    static let version = "3.0.2"
    private static let downloadURL = URL(string: "https://github.com/better-lyrics/better-lyrics/releases/download/v3.0.2/chrome-v3.0.2.zip")!
    private static let sha256 = "0f03e06a90f950a76013e1660f9d4e116391fd09f6d19467a74a118e7955ad9c"

    static var isSupported: Bool {
        if #available(macOS 15.4, *) { return true }
        return false
    }

    private var folder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Encore/Better Lyrics/\(Self.version)", isDirectory: true)
    }

    private var controller: AnyObject?          // WKWebExtensionController (macOS 15.4+)
    private var page: WKWebView?
    private var starting: Task<Bool, Never>?
    /// One page, one song at a time.
    private var queue: [(String, CheckedContinuation<Lyrics?, Never>)] = []
    private var busy = false
    private var cache: [String: Lyrics] = [:]

    // MARK: Public

    /// The extension's lyrics for this video, or nil (not supported, turned off, failed,
    /// or Better Lyrics found nothing either).
    func lyrics(for videoId: String) async -> Lyrics? {
        guard Self.isSupported, Prefs.shared.lyricsBetterLyricsExtension else { return nil }
        if let c = cache[videoId] { return c }
        guard await start() else { return nil }
        let result: Lyrics? = await withCheckedContinuation { cont in
            queue.append((videoId, cont))
            pump()
        }
        if let result { cache[videoId] = result }
        return result
    }

    // MARK: Setup

    private func start() async -> Bool {
        if page != nil { return true }
        if let starting { return await starting.value }
        let t = Task { await self.setUp() }
        starting = t
        let ok = await t.value
        if !ok { starting = nil }
        return ok
    }

    private func setUp() async -> Bool {
        guard #available(macOS 15.4, *) else { return false }
        guard let dir = await installed() else { return false }
        do {
            let ext = try await WKWebExtension(resourceBaseURL: dir)
            let ctx = WKWebExtensionContext(for: ext)
            // Exactly what its manifest asks for: storage, alarms, music.youtube.com.
            for p in ext.requestedPermissions { ctx.setPermissionStatus(.grantedExplicitly, for: p) }
            for m in ext.allRequestedMatchPatterns { ctx.setPermissionStatus(.grantedExplicitly, for: m) }
            // Its page keeps no website data (like a private window); extensions only run
            // in such pages when allowed to.
            ctx.hasAccessToPrivateData = true
            let c = WKWebExtensionController()
            try c.load(ctx)
            controller = c

            let config = WKWebViewConfiguration()
            config.webExtensionController = c
            config.websiteDataStore = .nonPersistent()
            config.mediaTypesRequiringUserActionForPlayback = .all
            let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 1280, height: 720), configuration: config)
            web.customUserAgent = WebBridge.userAgent
            // In the hidden player window (off-screen, transparent), behind the player pages:
            // a page that isn't in a window gets throttled by WebKit.
            if let host = WebHost.shared.parkingWindow.contentView {
                web.frame = host.bounds
                web.autoresizingMask = [.width, .height]
                web.alphaValue = 0
                host.addSubview(web, positioned: .below, relativeTo: nil)
            }
            page = web
            PerfMonitor.note("better lyrics: extension \(Self.version) loaded")
            return true
        } catch {
            PerfMonitor.note("better lyrics: couldn't load the extension: \(error)")
            return false
        }
    }

    /// The unpacked extension, downloading and checking it the first time.
    private func installed() async -> URL? {
        let manifest = folder.appendingPathComponent("manifest.json")
        if FileManager.default.fileExists(atPath: manifest.path) { return folder }
        var req = URLRequest(url: Self.downloadURL, timeoutInterval: 60)
        req.setValue("\(AppInfo.name)/\(AppInfo.version) (macOS desktop client)", forHTTPHeaderField: "User-Agent")
        guard let (data, resp) = try? await LyricsService.lyricsSession.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else {
            PerfMonitor.note("better lyrics: download failed"); return nil
        }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest == Self.sha256 else {
            PerfMonitor.note("better lyrics: download didn't match the expected checksum; not used"); return nil
        }
        let tmp = folder.deletingLastPathComponent().appendingPathComponent(".unpacking-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            try Zip.extract(data, to: tmp)
            try? FileManager.default.removeItem(at: folder)
            try FileManager.default.moveItem(at: tmp, to: folder)
            return folder
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            PerfMonitor.note("better lyrics: couldn't unpack: \(error)")
            return nil
        }
    }

    // MARK: Reading lyrics off the page

    private func pump() {
        guard !busy, !queue.isEmpty, let page else { return }
        busy = true
        let (videoId, cont) = queue.removeFirst()
        Task {
            let result = await read(videoId, in: page)
            page.load(URLRequest(url: URL(string: "about:blank")!))   // stop everything on the page
            cont.resume(returning: result)
            busy = false
            pump()
        }
    }

    private func read(_ videoId: String, in page: WKWebView) async -> Lyrics? {
        guard let url = URL(string: "https://music.youtube.com/watch?v=\(videoId)") else { return nil }
        page.load(URLRequest(url: url))
        let deadline = Date().addingTimeInterval(16)
        var lastJSON: String?
        var settledAt: Date?
        var polls = 0
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 400_000_000)
            polls += 1
            let raw = try? await page.evaluateJavaScript(Self.probeJS)
            if polls % 5 == 1 {
                let summary = (raw as? String).map { String($0.prefix(160)) } ?? "no result"
                let extra = (try? await page.evaluateJavaScript("JSON.stringify({u: location.href, tabs: document.querySelectorAll('tp-yt-paper-tab').length, b: document.querySelectorAll('[class*=blyrics]').length, title: document.title})")) as? String ?? "?"
                PerfMonitor.note("better lyrics: \(videoId) poll \(polls): \(summary) \(extra)")
            }
            guard let json = raw as? String else { continue }
            guard let data = json.data(using: .utf8), let j = try? JSON(data: data) else { continue }
            if j.video.string != videoId { continue }
            // Better Lyrics first shows YouTube's own untimed lines, then its real answer;
            // its loading indicator hides once it has finished asking.
            guard j.done.bool == true else { continue }
            if j.lines.array.isEmpty {
                // Finished with nothing (or still fading in): give it a moment, then stop.
                if settledAt == nil { settledAt = Date() }
                if Date().timeIntervalSince(settledAt!) > 1.5 { return nil }
                continue
            }
            if json == lastJSON { return Self.lyrics(from: j) }   // the same twice in a row: settled
            lastJSON = json
        }
        return lastJSON.flatMap { $0.data(using: .utf8) }.flatMap { try? JSON(data: $0) }.flatMap(Self.lyrics(from:))
    }

    private static func lyrics(from j: JSON) -> Lyrics? {
        var lines: [LyricLine] = []
        for l in j.lines.array {
            guard let lt = l.t.double else { continue }
            var words: [LyricWord] = []
            for w in l.words.array {
                guard let text = w["text"].string, !text.isEmpty, let t = w.t.double else { continue }
                let d = max(w.d.double ?? 0, 0)
                words.append(LyricWord(text: text, start: t, end: t + max(d, 0.03), trailingSpace: w.space.bool ?? true))
            }
            guard !words.isEmpty else { continue }
            words[words.count - 1].trailingSpace = false
            let timed = l.words.array.contains { ($0.d.double ?? 0) > 0 }
            let text = words.map { $0.text + ($0.trailingSpace ? " " : "") }.joined()
            let end = lt + max(l.d.double ?? 0, 0)
            if !timed {
                // Line-timed only: spread the words over the line (shown a line at a time).
                let spread = LyricsService.spreadWords(text, from: lt, to: max(end, lt + 0.5))
                lines.append(LyricLine(id: lines.count, start: lt, end: max(end, lt + 0.5), text: text, words: spread, exactWords: false))
            } else {
                lines.append(LyricLine(id: lines.count, start: words[0].start, end: max(end, words.last!.end), text: text, words: words, exactWords: true))
            }
        }
        guard lines.count >= 2 else { return nil }
        let src = (j.source.string ?? "").replacingOccurrences(of: "Source:", with: "").trimmingCharacters(in: .whitespaces)
        return Lyrics(lines: LyricsService.withBreaks(lines), synced: true,
                      source: "Better Lyrics extension" + (src.isEmpty ? "" : " · \(src)"))
    }

    /// Opens YouTube Music's Lyrics tab (where Better Lyrics draws) and reads what's there:
    /// each line's start and length, and each word's start, length and following space,
    /// from the plain copy of the words (the extension draws a second copy for its highlight).
    private static let probeJS = #"""
    (() => {
      const tab = [...document.querySelectorAll('tp-yt-paper-tab')].find(e => /lyrics/i.test(e.textContent));
      if (tab && tab.getAttribute('aria-selected') !== 'true' && !tab.hasAttribute('disabled')) tab.click();
      const video = new URLSearchParams(location.search).get('v');
      const loader = document.getElementById('blyrics-loader');
      const container = document.querySelector('.blyrics-container');
      const done = !!container && (!loader || getComputedStyle(loader).display === 'none');
      const lines = [];
      for (const line of document.querySelectorAll('.blyrics-container .blyrics--line')) {
        if (line.classList.contains('blyrics--instrumental')) continue;
        const run = line.querySelector('.blyrics-line-main > .blyrics-bidi-run:not(.blyrics-highlight-run)');
        if (!run) continue;
        const words = [];
        for (const group of run.querySelectorAll('.blyrics-word-group')) {
          const parts = [...group.querySelectorAll('.blyrics--word')];
          const next = group.nextSibling;
          const spaceAfter = !!next && next.nodeType === 3 && /\s/.test(next.textContent);
          parts.forEach((w, i) => words.push({ text: (w.dataset.content || w.textContent || '').trim(),
            t: +w.dataset.time, d: +w.dataset.duration || 0, space: i === parts.length - 1 ? spaceAfter : false }));
        }
        lines.push({ t: +line.dataset.time, d: +line.dataset.duration || 0, words });
      }
      const source = (document.querySelector('.blyrics-footer__container') || {}).textContent || '';
      return JSON.stringify({ video, done, lines, source });
    })()
    """#
}

/// Just enough of the zip format to unpack an extension: stored and deflated entries.
enum Zip {
    enum Failure: Error { case malformed, unsupported(Int), unsafePath(String) }

    static func extract(_ data: Data, to dir: URL) throws {
        let b = [UInt8](data)
        func u16(_ o: Int) -> Int { Int(b[o]) | Int(b[o + 1]) << 8 }
        func u32(_ o: Int) -> Int { u16(o) | u16(o + 2) << 16 }
        // End of central directory: the last "PK\5\6".
        var eocd = b.count - 22
        while eocd >= 0, !(b[eocd] == 0x50 && b[eocd + 1] == 0x4b && b[eocd + 2] == 5 && b[eocd + 3] == 6) { eocd -= 1 }
        guard eocd >= 0 else { throw Failure.malformed }
        let count = u16(eocd + 10)
        var p = u32(eocd + 16)
        let root = dir.standardizedFileURL.path
        for _ in 0..<count {
            guard p + 46 <= b.count, u32(p) == 0x02014b50 else { throw Failure.malformed }
            let method = u16(p + 10), csize = u32(p + 20), nameLen = u16(p + 28), extraLen = u16(p + 30), commentLen = u16(p + 32)
            let local = u32(p + 42)
            guard let name = String(bytes: b[(p + 46)..<(p + 46 + nameLen)], encoding: .utf8) else { throw Failure.malformed }
            p += 46 + nameLen + extraLen + commentLen
            let target = dir.appendingPathComponent(name).standardizedFileURL
            guard target.path.hasPrefix(root + "/") else { throw Failure.unsafePath(name) }
            if name.hasSuffix("/") {
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true); continue
            }
            guard u32(local) == 0x04034b50 else { throw Failure.malformed }
            let start = local + 30 + u16(local + 26) + u16(local + 28)
            guard start + csize <= b.count else { throw Failure.malformed }
            let raw = Data(b[start..<(start + csize)])
            let body: Data
            switch method {
            case 0: body = raw
            case 8: body = try (raw as NSData).decompressed(using: .zlib) as Data   // raw deflate
            default: throw Failure.unsupported(method)
            }
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try body.write(to: target)
        }
    }
}
