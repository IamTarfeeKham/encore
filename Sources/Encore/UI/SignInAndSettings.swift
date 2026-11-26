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
    @State private var finishing = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Sign in with Google").font(.headline)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(12)
            Divider()
            SignInWebView { finish() }
                .overlay {
                    if finishing {
                        VStack(spacing: 12) {
                            ProgressView().controlSize(.large)
                            Text("Finishing sign-in…").font(.system(size: 14, weight: .medium))
                            Text("Loading your library").font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(.regularMaterial)
                        .transition(.opacity)
                    }
                }
        }
        .frame(width: 520, height: 680)
    }

    /// Signed in: reload the player with the new session, wait until the account
    /// is really loaded (not a fixed pause), then close and say who's signed in.
    private func finish() {
        withAnimation(.easeOut(duration: 0.2)) { finishing = true }
        WebBridge.shared.reload()
        Task {
            for _ in 0..<12 {
                try? await Task.sleep(nanoseconds: 700_000_000)
                await model.refreshAccount()
                if model.account != nil { break }
            }
            dismiss()
            if let name = model.account?.name { model.flash("Signed in as \(name)") }
        }
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
            guard let url = action.request.url else { decisionHandler(.cancel); return }
            // Blank and in-memory pages are fine; everything else must be secure.
            if ["about", "blob", "data"].contains(url.scheme ?? "") { decisionHandler(.allow); return }
            guard url.scheme == "https", let host = url.host else { decisionHandler(.cancel); return }
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
            case .extensions: return "Your own extensions, plus built-in versions of the best YouTube Music extensions."
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
                if prefs.glassStyle == .liquid {
                    SettingsRow("Sidebar and player bar", detail: "Frosted blurs what's behind them; Liquid Glass keeps them clear and see-through.") {
                        PillPicker(selection: $prefs.barSurface, options: Prefs.BarSurface.allCases.map { ($0, $0.rawValue, nil) })
                    }
                }
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
            SettingsCard("Now Playing view") {
                SettingsRow("Show", detail: "Lyrics: the cover beside the lyrics, or beside Up Next when a song has none. Artwork: just the cover, big. You can also switch at the top of Now Playing.") {
                    PillPicker(selection: $prefs.nowPlayingLayout, options: [(.lyrics, "Lyrics", "quote.bubble"), (.artwork, "Artwork", "photo")])
                }
                SettingsToggle("Gently animate the artwork view", $prefs.artworkMotion,
                               detail: "In the Artwork view the cover breathes slowly and the background drifts a little more. Off when Reduce Motion is on.")
            }
            SettingsCard("Mini players") {
                SettingsToggle("Liquid Glass mini player and menu bar player", $prefs.glassMiniPlayers,
                               detail: "Clear glass that shows what's behind. Turn off for the cover's colours instead.")
            }
            SettingsCard("Lock Screen") {
                SettingsToggle("Show the song on the lock screen", $prefs.lockScreenArtwork,
                               detail: "While music plays, the cover (moving gently, like the Artwork view) and the song's name appear on your Mac's lock screen, between the clock and the password field. New: it uses a part of macOS that Apple doesn't document, so it may not appear on every macOS version.")
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
                SettingsRow("Crossfade", detail: "The next song starts while this one fades out, so the two blend into each other (repeat one crossfades a song into its own start). A second player runs for the last 40 seconds of each song. Also in the player bar (♪→♪).") {
                    HStack(spacing: 10) {
                        Slider(value: $player.fadeSeconds, in: 0...12, step: 1).frame(width: 160)
                        Text(player.fadeSeconds > 0 ? "\(Int(player.fadeSeconds)) s" : "Off")
                            .font(.system(size: 12).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 34, alignment: .trailing)
                    }
                }
                SettingsToggle("Smart crossfade", $player.smartFade,
                               detail: "Songs from the same album run straight into each other, and short songs get a shorter crossfade.")
                    .disabled(player.fadeSeconds == 0)
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
            UserExtensionsSettings()
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
                // Apple's web engine hands Web Audio pure silence for YouTube's audio
                // stream (measured: peak level 0 while a song plays), so a Web Audio
                // equaliser can only mute the music. It's switched off for good.
                SettingsNote("Not available. Apple's web engine doesn't let apps reach YouTube's audio stream, so an equaliser here could only silence the music. Your Mac's own sound settings, or a system-wide equaliser app, still work with Encore.")
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
                SettingsToggle("Single-key shortcuts (Space, M, J, L, R, S, +)", $prefs.singleKeyShortcuts)
            }
            UpdatesSettings()
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


/// Settings › General › Updates.
struct UpdatesSettings: View {
    @ObservedObject private var prefs = Prefs.shared
    @ObservedObject private var updater = Updater.shared

    private var statusText: String {
        switch updater.status {
        case .checking: return "Checking…"
        case .installing: return "Installing…"
        case .available: return updater.latest.map { "Version \($0.version) is available." } ?? ""
        case .upToDate: return "You're up to date."
        case .failed(let why): return why
        case .idle: return updater.lastChecked == nil ? "" : "You're up to date."
        }
    }

    var body: some View {
        SettingsCard("Updates") {
            SettingsRow("Version \(AppInfo.version)", detail: statusText.isEmpty ? nil : statusText) {
                HStack(spacing: 8) {
                    if updater.status == .available {
                        Button("Install and Relaunch") { updater.install(relaunch: true) }
                    }
                    Button("Check Now") { Task { await updater.check(userInitiated: true) } }
                        .disabled(updater.status == .checking || updater.status == .installing)
                }
            }
            SettingsToggle("Check for updates automatically", $prefs.autoCheckUpdates,
                           detail: "Looks for a new version on GitHub when the app opens and every few hours.")
            SettingsToggle("Install updates automatically", $prefs.autoInstallUpdates,
                           detail: "Downloads the update, checks it's genuine, replaces the old version and reopens. It waits until music isn't playing, or does it when you quit.")
            if prefs.autoInstallUpdates {
                SettingsRow("Install") {
                    PillMenu(selection: $prefs.autoInstallWhen, options: Prefs.AutoInstallWhen.allCases.map { ($0, $0.rawValue) })
                }
            }
        }
    }
}
