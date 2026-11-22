import SwiftUI
import WebKit

struct SignInPrompt: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        ZStack {
            Rectangle().fill(.regularMaterial).ignoresSafeArea()
            VStack(spacing: 18) {
                Image(systemName: "music.note.house.fill")
                    .font(.system(size: 54))
                    .foregroundStyle(.linearGradient(colors: [.pink, .red], startPoint: .top, endPoint: .bottom))
                Text("Sign in to YouTube Music").font(.system(size: 26, weight: .bold))
                Text("Your library, playlists, likes and recommendations come from your own account.\nYour password is entered on Google's page and is never seen by this app.")
                    .multilineTextAlignment(.center).foregroundStyle(.secondary)
                HStack {
                    Button("Sign In…") { model.showSignIn = true }
                        .buttonStyle(.borderedProminent).controlSize(.large)
                    Button("Continue Without Signing In") { model.signedIn = nil }
                        .buttonStyle(.bordered).controlSize(.large)
                }
            }
            .padding(40)
        }
    }
}

/// Google sign-in in a visible web view that shares the hidden player's cookie store.
struct SignInView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Sign in with Google").font(.headline)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(12)
            Divider()
            SignInWebView {
                dismiss()
                WebBridge.shared.reload()
                Task {
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    await model.refreshAccount()
                }
            }
        }
        .frame(width: 520, height: 680)
    }
}

struct SignInWebView: NSViewRepresentable {
    let onSignedIn: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onSignedIn: onSignedIn) }

    /// Google's standard YouTube Music sign-in entry point.
    static var signInURL: URL {
        var next = URLComponents(string: "https://www.youtube.com/signin")!
        next.queryItems = [URLQueryItem(name: "action_handle_signin", value: "true"),
                           URLQueryItem(name: "app", value: "desktop"),
                           URLQueryItem(name: "next", value: "https://music.youtube.com/")]
        var c = URLComponents(string: "https://accounts.google.com/ServiceLogin")!
        c.queryItems = [URLQueryItem(name: "service", value: "youtube"),
                        URLQueryItem(name: "ltmpl", value: "music"),
                        URLQueryItem(name: "passive", value: "true"),
                        URLQueryItem(name: "continue", value: next.url!.absoluteString)]
        return c.url!
    }

    /// Hosts the sign-in flow may load. Anything else opens in the default browser.
    static func isAllowedHost(_ host: String) -> Bool {
        let allowed = ["google.com", "youtube.com", "gstatic.com", "googleusercontent.com", "ggpht.com",
                       "googleapis.com", "youtube-nocookie.com", "ytimg.com", "recaptcha.net"]
        return allowed.contains { host == $0 || host.hasSuffix("." + $0) }
            || host.range(of: #"^(www\.|accounts\.)?google\.[a-z.]+$"#, options: .regularExpression) != nil
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        let web = WKWebView(frame: .zero, configuration: config)
        web.customUserAgent = WebBridge.userAgent
        web.navigationDelegate = context.coordinator
        web.uiDelegate = context.coordinator
        context.coordinator.attach(web)
        web.load(URLRequest(url: Self.signInURL))
        return web
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) { coordinator.detach() }

    /// Finishes sign-in as soon as YouTube's session cookies exist, no matter
    /// which page Google lands on (youtube.com, music.youtube.com, a
    /// "Continue" interstitial…), so the user never ends up browsing the website here.
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKHTTPCookieStoreObserver {
        let onSignedIn: () -> Void
        private var done = false
        private weak var web: WKWebView?
        private var timer: Timer?

        init(onSignedIn: @escaping () -> Void) { self.onSignedIn = onSignedIn }

        func attach(_ web: WKWebView) {
            self.web = web
            web.configuration.websiteDataStore.httpCookieStore.add(self)
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.check() }
        }

        func detach() {
            timer?.invalidate()
            web?.configuration.websiteDataStore.httpCookieStore.remove(self)
        }

        func cookiesDidChange(in cookieStore: WKHTTPCookieStore) { check() }

        private var handoffs = 0
        private var lastHandoff = Date.distantPast

        private func check() {
            guard !done, let web else { return }
            let url = web.url
            let host = url?.host ?? ""
            let leftGoogle = host.hasSuffix("youtube.com")
            web.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
                guard let self, !self.done else { return }
                let yt = cookies.filter { $0.domain.hasSuffix("youtube.com") }
                let hasSession = yt.contains { $0.name == "SAPISID" || $0.name == "__Secure-3PAPISID" }
                let hasSID = yt.contains { $0.name == "SID" || $0.name == "__Secure-3PSID" }
                if hasSession && hasSID && (leftGoogle || yt.contains { $0.name == "LOGIN_INFO" }) {
                    self.finish()
                    return
                }
                // Signed in to Google, but Google parked us on one of its own pages
                // (Security Checkup, account settings, "Continue to YouTube"…)
                // instead of returning to YouTube. Hand the session to YouTube ourselves.
                let googleSignedIn = cookies.contains {
                    $0.domain.hasSuffix("google.com") && ($0.name == "SID" || $0.name == "__Secure-3PSID")
                }
                let inLoginFlow = host == "accounts.google.com" && self.isActiveLoginStep(url)
                if googleSignedIn, !leftGoogle, !inLoginFlow, self.handoffs < 3,
                   Date().timeIntervalSince(self.lastHandoff) > 4 {
                    self.handoffs += 1
                    self.lastHandoff = Date()
                    DispatchQueue.main.async { self.web?.load(URLRequest(url: SignInWebView.signInURL)) }
                }
            }
        }

        /// Pages on accounts.google.com where the user still has to do something
        /// (enter password, 2-step code, choose account). Never interrupt these.
        private func isActiveLoginStep(_ url: URL?) -> Bool {
            let path = url?.path ?? ""
            let interrupting = ["/signin", "/v3/signin", "/ServiceLogin", "/AccountChooser", "/challenge",
                                "/speedbump", "/InteractiveLogin", "/CheckCookie", "/ServiceLoginAuth", "/SetSID",
                                "/accounts/SetSID", "/o/oauth2"]
            return interrupting.contains { path.hasPrefix($0) || path.contains($0) }
        }

        private func finish() {
            guard !done else { return }
            done = true
            timer?.invalidate()
            DispatchQueue.main.async {
                self.web?.stopLoading()
                self.onSignedIn()
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = action.request.url, let host = url.host else { decisionHandler(.allow); return }
            if !SignInWebView.isAllowedHost(host) {
                if action.targetFrame?.isMainFrame != false { NSWorkspace.shared.open(url) }
                decisionHandler(.cancel); return
            }
            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { check() }
        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) { check() }

        /// Google sometimes opens "Continue" in a new window: keep it in this sheet.
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if let url = action.request.url { webView.load(URLRequest(url: url)) }
            return nil
        }
    }
}

/// Full Settings page, shown inside the main window.
struct SettingsView: View {
    @EnvironmentObject var player: PlayerController
    @EnvironmentObject var model: AppModel
    @ObservedObject private var prefs = Prefs.shared
    @ObservedObject private var dial = SpeedDialStore.shared
    @State private var cacheCleared = false
    private var section: Section { model.settingsSection }

    enum Section: String, CaseIterable, Identifiable {
        case appearance = "Appearance", lyrics = "Lyrics", playback = "Playback", extensions = "Extensions", home = "Home & Sidebar",
             general = "General", shortcuts = "Keyboard Shortcuts", account = "Account & Privacy", about = "About"
        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .appearance: return "paintbrush"
            case .lyrics: return "quote.bubble"
            case .playback: return "play.circle"
            case .home: return "house"
            case .general: return "gearshape"
            case .shortcuts: return "keyboard"
            case .extensions: return "puzzlepiece.extension"
            case .account: return "lock.shield"
            case .about: return "info.circle"
            }
        }
        var blurb: String {
            switch self {
            case .appearance: return "Colours, panels and the living artwork background."
            case .lyrics: return "Where lyrics come from and how they animate."
            case .playback: return "Autoplay, speed, sleep timer and resuming."
            case .home: return "What appears on Home and in the sidebar."
            case .general: return "Menu bar, notifications and single-key shortcuts."
            case .shortcuts: return "Change any keyboard shortcut. Click a shortcut, then press the new keys."
            case .extensions: return "Built-in versions of the best YouTube Music extensions."
            case .account: return "Your account, privacy and stored data."
            case .about: return "About this app."
            }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(section.rawValue).font(.system(size: 28, weight: .bold))
                    Text(section.blurb).font(.system(size: 13)).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 30) { content }
                    .id(section)
                    .transition(.opacity)
            }
            // Fills whatever width is left beside the sidebar and queue (no fixed cap).
            .frame(maxWidth: .infinity, alignment: .leading)
            .pagePadding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onChange(of: prefs.lyricsSource) {
            LyricsService.shared.reload(for: player.current, ytLyricsBrowseId: player.lyricsBrowseId)
        }
    }

    @ViewBuilder private var content: some View {
        switch section {
        case .appearance:
            SettingsCard("Look") {
                SettingsRow("Appearance") { PillPicker(selection: $prefs.appearance, options: [(.system, "System", "circle.lefthalf.filled"), (.dark, "Dark", "moon.fill"), (.light, "Light", "sun.max.fill")]) }
                SettingsRow("Panels") { PillPicker(selection: $prefs.glassStyle, options: Prefs.GlassStyle.allCases.map { ($0, $0.rawValue, nil) }) }
                SettingsRow("Glass transparency", detail: "How see-through every glass surface in the app is: sidebar, player bar, queue, Now Playing controls and menus.") {
                    Slider(value: Binding(get: { 0.6 - prefs.glassTint }, set: { prefs.glassTint = 0.6 - $0 }), in: 0...0.6) { EmptyView() }
                        minimumValueLabel: { Text("Solid") } maximumValueLabel: { Text("Clear") }
                        .frame(width: 280)
                }
                SettingsRow("Accent colour") {
                    HStack(spacing: 7) {
                        ForEach(Prefs.accents, id: \.0) { name, color in
                            Circle().fill(color).frame(width: 18, height: 18)
                                .overlay(Circle().strokeBorder(.white, lineWidth: prefs.accent == name ? 2 : 0))
                                .scaleEffect(prefs.accent == name ? 1.15 : 1)
                                .onTapGesture { withAnimation(.spring(duration: 0.25)) { prefs.accent = name } }
                                .hoverTip(name)
                        }
                    }
                }
                SettingsRow("Custom colour", detail: "Pick any colour from the colour wheel, or type a hex code like #1DB954.") {
                    HStack(spacing: 10) {
                        ColorPicker("", selection: Binding(get: { prefs.accentColor }, set: { prefs.setCustomAccent($0) }), supportsOpacity: false)
                            .labelsHidden()
                        HexField(hex: Binding(get: { prefs.customAccentHex }, set: { if Color(hex: $0) != nil { prefs.customAccentHex = $0.uppercased(); prefs.accent = "Custom" } }))
                    }
                }
                SettingsRow("Popular app colours", detail: "Accent colours from well-known apps.") { EmptyView() }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8)], alignment: .leading, spacing: 8) {
                    ForEach(Prefs.popularAccents, id: \.0) { name, hex in
                        let on = prefs.accent == "Custom" && prefs.customAccentHex.uppercased() == hex
                        Button { withAnimation(.easeOut(duration: 0.2)) { prefs.customAccentHex = hex; prefs.accent = "Custom" } } label: {
                            HStack(spacing: 8) {
                                Circle().fill(Color(hex: hex) ?? .gray).frame(width: 14, height: 14)
                                    .overlay(Circle().strokeBorder(.white.opacity(on ? 0.9 : 0.15), lineWidth: on ? 1.5 : 0.5))
                                Text(name).font(.system(size: 12, weight: on ? .semibold : .regular)).lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(Capsule().fill(Color.primary.opacity(on ? 0.14 : 0.05)))
                            .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.bottom, 12)
                SettingsRow("Artwork size") { PillPicker(selection: $prefs.cardSize, options: Prefs.CardSize.allCases.map { ($0, $0.rawValue, nil) }) }
            }
            SettingsCard("Background") {
                SettingsToggle("Animated artwork background", $prefs.animatedBackground)
                SettingsRow("Motion") {
                    Slider(value: $prefs.backgroundMotion, in: 0.3...2.5) { EmptyView() } minimumValueLabel: { Text("Calm") } maximumValueLabel: { Text("Lively") }
                        .frame(width: 280).disabled(!prefs.animatedBackground)
                }
                SettingsToggle("Follow the cursor (parallax)", $prefs.followCursor)
                SettingsRow("Dimming") {
                    Slider(value: $prefs.backgroundDim, in: 0.15...0.75) { EmptyView() } minimumValueLabel: { Text("Vivid") } maximumValueLabel: { Text("Dark") }
                        .frame(width: 280)
                }
                ButtonRow { ResetButton("Reset Appearance") { prefs.resetAppearance() } }
            }
        case .lyrics:
            SettingsCard("Source") {
                SettingsRow("Lyrics source") { PillMenu(selection: $prefs.lyricsSource, options: Prefs.LyricsSource.allCases.map { ($0, $0.rawValue) }) }
                SettingsNote("Best available tries word-synced lyrics (Better Lyrics), then line-synced (LRCLIB), then YouTube Music's own. Only the song title, artist, album and length are sent.")
            }
            SettingsCard("Display") {
                SettingsRow("Highlight") { PillPicker(selection: $prefs.lyricsStyle, options: Prefs.LyricsStyle.allCases.map { ($0, $0.rawValue, nil) }) }
                SettingsRow("Alignment") { PillPicker(selection: $prefs.lyricsAlign, options: [(.leading, "Left", "text.alignleft"), (.center, "Centre", "text.aligncenter")]) }
                SettingsRow("Text size") {
                    HStack { Slider(value: $prefs.lyricsSize, in: 22...52, step: 1).frame(width: 240); Text("\(Int(prefs.lyricsSize)) pt").monospacedDigit().frame(width: 46) }
                }
                SettingsToggle("Glow on the word being sung", $prefs.lyricsGlow)
                SettingsToggle("Blur lines that aren't playing", $prefs.lyricsBlur)
            }
            SettingsCard("Timing") {
                SettingsRow("Sync offset") {
                    HStack {
                        Slider(value: $prefs.lyricsOffset, in: -1.0...1.0, step: 0.05).frame(width: 240)
                        Text(String(format: "%+.2f s", prefs.lyricsOffset)).monospacedDigit().frame(width: 60)
                        ResetButton("Reset") { prefs.lyricsOffset = 0 }
                    }
                }
                SettingsNote("Positive shows lyrics earlier. Bluetooth headphones usually need about +0.15 to +0.25 s.")
                ButtonRow {
                    Button { LyricsService.shared.reload(for: player.current, ytLyricsBrowseId: player.lyricsBrowseId) } label: { Label("Reload Lyrics", systemImage: "arrow.clockwise") }
                    ResetButton("Reset Lyrics Settings") { prefs.resetLyrics() }
                }
            }
        case .playback:
            SettingsCard("Playback") {
                SettingsToggle("Autoplay similar music when the queue ends", $player.autoplay)
                SettingsRow("Playback speed") {
                    PillMenu(selection: $player.playbackRate, options: [0.5, 0.75, 1.0, 1.25, 1.5, 2.0].map { ($0, $0 == 1 ? "Normal" : String(format: "%g×", $0)) })
                }
                SettingsToggle("Remember queue and position after quitting", $prefs.rememberQueue)
                SettingsRow("Sleep timer") {
                    Menu(player.sleepAt.map { "Until \($0.formatted(date: .omitted, time: .shortened))" } ?? (player.sleepAtEndOfTrack ? "End of song" : "Off")) {
                        ForEach([5, 15, 30, 45, 60, 90], id: \.self) { m in Button("\(m) minutes") { player.setSleepTimer(minutes: m) } }
                        Button("When current song ends") { player.sleepAfterCurrentTrack() }
                        Divider()
                        Button("Off") { player.setSleepTimer(minutes: nil) }
                    }
                    .menuStyle(.button).buttonStyle(CapsuleButtonStyle(prominent: false)).menuIndicator(.hidden).fixedSize()
                }
                ButtonRow { Button { WebBridge.shared.reload() } label: { Label("Reload Player", systemImage: "arrow.clockwise") } }
                SettingsNote("Audio quality follows your YouTube Music account (Premium streams the higher quality).")
            }
        case .extensions:
            SettingsCard("SponsorBlock") {
                SettingsToggle("Skip non-music sections", $prefs.sponsorBlock,
                               detail: "Uses the community SponsorBlock database to skip talking, skits, sponsor reads and other non-music parts of music videos. Only a short anonymous hash of the video is sent.")
                if prefs.sponsorBlock {
                    ForEach(Prefs.sponsorCategoryNames, id: \.0) { key, title in
                        SettingsToggle(title, Binding(get: { prefs.sponsorCategories.contains(key) },
                                                      set: { on in
                                                          if on { prefs.sponsorCategories.append(key) } else { prefs.sponsorCategories.removeAll { $0 == key } }
                                                      }), detail: "")
                            .padding(.leading, 18)
                    }
                }
            }
            SettingsCard("Equalizer") {
                SettingsToggle("Equalizer", $prefs.eqEnabled,
                               detail: "Shape the sound with presets or your own settings. Applies to everything you play.")
                SettingsRow("Preset", detail: "Choose a starting point, then fine-tune the bands below.") {
                    PillMenu(selection: Binding(get: { prefs.eqPreset }, set: { name in
                        prefs.eqPreset = name
                        if let g = Prefs.eqPresets.first(where: { $0.0 == name })?.1 { withAnimation(.easeOut(duration: 0.25)) { prefs.eqGains = g } }
                    }), options: (Prefs.eqPresets.map { ($0.0, $0.0) } + [("Custom", "Custom")]))
                }
                EqualizerBands(gains: $prefs.eqGains, enabled: prefs.eqEnabled) { prefs.eqPreset = "Custom" }
                    .padding(.vertical, 14)
                ButtonRow { ResetButton("Reset Equalizer") { prefs.eqPreset = "Flat"; prefs.eqGains = Array(repeating: 0, count: 8) } }
            }
            SettingsCard("Playback helpers") {
                SettingsToggle("Auto-skip disliked songs", $prefs.autoSkipDisliked,
                               detail: "If a song you've given a thumbs down comes up in a radio or mix, it's skipped automatically.")
            }
            SettingsCard("Also built in") {
                SettingsNote("Better Lyrics (word-synced karaoke lyrics) is built into Now Playing. Browser extensions can't be installed in this app because it's a native Mac app, not a browser; the most useful ones are built in here instead.")
            }
        case .home:
            SettingsCard("Home") {
                SettingsToggle("Show Speed Dial", $dial.visible)
                SettingsToggle("Add my last 3 played songs to Speed Dial", $dial.autoFill)
                SettingsToggle("Show mood chips (Relax, Energize…)", $prefs.showHomeChips)
            }
            SettingsCard("Hidden Home sections") {
                if prefs.hiddenHomeSections.isEmpty {
                    SettingsNote("Nothing hidden. On Home, hover a section's title and click Hide (or right-click it) to remove sections you don't want.")
                } else {
                    ForEach(prefs.hiddenHomeSections, id: \.self) { title in
                        SettingsRow(title, detail: "") {
                            Button("Show") { prefs.hiddenHomeSections.removeAll { $0 == title } }
                        }
                    }
                    ButtonRow { ResetButton("Show All Sections") { prefs.hiddenHomeSections = [] } }
                }
            }
            SettingsCard("Sidebar") {
                ButtonRow {
                    Button { model.editingSidebar = true } label: { Label("Customise Sidebar…", systemImage: "slider.horizontal.3") }
                    ResetButton("Reset Sidebar") { SidebarStore.shared.reset() }
                }
            }
        case .general:
            SettingsCard("General") {
                SettingsToggle("Show player in the menu bar", $prefs.showMenuBarPlayer)
                SettingsToggle("Notify when the song changes (while in background)", $prefs.notifyOnTrackChange)
                SettingsToggle("Single-key shortcuts (Space, R, S, L)", $prefs.singleKeyShortcuts)
            }
        case .shortcuts:
            ForEach([("Playback", [ShortcutAction.playPause, .next, .previous, .skipForward, .skipBack, .shuffle, .repeatMode, .like]),
                     ("Volume", [.volumeUp, .volumeDown, .mute]),
                     ("Navigation", [.nowPlaying, .queue, .miniPlayer, .search, .toggleSidebar, .back, .forward, .settings])], id: \.0) { group, actions in
                SettingsCard(group) {
                    ForEach(actions) { a in
                        SettingsRow(a.title, detail: "") { ShortcutRecorder(action: a) }
                    }
                }
            }
            SettingsCard("Defaults") {
                SettingsNote("Plain keys (like Space or R) only work when you're not typing. ⌘M, ⌘W and ⌘Q always minimise, close and quit.")
                ButtonRow { ResetButton("Restore All Default Shortcuts") { ShortcutStore.shared.resetAll() } }
            }
        case .account:
            SettingsCard("Account") {
                if let a = model.account {
                    SettingsRow("Signed in as") { Text(a.name).foregroundStyle(.secondary) }
                    ButtonRow {
                        Button { Task { await model.refreshAccount() } } label: { Label("Refresh Library", systemImage: "arrow.clockwise") }
                        Button(role: .destructive) {
                            Task { await WebBridge.shared.signOut(); model.account = nil; model.playlists = []; model.signedIn = false }
                        } label: { Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right") }
                    }
                } else {
                    Button("Sign In…") { model.showSignIn = true }
                }
            }
            SettingsCard("Privacy & Data") {
                SettingsNote("Your password is only entered on Google's page. The app runs sandboxed, uses HTTPS only, and keeps listening stats on this Mac.")
                ButtonRow {
                    Button {
                        ImageLoader.sharedCache.removeAllObjects()
                        try? FileManager.default.removeItem(at: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("images"))
                        cacheCleared = true
                    } label: { Label(cacheCleared ? "Image Cache Cleared" : "Clear Image Cache", systemImage: "photo.stack") }
                    .disabled(cacheCleared)
                    Button { PlayStats.shared.clear() } label: { Label("Clear Listening Stats", systemImage: "chart.bar.xaxis") }
                }
            }
        case .about:
            SettingsCard("\(AppInfo.name) \(AppInfo.version)") {
                SettingsNote("An unofficial, open-source client for YouTube Music. Not affiliated with, endorsed by or sponsored by Google or Apple. Playback uses YouTube's own player; lyrics from Better Lyrics, LRCLIB and YouTube Music.")
            }
        }
    }

    static let shortcuts: [(String, String)] = [
        ("Space", "Play / Pause"), ("⌘ →  /  ⌘ ←", "Next / Previous"), ("⌥⌘ →  /  ⌥⌘ ←", "Skip ±10 s"),
        ("⌘ ↑  /  ⌘ ↓", "Volume"), ("R", "Cycle repeat"), ("S", "Shuffle"), ("L", "Like"),
        ("⌘ L", "Now Playing"), ("⌥⌘ U", "Playing Next"), ("⇧⌘ M", "Mini Player"), ("⌘ F", "Search"),
        ("⌘ [  /  ⌘ ]", "Back / Forward"), ("⌃⌘ S", "Show / hide sidebar"), ("⌘ ,", "Settings"),
        ("⌘ M  /  ⌘ W  /  ⌘ Q", "Minimise / Close / Quit"),
    ]
}

/// A settings group: small heading, rows separated by hairlines — no boxes.
struct SettingsCard<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content
    init(_ title: String, @ViewBuilder content: @escaping () -> Content) { self.title = title; self.content = content }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .semibold)).tracking(0.6)
                .foregroundStyle(.secondary)
                .padding(.bottom, 6)
            Rectangle().fill(Color.primary.opacity(0.12)).frame(height: 0.5)
            VStack(alignment: .leading, spacing: 0) { content() }
                .buttonStyle(CapsuleButtonStyle(prominent: false))
        }
    }
}

struct SettingsRow<Control: View>: View {
    let label: String
    let detail: String?
    @ViewBuilder let control: () -> Control
    init(_ label: String, detail: String? = nil, @ViewBuilder control: @escaping () -> Control) {
        let d = detail ?? SettingsHelp.text[label]
        self.label = label; self.detail = (d?.isEmpty ?? true) ? nil : d; self.control = control
    }
    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(label).font(.system(size: 13, weight: .medium))
                if let detail { Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: 12)
            control().labelsHidden()
        }
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.primary.opacity(0.07)).frame(height: 0.5) }
    }
}

struct SettingsToggle: View {
    let label: String
    let detail: String?
    @Binding var isOn: Bool
    init(_ label: String, _ isOn: Binding<Bool>, detail: String? = nil) {
        self.label = label; self._isOn = isOn; self.detail = detail ?? SettingsHelp.text[label]
    }
    var body: some View {
        SettingsRow(label, detail: detail) { Toggle("", isOn: $isOn).toggleStyle(.switch) }
    }
}

/// One-line explanations shown under each setting.
enum SettingsHelp {
    static let text: [String: String] = [
        "Appearance": "Dark suits the artwork background best. System follows your Mac.",
        "Panels": "Liquid Glass refracts the background; Frosted is a classic blur; Solid is opaque and lightest on the GPU.",
        "Accent colour": "Colour of selections, the progress bar, active buttons and links.",
        "Artwork size": "Size of album and playlist tiles on Home, Explore and other pages.",
        "Animated artwork background": "The current song's artwork, blurred into colour, slowly moving behind everything.",
        "Motion": "How fast the background drifts and turns.",
        "Follow the cursor (parallax)": "The background and Now Playing artwork shift gently with your pointer.",
        "Dimming": "Darkens the background so text stays easy to read.",
        "Lyrics source": "Where lyrics come from. Word-synced lyrics light up exactly in time with each word.",
        "Highlight": "Letter sweep fills each letter as it's sung; Word fade lights whole words; Whole line just brightens the line.",
        "Alignment": "Position of the lyrics in Now Playing.",
        "Text size": "Size of the lyrics in Now Playing.",
        "Glow on the word being sung": "A soft light that travels with the singing.",
        "Blur lines that aren't playing": "Softens the other lines so the current one stands out.",
        "Sync offset": "Moves lyrics earlier (+) or later (−) if they don't line up with what you hear.",
        "Autoplay similar music when the queue ends": "Keeps the music going with a radio based on what you just played.",
        "Playback speed": "Plays songs and podcasts faster or slower.",
        "Remember queue and position after quitting": "Reopens with the same song, queue and position.",
        "Sleep timer": "Pauses playback after a set time or at the end of the current song.",
        "Show Speed Dial": "A grid of your go-to music at the top of Home.",
        "Add my last 3 played songs to Speed Dial": "Empty spots are filled from what you play most (counted only on this Mac).",
        "Show mood chips (Relax, Energize…)": "Quick mood filters at the top of Home.",
        "Show player in the menu bar": "A small player in the menu bar with controls, progress and volume.",
        "Notify when the song changes (while in background)": "A notification with the song name when the app isn't in front.",
        "Single-key shortcuts (Space, R, S, L)": "Space plays/pauses, R repeats, S shuffles, L likes — when you're not typing.",
        "Signed in as": "The YouTube Music account this app uses.",
    ]
}

struct SettingsNote: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View { Text(text).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).padding(.vertical, 10) }
}


/// Hex colour entry with a live swatch; commits on Return.
struct HexField: View {
    @Binding var hex: String
    @State private var text = ""
    var body: some View {
        TextField("#RRGGBB", text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: 12, weight: .medium, design: .monospaced))
            .frame(width: 78)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Capsule().fill(Color.primary.opacity(0.09)))
            .overlay(Capsule().strokeBorder(Color(hex: text) == nil && !text.isEmpty ? Color.red.opacity(0.7) : .white.opacity(0.1), lineWidth: 0.8))
            .onAppear { text = hex }
            .onChange(of: hex) { text = hex }
            .onSubmit { hex = text }
    }
}


/// Buttons laid out in a row with consistent spacing (never stacked tight).
struct ButtonRow<Content: View>: View {
    @ViewBuilder let content: () -> Content
    var body: some View {
        HStack(spacing: 12) { content() }
            .buttonStyle(CapsuleButtonStyle(prominent: false))
            .controlSize(.large)
            .padding(.vertical, 14)
    }
}

/// Consistent, bold reset action.
struct ResetButton: View {
    let title: String
    let action: () -> Void
    init(_ title: String, action: @escaping () -> Void) { self.title = title; self.action = action }
    var body: some View {
        Button(action: action) { Label(title, systemImage: "arrow.counterclockwise").font(.system(size: 12.5, weight: .bold)) }
            .buttonStyle(CapsuleButtonStyle(prominent: false))
            .controlSize(.large)
    }
}


/// Eight vertical band sliders with frequency labels.
struct EqualizerBands: View {
    @Binding var gains: [Double]
    let enabled: Bool
    let onEdit: () -> Void

    var body: some View {
        HStack(alignment: .bottom, spacing: 0) {
            VStack(alignment: .trailing) {
                Text("+12 dB"); Spacer(); Text("0"); Spacer(); Text("−12 dB")
            }
            .font(.system(size: 10, weight: .medium).monospacedDigit())
            .foregroundStyle(.secondary)
            .frame(height: 140)
            .padding(.trailing, 10)
            ForEach(Array(Prefs.eqBands.enumerated()), id: \.offset) { i, f in
                VStack(spacing: 8) {
                    VerticalBandSlider(value: Binding(get: { gains.indices.contains(i) ? gains[i] : 0 },
                                                      set: { v in
                                                          var g = gains
                                                          while g.count < Prefs.eqBands.count { g.append(0) }
                                                          g[i] = (v * 2).rounded() / 2
                                                          gains = g
                                                          onEdit()
                                                      }))
                        .frame(width: 30, height: 140)
                    Text(f >= 1000 ? "\(Int(f / 1000))k" : "\(Int(f))")
                        .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .opacity(enabled ? 1 : 0.45)
        .disabled(!enabled)
    }
}


/// A drawn vertical slider (−12…+12 dB): track, fill from the centre line, knob,
/// and the value while dragging.
struct VerticalBandSlider: View {
    @Binding var value: Double
    @State private var dragging = false
    @State private var hover = false

    var body: some View {
        GeometryReader { g in
            let h = g.size.height
            let y = h / 2 - CGFloat(value / 12) * (h / 2 - 8)
            ZStack(alignment: .top) {
                Capsule().fill(Color.primary.opacity(0.14)).frame(width: 4).frame(maxHeight: .infinity)
                Rectangle().fill(Color.primary.opacity(0.25)).frame(width: 12, height: 1).offset(y: h / 2)
                Capsule().fill(Color.accentColor)
                    .frame(width: 4, height: abs(y - h / 2))
                    .offset(y: min(y, h / 2))
                Circle().fill(.white)
                    .frame(width: dragging || hover ? 16 : 13, height: dragging || hover ? 16 : 13)
                    .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                    .offset(y: y - (dragging || hover ? 8 : 6.5))
                if dragging {
                    Text(String(format: "%+.1f", value))
                        .font(.system(size: 10, weight: .semibold).monospacedDigit())
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Capsule().fill(Color.black.opacity(0.8)))
                        .foregroundStyle(.white)
                        .fixedSize()
                        .offset(y: y - 30)
                }
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { v in
                    dragging = true
                    let t = (h / 2 - v.location.y) / (h / 2 - 8)
                    value = max(-12, min(12, Double(t) * 12))
                }
                .onEnded { _ in dragging = false })
            .onHover { hover = $0 }
            .animation(.easeOut(duration: 0.12), value: hover)
        }
    }
}
