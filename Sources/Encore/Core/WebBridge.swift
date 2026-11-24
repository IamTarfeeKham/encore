import Foundation
import WebKit
import Combine

/// Owns the single hidden WKWebView that runs music.youtube.com.
///
/// Playback is delegated to YouTube's own player inside that page, which means
/// stream deciphering, PoTokens, Premium quality and DRM are all handled by
/// Google's code. Native code only sends simple commands (load / play / seek)
/// and receives state events. If Google changes the page, the worst case is
/// that one command needs a tweak here; the stream itself keeps working.
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

    let webView: WKWebView
    @Published private(set) var pageLoaded = false
    @Published private(set) var snapshot = PlayerSnapshot()
    private(set) var client = ClientInfo()

    /// Called for discrete events: "ended", "playing", "pause", "videochange", "error".
    var onEvent: ((String, [String: Any]) -> Void)?

    private var pollTimer: Timer?

    override init() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()   // persistent cookies = stays signed in
        config.mediaTypesRequiringUserActionForPlayback = []
        config.preferences.isElementFullscreenEnabled = true
        WebBridge.enableMediaSession(config.preferences)
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

    /// Lets WebKit use the page's Media Session for the Now Playing entry, so it
    /// shows the app's track info and previous/next buttons (instead of generic
    /// ±15 s skips). WebKit option, applied only when present.
    static func enableMediaSession(_ prefs: WKPreferences) {
        let sel = NSSelectorFromString("_setMediaSessionEnabled:")
        guard prefs.responds(to: sel), let m = class_getInstanceMethod(type(of: prefs), sel) else { return }
        typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
        unsafeBitCast(method_getImplementation(m), to: Setter.self)(prefs, sel, true)
    }

    func start() {
        guard webView.url == nil else { return }
        webView.load(URLRequest(url: URL(string: WebBridge.origin + "/")!))
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
    }

    func reload() {
        pageLoaded = false
        webView.load(URLRequest(url: URL(string: WebBridge.origin + "/")!))
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
        await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
            .filter { $0.domain.hasSuffix("youtube.com") }
    }

    var isSignedIn: Bool { client.loggedIn }

    func hasAuthCookies() async -> Bool {
        let names = Set(await cookies().map(\.name))
        return names.contains("SAPISID") || names.contains("__Secure-3PAPISID")
    }

    func signOut() async {
        let store = webView.configuration.websiteDataStore
        let records = await store.dataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes())
        await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), for: records)
        await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
        HTTPCookieStorage.shared.removeCookies(since: .distantPast)
        URLCache.shared.removeAllCachedResponses()
        UserDefaults.standard.removeObject(forKey: "savedQueue")
        client = ClientInfo()
        reload()
    }

    // MARK: - Player commands

    @discardableResult
    func js(_ code: String) async -> Any? {
        guard pageLoaded else { return nil }
        return try? await webView.evaluateJavaScript(code)
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
    func setVolume(_ v: Double) { Task { await js("window.__ytmac && window.__ytmac.volume(\(Int(v.rounded())))") } }
    func setRate(_ r: Double) { Task { await js("window.__ytmac && window.__ytmac.rate(\(r))") } }
    func setVideoMode(_ on: Bool) { Task { await js("window.__ytmac && window.__ytmac.videoMode(\(on))") } }
    func fade(to volume: Double, ms: Int) async { await js("window.__ytmac && window.__ytmac.fade(\(Int(volume.rounded())), \(ms))") }
    func requestHD() { Task { await js("window.__ytmac && window.__ytmac.hd()") } }

    private func poll() {
        guard pageLoaded else { return }
        let sent = Date()
        webView.evaluateJavaScript("window.__ytmac ? window.__ytmac.state() : null") { [weak self] result, _ in
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

    fileprivate func handle(message: Any) {
        guard let d = message as? [String: Any], let type = d["type"] as? String else { return }
        if type == "boot" {
            Task { await refreshClientInfo() }
            return
        }
        if type == "remote" {   // a Control Center / media-key / AirPods button
            NowPlayingService.shared.handleRemote(action: d["action"] as? String ?? "", seekTime: d["seekTime"] as? Double)
            return
        }
        onEvent?(type, d)
    }

    func refreshClientInfo() async {
        let r = try? await webView.evaluateJavaScript("""
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
        if !pageLoaded { pageLoaded = true }
        NotificationCenter.default.post(name: .ytBridgeReady, object: nil)
    }
}

extension Notification.Name {
    static let ytBridgeReady = Notification.Name("ytBridgeReady")
}

extension WebBridge: WKNavigationDelegate {
    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            // ytcfg is available once the document has loaded.
            try? await Task.sleep(nanoseconds: 300_000_000)
            await self.refreshClientInfo()
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        // Keep the hidden player on music.youtube.com; open anything else externally.
        guard let url = navigationAction.request.url else { return .cancel }
        if url.scheme == "about" || url.scheme == "blob" || url.scheme == "data" { return .allow }
        guard url.scheme == "https", let host = url.host else { return .cancel }
        if navigationAction.targetFrame?.isMainFrame == false { return .allow }
        if host.hasSuffix("youtube.com") || host.hasSuffix("google.com") || host.hasSuffix("gstatic.com") {
            return .allow
        }
        return .cancel
    }

    nonisolated func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        // Recover from a crashed web process instead of silently going quiet.
        Task { @MainActor in
            self.pageLoaded = false
            self.reload()
            self.onEvent?("crashed", [:])
        }
    }
}

private final class WeakHandler: NSObject, WKScriptMessageHandler {
    weak var bridge: WebBridge?
    init(_ b: WebBridge) { bridge = b }
    func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
        let body = message.body
        Task { @MainActor in self.bridge?.handle(message: body) }
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
        // Equaliser: route the <video> through Web Audio filters. Audio is only
        // rerouted once the AudioContext is confirmed running (so it can never go
        // silent), and never at all while the EQ is off/flat.
        eq(freqs, gains, enabled) {
          const v = video(); if (!v) return 'novideo';
          const st = window.__ytmacEQ;
          const needed = enabled && gains.some(g => Math.abs(g) > 0.01);
          if (!st && !needed) return 'skip';
          if (!st || st.el !== v) {
            const ac = new (window.AudioContext || window.webkitAudioContext)();
            ac.resume().then(() => {
              if (ac.state !== 'running') { ac.close(); return; }
              try {
                const src = ac.createMediaElementSource(v);
                const pre = ac.createGain();
                const filters = freqs.map((f, i) => {
                  const b = ac.createBiquadFilter();
                  b.type = i === 0 ? 'lowshelf' : (i === freqs.length - 1 ? 'highshelf' : 'peaking');
                  b.frequency.value = f; b.Q.value = 1.0; b.gain.value = 0; return b;
                });
                src.connect(pre); let n = pre; filters.forEach(f => { n.connect(f); n = f; }); n.connect(ac.destination);
                window.__ytmacEQ = { ac, el: v, filters, pre };
                api.eq(freqs, gains, enabled);
              } catch (e) { ac.close(); }
            }).catch(() => {});
            return 'starting';
          }
          const t = st.ac.currentTime;
          st.filters.forEach((f, i) => f.gain.setTargetAtTime(enabled ? (gains[i] || 0) : 0, t, 0.04));
          const boost = enabled ? Math.max(0, ...gains) : 0;           // headroom so boosts don't clip
          st.pre.gain.setTargetAtTime(Math.pow(10, -boost * 0.7 / 20), t, 0.04);
          if (st.ac.state !== 'running') st.ac.resume();
          return 'ok';
        },
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
      const relay = (type) => document.addEventListener(type, (e) => {
        if (!(e.target instanceof HTMLMediaElement)) return;
        let id = null; try { id = player().getVideoData().video_id; } catch (x) {}
        post({ type, videoId: id, expected, time: e.target.currentTime, duration: e.target.duration });
      }, true);
      ['ended', 'playing', 'pause', 'error', 'waiting'].forEach(relay);

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
