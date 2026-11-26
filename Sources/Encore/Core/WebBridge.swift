import Foundation
import WebKit
import Combine
import QuartzCore

/// Owns the hidden WKWebViews that run music.youtube.com.
///
/// Playback is delegated to YouTube's own player inside the page, which means
/// stream deciphering, PoTokens, Premium quality and DRM are all handled by
/// Google's code. Native code only sends simple commands (load / play / seek)
/// and receives state events. If Google changes the page, the worst case is
/// that one command needs a tweak here; the stream itself keeps working.
///
/// Normally there is one page. While Crossfade is on there are two: the next song
/// starts on the other page and the two overlap, then that page becomes "the
/// player". Everything outside talks to whichever page is playing (`active`).
@MainActor
final class WebBridge: NSObject, ObservableObject {
    static let shared = WebBridge()

    static let origin = "https://music.youtube.com"
    /// A current Safari UA: Google refuses sign-in from UAs it doesn't recognise.
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.6 Safari/605.1.15"

    struct PlayerSnapshot: Equatable {
        var ready = false
        var state = -1        // -1 unstarted, 0 ended, 1 playing, 2 paused, 3 buffering, 5 cued
        var time: Double = 0
        var duration: Double = 0
        var videoId: String?
        var volume: Double = 100
        var muted = false
        var rate: Double = 1
        var hasVideo = false
        /// When `time` was measured (midpoint of the JS round trip).
        var measuredAt = Date()
    }

    struct ClientInfo {
        var clientVersion: String = "1.20251117.01.00"
        var visitorData: String?
        var hl: String = Locale.current.language.languageCode?.identifier ?? "en"
        var gl: String = Locale.current.region?.identifier ?? "US"
        var loggedIn = false
        var pageId: String?
    }

    private var pages: [PlayerPage] = []
    private var activeIndex = 0
    private var active: PlayerPage { pages[activeIndex] }
    private var standby: PlayerPage? { pages.count > 1 ? pages[1 - activeIndex] : nil }

    /// The page that's playing now (the one shown in video mode).
    var webView: WKWebView { active.webView }
    /// Every player page (two while Crossfade is on).
    var allWebViews: [WKWebView] { pages.map(\.webView) }

    @Published private(set) var pageLoaded = false
    @Published private(set) var snapshot = PlayerSnapshot()
    /// The second page is up and can start the next song.
    @Published private(set) var standbyReady = false
    /// A crossfade is starting or running.
    @Published private(set) var isCrossfading = false
    private(set) var client = ClientInfo()

    /// Called for discrete events: "ended", "playing", "pause", "videochange", "error".
    var onEvent: ((String, [String: Any]) -> Void)?

    private var pollTimer: Timer?

    override init() {
        super.init()
        pages = [PlayerPage(bridge: self)]
    }

    /// Lets WebKit use the page's Media Session for the Now Playing entry, so it
    /// shows the app's track info and previous/next buttons (instead of generic
    /// ±15 s skips). WebKit option, applied only when present.
    static func enableMediaSession(_ prefs: WKPreferences) {
        setPrivatePref(prefs, "_setMediaSessionEnabled:", true)
    }

    /// The player pages are never on screen, so WebKit would throttle their timers
    /// (to about once a second) whenever the app is in the background, slowing
    /// YouTube's player down there. They're music players: keep them running.
    static func disableBackgroundThrottling(_ prefs: WKPreferences) {
        setPrivatePref(prefs, "_setHiddenPageDOMTimerThrottlingEnabled:", false)
        setPrivatePref(prefs, "_setHiddenPageDOMTimerThrottlingAutoIncreases:", false)
        setPrivatePref(prefs, "_setPageVisibilityBasedProcessSuppressionEnabled:", false)
    }

    private static func setPrivatePref(_ prefs: WKPreferences, _ name: String, _ value: Bool) {
        let sel = NSSelectorFromString(name)
        guard prefs.responds(to: sel), let m = class_getInstanceMethod(type(of: prefs), sel) else { return }
        typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
        unsafeBitCast(method_getImplementation(m), to: Setter.self)(prefs, sel, value)
    }

    func start() {
        guard active.webView.url == nil else { return }
        active.load()
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
    }

    func reload() {
        pageLoaded = false
        active.loaded = false
        active.load()
    }

    /// Waits until the YTM app has booted (ytcfg + player present), up to `timeout`.
    func waitUntilReady(timeout: TimeInterval = 20) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !pageLoaded && Date() < deadline {
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
    }

    // MARK: - Cookies / auth

    func cookies() async -> [HTTPCookie] {
        await active.webView.configuration.websiteDataStore.httpCookieStore.allCookies()
            .filter { $0.domain.hasSuffix("youtube.com") }
    }

    var isSignedIn: Bool { client.loggedIn }

    func hasAuthCookies() async -> Bool {
        let names = Set(await cookies().map(\.name))
        return names.contains("SAPISID") || names.contains("__Secure-3PAPISID")
    }

    func signOut() async {
        let store = active.webView.configuration.websiteDataStore
        let records = await store.dataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes())
        await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), for: records)
        await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
        HTTPCookieStorage.shared.removeCookies(since: .distantPast)
        URLCache.shared.removeAllCachedResponses()
        UserDefaults.standard.removeObject(forKey: "savedQueue")
        client = ClientInfo()
        reload()
        if let s = standby { s.loaded = false; standbyReady = false; s.load() }
    }

    // MARK: - Player commands (to the page that's playing)

    @discardableResult
    func js(_ code: String) async -> Any? {
        guard pageLoaded else { return nil }
        return await active.js(code)
    }

    func load(videoId: String, playlistId: String? = nil, start: Double = 0) async {
        await waitUntilReady()
        for _ in 0..<40 {
            if (await js("!!(document.querySelector('#movie_player') && document.querySelector('#movie_player').loadVideoById)")) as? Bool == true { break }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        let pl = playlistId.map { "'\($0.jsEscaped)'" } ?? "null"
        _ = await js("window.__ytmac && window.__ytmac.load('\(videoId.jsEscaped)', \(pl), \(start))")
    }
    func play() { Task { await js("window.__ytmac && window.__ytmac.play()") } }
    func pause() { Task { await js("window.__ytmac && window.__ytmac.pause()") } }
    func seek(to t: Double) {
        snapshot.time = t
        Task { await js("window.__ytmac && window.__ytmac.seek(\(t))") }
    }
    func setVolume(_ v: Double) {
        cancelSingleFade()
        Task { await js("window.__ytmac && window.__ytmac.volume(\(Int(v.rounded())))") }
    }
    func setRate(_ r: Double) { Task { await js("window.__ytmac && window.__ytmac.rate(\(r))") } }
    func setVideoMode(_ on: Bool) { Task { await js("window.__ytmac && window.__ytmac.videoMode(\(on))") } }
    func setLoop(_ on: Bool) { Task { await js("window.__ytmac && window.__ytmac.setLoop(\(on))") } }
    func requestHD() { Task { await js("window.__ytmac && window.__ytmac.hd()") } }

    // MARK: - Volume fades (stepped from here, not by page timers)

    private var singleFade: DispatchSourceTimer?

    /// Moves the playing page's volume to `target` over `ms`, from `from` (or where it
    /// is now). Stepped by the app about 30 times a second, so it keeps its timing
    /// when the app is in the background (a page timer would be slowed to a crawl).
    func fade(from: Double? = nil, to target: Double, ms: Int) async {
        cancelSingleFade()
        let page = active
        let start = from ?? (snapshot.muted ? 0 : snapshot.volume)
        let length = Double(max(ms, 1)) / 1000
        let began = CACurrentMediaTime()
        var last = -1
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: .milliseconds(33), leeway: .milliseconds(4))
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                let p = min(1, (CACurrentMediaTime() - began) / length)
                let v = Int((start + (target - start) * p).rounded())
                if v != last { last = v; page.run("window.__ytmac && window.__ytmac.volume(\(v))") }
                if p >= 1 {
                    timer.cancel()
                    if self?.singleFade === timer { self?.singleFade = nil }
                }
            }
        }
        singleFade = timer
        timer.resume()
    }

    private func cancelSingleFade() {
        singleFade?.cancel()
        singleFade = nil
    }

    // MARK: - Crossfade (the second page)

    private var crossfadeGeneration = 0
    private var crossfadeRamp: DispatchSourceTimer?

    /// Creates the second page while Crossfade is on, and closes it when it's off
    /// (it holds a whole second YouTube Music page in memory).
    func setStandbyWanted(_ wanted: Bool) {
        if wanted, pages.count == 1 {
            let page = PlayerPage(bridge: self)
            pages.append(page)
            page.load()
            NotificationCenter.default.post(name: .playerPagesChanged, object: nil)
        } else if !wanted, let s = standby, !isCrossfading {
            let playing = active
            pages.removeAll { $0 === s }
            activeIndex = pages.firstIndex { $0 === playing } ?? 0
            s.close()
            standbyReady = false
            NotificationCenter.default.post(name: .playerPagesChanged, object: nil)
        }
    }

    /// Starts `videoId` on the second page and crossfades into it over `length` seconds
    /// (equal-power curves, so the overall loudness stays even). The moment the new
    /// song is really playing, its page becomes the player and `onSwap` runs; if it
    /// can't start, `onFail` runs and the current song carries on alone.
    func crossfade(to videoId: String, length: Double, target: @escaping () -> Double,
                   onSwap: @escaping () -> Void, onFail: @escaping () -> Void) {
        guard let next = standby, next.loaded, !isCrossfading else { onFail(); return }
        let old = active
        isCrossfading = true
        crossfadeGeneration += 1
        let gen = crossfadeGeneration
        let oldVolume = snapshot.muted ? 0 : snapshot.volume
        cancelSingleFade()
        Task {
            // Start silent (muted before any sound), then wait until it really plays.
            _ = await next.js("""
                (function(){ const p = document.querySelector('#movie_player');
                  window.__ytmac.setLoop(false);
                  try { p.mute(); p.setVolume(0); } catch (e) {}
                  window.__ytmac.load('\(videoId.jsEscaped)', null, 0);
                  try { p.mute(); p.setVolume(0); } catch (e) {}
                  return 0; })()
                """)
            var started = false
            let deadline = Date().addingTimeInterval(8)
            while Date() < deadline, gen == crossfadeGeneration {
                if let d = await next.js("window.__ytmac.state()") as? [String: Any],
                   (d["videoId"] as? String) == videoId,
                   (d["state"] as? NSNumber)?.intValue == 1,
                   ((d["time"] as? NSNumber)?.doubleValue ?? 0) > 0.02 {
                    started = true
                    break
                }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            guard gen == crossfadeGeneration else { return }       // cancelled meanwhile
            guard started else {
                isCrossfading = false
                next.run("window.__ytmac.pause()")
                onFail()
                return
            }
            PerfMonitor.note("crossfade: new song playing on the other player; swapping")
            // The new song is playing (silently): its page becomes the player.
            old.run("window.__ytmac.setLoop(false); window.__ytmacNP && window.__ytmacNP({ meta: null, state: 'none' })")
            activeIndex = pages.firstIndex { $0 === next } ?? activeIndex
            NotificationCenter.default.post(name: .playerPageSwapped, object: nil)
            onSwap()
            poll()
            runCrossfadeRamp(gen: gen, old: old, new: next, oldFrom: oldVolume, length: length, target: target)
        }
    }

    private func runCrossfadeRamp(gen: Int, old: PlayerPage, new: PlayerPage, oldFrom: Double,
                                  length: Double, target: @escaping () -> Double) {
        let began = CACurrentMediaTime()
        var lastOld = -1, lastNew = -1, step = 0
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: .milliseconds(33), leeway: .milliseconds(4))
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self, gen == self.crossfadeGeneration else { timer.cancel(); return }
                let p = min(1, (CACurrentMediaTime() - began) / max(length, 0.05))
                let a = p * Double.pi / 2
                let nv = Int((target() * sin(a)).rounded())
                let ov = Int((oldFrom * cos(a)).rounded())
                if nv != lastNew { lastNew = nv; new.run("window.__ytmac.volume(\(nv))") }
                if ov != lastOld { lastOld = ov; old.run("window.__ytmac.volume(\(ov))") }
                step += 1
                if step % 15 == 1 { PerfMonitor.note(String(format: "crossfade ramp %.0f%%: new %d, old %d", p * 100, nv, ov)) }
                // Developer log: are both players really playing mid-crossfade?
                if step == 45, UserDefaults.standard.bool(forKey: "perfLog") {
                    Task {
                        let o = await old.evaluate("(()=>{const s=window.__ytmac.state();return s.state+'@'+s.time.toFixed(1)})()") as? String ?? "?"
                        let n = await new.evaluate("(()=>{const s=window.__ytmac.state();return s.state+'@'+s.time.toFixed(1)})()") as? String ?? "?"
                        PerfMonitor.note("crossfade mid-check: old player \(o), new player \(n) (state 1 = playing)")
                    }
                }
                if p >= 1 {
                    timer.cancel()
                    self.crossfadeRamp = nil
                    old.run("window.__ytmac.pause()")
                    self.isCrossfading = false
                    PerfMonitor.note("crossfade done: old player paused")
                }
            }
        }
        crossfadeRamp = timer
        timer.resume()
    }

    /// Stops a crossfade where it is (you paused, skipped, picked another song): the
    /// other page stops, and the playing one goes to `volume`.
    func cancelCrossfade(volume: Double) {
        guard isCrossfading else { return }
        crossfadeGeneration += 1
        crossfadeRamp?.cancel()
        crossfadeRamp = nil
        isCrossfading = false
        standby?.run("window.__ytmac && window.__ytmac.pause()")
        active.run("window.__ytmac && window.__ytmac.volume(\(Int(volume.rounded())))")
        if UserDefaults.standard.bool(forKey: "perfLog") {
            let (a, b) = (active, standby)
            Task {
                try? await Task.sleep(nanoseconds: 600_000_000)
                let q = "(()=>{const s=window.__ytmac.state();return s.state+' vol '+s.volume})()"
                let x = await a.evaluate(q) as? String ?? "?"
                let y = await b?.evaluate(q) as? String ?? "-"
                PerfMonitor.note("crossfade cancelled: playing player \(x), other player \(y) (2 = paused)")
            }
        }
    }

    // MARK: - State

    /// Reads the playing page's state now (normally every 0.2 s).
    func poll() {
        guard pageLoaded else { return }
        let sent = Date()
        active.webView.evaluateJavaScript("window.__ytmac ? window.__ytmac.state() : null") { [weak self] result, _ in
            guard let self, let d = result as? [String: Any] else { return }
            let received = Date()
            var s = PlayerSnapshot()
            s.measuredAt = sent.addingTimeInterval(received.timeIntervalSince(sent) / 2)
            s.ready = d["ready"] as? Bool ?? false
            s.state = (d["state"] as? NSNumber)?.intValue ?? -1
            s.time = (d["time"] as? NSNumber)?.doubleValue ?? 0
            s.duration = (d["duration"] as? NSNumber)?.doubleValue ?? 0
            s.videoId = d["videoId"] as? String
            s.volume = (d["volume"] as? NSNumber)?.doubleValue ?? 100
            s.muted = d["muted"] as? Bool ?? false
            s.rate = (d["rate"] as? NSNumber)?.doubleValue ?? 1
            s.hasVideo = d["hasVideo"] as? Bool ?? false
            if s != self.snapshot { self.snapshot = s }
        }
    }

    fileprivate func handle(message: Any, from page: PlayerPage) {
        guard let d = message as? [String: Any], let type = d["type"] as? String else { return }
        if type == "remote" {   // a Control Center / media-key / AirPods button, from either page
            NowPlayingService.shared.handleRemote(action: d["action"] as? String ?? "", seekTime: d["seekTime"] as? Double)
            return
        }
        if type == "boot" {
            if page === active { Task { await refreshClientInfo() } } else { standbyDidBoot(page) }
            return
        }
        if type == "youthere" { PerfMonitor.note("youthere prompt answered on the \(page === active ? "playing" : "second") player") }
        // Only the playing page's song concerns the app (the other one is fading
        // out, or waiting for the next song).
        guard page === active else { return }
        onEvent?(type, d)
    }

    fileprivate func pageDidLoad(_ page: PlayerPage) async {
        if page === active {
            await refreshClientInfo()
        } else if (await page.evaluate("!!(window.ytcfg && document.querySelector('#movie_player'))")) as? Bool == true {
            standbyDidBoot(page)
        }
    }

    private func standbyDidBoot(_ page: PlayerPage) {
        guard page !== active, !page.loaded else { return }
        PerfMonitor.note("crossfade: second player ready")
        page.loaded = true
        standbyReady = true
        NotificationCenter.default.post(name: .playerPagesChanged, object: nil)
    }

    fileprivate func pageCrashed(_ page: PlayerPage) {
        if page === active {
            // Recover from a crashed web process instead of silently going quiet.
            pageLoaded = false
            reload()
            onEvent?("crashed", [:])
        } else {
            page.loaded = false
            standbyReady = false
            if isCrossfading { cancelCrossfade(volume: snapshot.volume) }
            page.load()
        }
    }

    func refreshClientInfo() async {
        let r = await active.evaluate("""
        (function(){ try { const g = (k)=>window.ytcfg && ytcfg.get(k);
          return JSON.stringify({v:g('INNERTUBE_CLIENT_VERSION'), vd:g('VISITOR_DATA'), hl:g('HL'), gl:g('GL'),
            li:g('LOGGED_IN'), pid:g('DELEGATED_SESSION_ID')}); } catch(e) { return null } })()
        """)
        guard let s = r as? String, let j = try? JSON(data: Data(s.utf8)) else { return }
        if let v = j.v.string { client.clientVersion = v }
        if let v = j.vd.string { client.visitorData = v }
        if let v = j.hl.string { client.hl = v }
        if let v = j.gl.string { client.gl = v }
        client.loggedIn = j.li.bool ?? false
        client.pageId = j.pid.string
        active.loaded = true
        if !pageLoaded { pageLoaded = true }
        NotificationCenter.default.post(name: .ytBridgeReady, object: nil)
    }

    fileprivate static func policy(for navigationAction: WKNavigationAction) -> WKNavigationActionPolicy {
        // Keep the hidden player on music.youtube.com; open anything else externally.
        guard let url = navigationAction.request.url else { return .cancel }
        if url.scheme == "about" || url.scheme == "blob" || url.scheme == "data" { return .allow }
        guard url.scheme == "https", let host = url.host else { return .cancel }
        if navigationAction.targetFrame?.isMainFrame == false { return .allow }
        // Exact domains or real subdomains only ("evilyoutube.com" must not pass).
        let trusted = ["youtube.com", "google.com", "gstatic.com"]
        if trusted.contains(where: { host == $0 || host.hasSuffix("." + $0) }) { return .allow }
        return .cancel
    }
}

extension Notification.Name {
    static let ytBridgeReady = Notification.Name("ytBridgeReady")
    /// A player page was added or removed (Crossfade turned on or off).
    static let playerPagesChanged = Notification.Name("playerPagesChanged")
    /// The other page became the player (a crossfade started the next song on it).
    static let playerPageSwapped = Notification.Name("playerPageSwapped")
}

/// One hidden music.youtube.com page with its own YouTube player.
@MainActor
final class PlayerPage: NSObject, WKNavigationDelegate {
    let webView: WKWebView
    /// The YouTube Music app inside has booted (ytcfg and the player exist).
    var loaded = false
    weak var bridge: WebBridge?

    init(bridge: WebBridge) {
        self.bridge = bridge
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()   // persistent cookies = stays signed in
        config.mediaTypesRequiringUserActionForPlayback = []
        config.preferences.isElementFullscreenEnabled = true
        WebBridge.enableMediaSession(config.preferences)
        WebBridge.disableBackgroundThrottling(config.preferences)
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        let ucc = WKUserContentController()
        ucc.addUserScript(WKUserScript(source: WebBridge.injectedJS, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        ucc.addUserScript(WKUserScript(source: WebBridge.injectedCSSJS, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        config.userContentController = ucc
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1280, height: 720), configuration: config)
        super.init()
        webView.customUserAgent = WebBridge.userAgent
        webView.navigationDelegate = self
        webView.underPageBackgroundColor = .black
        webView.setValue(false, forKey: "drawsBackground")
        ucc.add(WeakHandler(self), name: "ytmac")
    }

    func load() {
        webView.load(URLRequest(url: URL(string: WebBridge.origin + "/")!))
    }

    /// Runs script once the page has booted (nil before).
    func js(_ code: String) async -> Any? {
        guard loaded else { return nil }
        return try? await webView.evaluateJavaScript(code)
    }

    /// Runs script whether or not the page has booted.
    func evaluate(_ code: String) async -> Any? {
        try? await webView.evaluateJavaScript(code)
    }

    /// Fire-and-forget (the fast volume steps of a fade).
    func run(_ code: String) {
        guard loaded else { return }
        webView.evaluateJavaScript(code, completionHandler: nil)
    }

    /// Takes the page down for good (Crossfade turned off).
    func close() {
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "ytmac")
        webView.removeFromSuperview()
        loaded = false
    }

    fileprivate func received(_ body: Any) { bridge?.handle(message: body, from: self) }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            // ytcfg is available once the document has loaded.
            try? await Task.sleep(nanoseconds: 300_000_000)
            await self.bridge?.pageDidLoad(self)
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        WebBridge.policy(for: navigationAction)
    }

    nonisolated func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        Task { @MainActor in self.bridge?.pageCrashed(self) }
    }
}

private final class WeakHandler: NSObject, WKScriptMessageHandler {
    weak var page: PlayerPage?
    init(_ p: PlayerPage) { page = p }
    func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
        // Only YouTube Music's own page may talk to the app.
        guard message.frameInfo.isMainFrame, message.frameInfo.securityOrigin.protocol == "https",
              message.frameInfo.securityOrigin.host == "music.youtube.com" else { return }
        let body = message.body
        Task { @MainActor in self.page?.received(body) }
    }
}

extension String {
    var jsEscaped: String {
        replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: "\\n")
    }
}

// MARK: - Injected page scripts

extension WebBridge {
    static let injectedJS = #"""
    (() => {
      if (window.__ytmac) return;
      const post = (m) => { try { window.webkit.messageHandlers.ytmac.postMessage(m); } catch (e) {} };

      // The page is never "visible" to the user, so pretend it is: avoids
      // background throttling and the "Video paused. Continue watching?" prompt.
      try {
        Object.defineProperty(document, 'hidden', { get: () => false, configurable: true });
        Object.defineProperty(document, 'visibilityState', { get: () => 'visible', configurable: true });
        document.addEventListener('visibilitychange', e => e.stopImmediatePropagation(), true);
      } catch (e) {}

      // One Now Playing entry, owned by the app. WebKit publishes this page's Media
      // Session to Control Center whatever we do, so instead of adding a second
      // entry natively, take the session over: YouTube's own metadata, buttons and
      // position are ignored, the app supplies them (window.__ytmacNP), and every
      // button is routed to the app's queue.
      try {
        const ms = navigator.mediaSession;
        if (ms && window.MediaSession) {
          const P = MediaSession.prototype;
          const mdSet = Object.getOwnPropertyDescriptor(P, 'metadata').set;
          const psSet = Object.getOwnPropertyDescriptor(P, 'playbackState').set;
          const setHandler = P.setActionHandler.bind(ms);
          const setPos = P.setPositionState ? P.setPositionState.bind(ms) : null;
          let md = null, ps = 'none';
          Object.defineProperty(ms, 'metadata', { get: () => md, set: () => {}, configurable: true });
          Object.defineProperty(ms, 'playbackState', { get: () => ps, set: () => {}, configurable: true });
          ms.setActionHandler = () => {};
          ms.setPositionState = () => {};
          const route = (action) => (d) => post({ type: 'remote', action, seekTime: d && d.seekTime });
          for (const a of ['play', 'pause', 'stop', 'previoustrack', 'nexttrack', 'seekto']) {
            try { setHandler(a, route(a)); } catch (e) {}
          }
          for (const a of ['seekforward', 'seekbackward']) { try { setHandler(a, null); } catch (e) {} }
          window.__ytmacNP = (o) => {
            try {
              if (o.meta !== undefined) {
                md = o.meta ? new MediaMetadata({ title: o.meta.title, artist: o.meta.artist, album: o.meta.album || '',
                                                  artwork: o.meta.art ? [{ src: o.meta.art, sizes: '544x544' }] : [] }) : null;
                mdSet.call(ms, md);
              }
              if (o.state) { ps = o.state; psSet.call(ms, ps); }
              if (o.pos && setPos && o.pos.duration > 0) {
                setPos({ duration: o.pos.duration, position: Math.max(0, Math.min(o.pos.position, o.pos.duration)), playbackRate: o.pos.rate || 1 });
              }
            } catch (e) {}
          };
        }
      } catch (e) {}
      setInterval(() => {
        window._lact = Date.now();
        const dlg = document.querySelector('ytmusic-you-there-renderer');
        if (dlg && dlg.offsetParent !== null) {
          const b = dlg.querySelector('button, yt-button-renderer, #button');
          post({ type: 'youthere', clicked: !!b });
          if (b) b.click();
          const p = document.querySelector('#movie_player');
          if (p && p.playVideo) p.playVideo();
        }
      }, 2000);

      const player = () => document.querySelector('#movie_player');
      const video = () => document.querySelector('video');
      let expected = null;      // videoId the native side asked for
      let lastId = null;

      const api = {
        state() {
          const p = player(); const v = video();
          if (!p || !p.getPlayerState) return { ready: false };
          let d = {}; try { d = p.getVideoData() || {}; } catch (e) {}
          const dur = v && isFinite(v.duration) && v.duration > 0 ? v.duration : (p.getDuration ? p.getDuration() : 0);
          return {
            ready: true,
            state: p.getPlayerState(),
            time: v ? v.currentTime : p.getCurrentTime(),
            duration: dur || 0,
            videoId: d.video_id || null,
            volume: p.getVolume ? p.getVolume() : 100,
            muted: p.isMuted ? p.isMuted() : false,
            rate: v ? v.playbackRate : 1,
            hasVideo: !!(v && v.videoWidth > 0),
          };
        },
        load(id, playlistId, start) {
          expected = id;
          const p = player();
          if (p && p.loadVideoById) {
            try {
              p.loadVideoById({ videoId: id, startSeconds: start || 0 });
              return 'api';
            } catch (e) {}
          }
          location.href = '/watch?v=' + encodeURIComponent(id) + (playlistId ? '&list=' + encodeURIComponent(playlistId) : '');
          return 'nav';
        },
        play() { const p = player(); if (p && p.playVideo) p.playVideo(); else { const v = video(); v && v.play(); } },
        pause() { const p = player(); if (p && p.pauseVideo) p.pauseVideo(); else { const v = video(); v && v.pause(); } },
        seek(t) { const p = player(); if (p && p.seekTo) p.seekTo(t, true); else { const v = video(); if (v) v.currentTime = t; } },
        volume(v) { const p = player(); if (p && p.setVolume) { p.setVolume(v); if (v > 0 && p.unMute) p.unMute(); } },
        rate(r) { const v = video(); if (v) v.playbackRate = r; const p = player(); if (p && p.setPlaybackRate) p.setPlaybackRate(r); },
        // Video mode: draw the playing <video>'s frames onto a full-viewport
        // canvas at <html> level. Works regardless of YouTube Music's own page
        // layout, and never navigates or touches the player, so audio continues.
        // Ask YouTube's player for HD. It picks quality from its own on-page size, so
        // give it a full-HD size too (it's never shown — we draw its frames ourselves).
        hd() {
          const p = player(); if (!p) return;
          try { if (p.setSize) p.setSize(1920, 1080); } catch (e) {}
          try { if (p.setPlaybackQualityRange) p.setPlaybackQualityRange('hd1080', 'highres'); } catch (e) {}
          try { if (p.setPlaybackQuality) p.setPlaybackQuality('hd1080'); } catch (e) {}
        },
        // Repeat one: the song restarts from here, a moment before it ends (see below).
        setLoop(on) { window.__ytmacLoop = !!on; },
        // Smooth volume ramp (0–100) over ms, so switching streams never clicks.
        fade(target, ms) {
          const p = player(); if (!p || !p.setVolume) return;
          clearInterval(window.__ytmacFade);
          const from = p.isMuted && p.isMuted() ? 0 : p.getVolume(); const steps = Math.max(1, Math.round(ms / 16)); let i = 0;
          if (target > 0 && p.unMute) p.unMute();
          window.__ytmacFade = setInterval(() => {
            i++; const v = from + (target - from) * (i / steps);
            p.setVolume(Math.round(v));
            if (i >= steps) clearInterval(window.__ytmacFade);
          }, 16);
        },
        videoMode(on) {
          if (on) api.hd();
          let cv = document.getElementById('ytmac-video');
          if (!on) { window.__ytmacVideo = false; if (cv) cv.style.display = 'none'; return; }
          if (!cv) {
            cv = document.createElement('canvas');
            cv.id = 'ytmac-video';
            cv.style.cssText = 'position:fixed;left:0;top:0;width:100vw;height:100vh;z-index:2147483647;background:#000;display:block;pointer-events:none;';
            document.documentElement.appendChild(cv);
          }
          cv.style.display = 'block';
          const ctx = cv.getContext('2d', { alpha: false });
          window.__ytmacVideo = true;
          const gen = (window.__ytmacVideoGen = (window.__ytmacVideoGen || 0) + 1);
          let last = 0;
          const draw = () => {
            if (!window.__ytmacVideo || gen !== window.__ytmacVideoGen) return;
            const v = video();
            const dpr = window.devicePixelRatio || 1;
            const W = Math.round(innerWidth * dpr), H = Math.round(innerHeight * dpr);
            if (cv.width !== W || cv.height !== H) { cv.width = W; cv.height = H; }
            ctx.fillStyle = '#000'; ctx.fillRect(0, 0, W, H);
            if (v && v.videoWidth) {
              const sc = Math.min(W / v.videoWidth, H / v.videoHeight);
              const w = v.videoWidth * sc, h = v.videoHeight * sc;
              ctx.imageSmoothingQuality = 'high';
              ctx.drawImage(v, (W - w) / 2, (H - h) / 2, w, h);
            }
            last = performance.now();
            if (v && v.requestVideoFrameCallback && !v.paused) v.requestVideoFrameCallback(draw);
            else requestAnimationFrame(draw);
          };
          draw();
          // Restart the loop if the <video> element is swapped or frames stop arriving.
          clearInterval(window.__ytmacVideoWatch);
          window.__ytmacVideoWatch = setInterval(() => {
            if (!window.__ytmacVideo) { clearInterval(window.__ytmacVideoWatch); return; }
            if (performance.now() - last > 400) draw();
          }, 300);
        },
      };
      window.__ytmac = api;

      // Media events don't bubble, but they do reach capture listeners.
      // While YouTube plays an ad (free accounts), the media element is the ad: its
      // ending or failing says nothing about the song, so those aren't reported.
      const adShowing = () => !!document.querySelector('#movie_player.ad-showing, #movie_player.ad-interrupting');
      const relay = (type) => document.addEventListener(type, (e) => {
        if (!(e.target instanceof HTMLMediaElement)) return;
        if ((type === 'ended' || type === 'error') && adShowing()) return;
        let id = null; try { id = player().getVideoData().video_id; } catch (x) {}
        post({ type, videoId: id, expected, time: e.target.currentTime, duration: e.target.duration });
      }, true);
      ['ended', 'playing', 'pause', 'error', 'waiting'].forEach(relay);

      // Song endings are handled a moment before the media element actually ends, so
      // YouTube's own autoplay never gets to start a different song first:
      //  - repeat one: jump straight back to the start (a gapless loop);
      //  - otherwise: tell the app now, so it loads the next song itself.
      let endSentFor = null;
      const endNow = (v) => {
        if (adShowing()) return;
        // Only the song itself: its length must match the one the player reports.
        const p0 = player();
        if (p0 && p0.getDuration) { const pd = p0.getDuration(); if (pd > 0 && Math.abs(pd - v.duration) > 3) return; }
        if (window.__ytmacLoop) {
          const p = player();
          if (p && p.seekTo) p.seekTo(0, true); else v.currentTime = 0;
          return;
        }
        let id = null; try { id = player().getVideoData().video_id; } catch (x) {}
        if (endSentFor === id) return;
        endSentFor = id;
        post({ type: 'ended', videoId: id, expected, time: v.currentTime, duration: v.duration });
      };
      document.addEventListener('timeupdate', (e) => {
        const v = e.target; if (!(v instanceof HTMLMediaElement)) return;
        const d = v.duration, t = v.currentTime;
        if (!isFinite(d) || d < 3) return;
        if (d - t > 0.35) { endSentFor = null; return; }
        endNow(v);
      }, true);


      setInterval(() => {
        let id = null; try { id = player().getVideoData().video_id; } catch (x) {}
        if (id && id !== lastId) { lastId = id; post({ type: 'videochange', videoId: id, expected }); }
      }, 500);

      const boot = setInterval(() => {
        if (window.ytcfg && document.querySelector('#movie_player')) { clearInterval(boot); post({ type: 'boot' }); }
      }, 300);
    })();
    """#

    static let injectedCSSJS = #"""
    (() => {
      const s = document.createElement('style');
      s.textContent = `
        html.ytmac-video ytmusic-player, html.ytmac-video #player.ytmusic-player-page {
          position: fixed !important; inset: 0 !important; width: 100vw !important; height: 100vh !important;
          max-width: none !important; max-height: none !important; margin: 0 !important;
          z-index: 2147483000 !important; background: #000 !important; display: block !important; visibility: visible !important;
        }
        html.ytmac-video #movie_player, html.ytmac-video .html5-video-container, html.ytmac-video video {
          width: 100vw !important; height: 100vh !important; left: 0 !important; top: 0 !important; object-fit: contain !important;
        }
        html.ytmac-video .ytp-chrome-bottom, html.ytmac-video .ytp-chrome-top, html.ytmac-video .ytp-gradient-bottom,
        html.ytmac-video .ytp-gradient-top, html.ytmac-video .ytp-pause-overlay, html.ytmac-video .song-media-controls { display: none !important; }
        html.ytmac-video body { overflow: hidden !important; background: #000 !important; }
        /* Nobody sees this page: skip rendering YouTube's own feed, search page,
           sidebar and top bar (artwork grids etc.) so the hidden page uses less
           memory and CPU. The player itself is untouched. */
        ytmusic-browse-response, ytmusic-search-page, ytmusic-guide-renderer, #guide-wrapper,
        ytmusic-nav-bar, ytmusic-tab-renderer #contents {
          content-visibility: hidden !important; contain-intrinsic-size: 0 0 !important;
        }
      `;
      (document.head || document.documentElement).appendChild(s);
    })();
    """#
}
