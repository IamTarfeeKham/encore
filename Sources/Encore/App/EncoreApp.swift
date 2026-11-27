import SwiftUI
import AppKit
import WebKit

@main
struct EncoreApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var player = PlayerController.shared
    @StateObject private var model = AppModel.shared
    @StateObject private var prefs = Prefs.shared
    @AppStorage("showMenuBarPlayer") private var showMenuBar = true

    var body: some Scene {
        Window(AppInfo.name, id: "main") {
            ContentView()
                .environmentObject(player)
                .environmentObject(model)
                .environmentObject(player.clock)
                .frame(minWidth: 620, minHeight: 440)
                .preferredColorScheme(prefs.colorScheme)
                .tint(prefs.accentColor)
                .accentColor(prefs.accentColor)
        }
        .defaultSize(width: 1360, height: 880)
        .windowStyle(.hiddenTitleBar)
        .commands { PlayerCommands(player: player, model: model) }

        Window("About \(AppInfo.name)", id: "about") {
            AboutView()
                .preferredColorScheme(prefs.colorScheme)
                .tint(prefs.accentColor)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        Window("Mini Player", id: "mini") {
            MiniPlayerView()
                .environmentObject(player)
                .environmentObject(model)
                .environmentObject(player.clock)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultPosition(.topTrailing)

        MenuBarExtra(isInserted: $showMenuBar) {
            MenuBarPlayerView()
                .environmentObject(player)
                .environmentObject(model)
                .environmentObject(player.clock)
        } label: {
            Image(nsImage: MenuBarIcon.image)
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var keyMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            WebHost.shared.park()
            WebHost.shared.watchScreens()
            WebHost.shared.watchPages()
            MenuBarActivation.start()
            AppDelegate.dropAutomaticSearchFocus()
            ScrollActivity.start()
            WebBridge.shared.start()
            NowPlayingService.shared.start()
            LockScreenArt.shared.start()
            Updater.shared.start()
            WidgetFeed.shared.start()
            UserExtensions.shared.start()
            AppIcon.start()
            LyricsBench.runIfRequested()
            Task { await AppModel.shared.refreshAccount() }
        }
        // Single-key shortcuts (only when not typing): Space play/pause, R repeat, S shuffle, L like.
        // All app shortcuts (customisable in Settings → Keyboard Shortcuts).
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Hide / Hide Others always work, even when a web view (video mode,
            // sign-in) has keyboard focus and would otherwise swallow the keys.
            let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
            if event.charactersIgnoringModifiers?.lowercased() == "h" {
                if mods == [.command, .option] { NSApp.hideOtherApplications(nil); return nil }
                if mods == [.command] { NSApp.hide(nil); return nil }
            }
            let typing = MainActor.assumeIsolated { Self.isTyping(in: event.window) }
            let handled = MainActor.assumeIsolated { ShortcutStore.shared.handle(event, typing: typing) }
            return handled ? nil : event
        }
    }

    /// Whether a keystroke is text input, so single-key shortcuts must not fire.
    /// macOS parks the cursor in the search field whenever the window opens; that
    /// alone isn't typing. It is when the search panel is open (you clicked in, or
    /// started typing), or in any other text field. YouTube's own player view
    /// (video mode) never counts; the sign-in page does.
    static func isTyping(in window: NSWindow?) -> Bool {
        guard let r = window?.firstResponder else { return false }
        if let v = r as? NSView, WebBridge.shared.allWebViews.contains(where: { v === $0 || v.isDescendant(of: $0) }) { return false }
        if r is WKWebView { return true }
        // Any text field with the cursor in it. (The automatic focus macOS gives
        // the search field is removed in dropAutomaticSearchFocus, so a focused
        // search field always means you clicked into it or pressed ⌘F.)
        return r is NSText || r is NSTextView || r is NSTextField
    }

    /// macOS puts the cursor in the window's first text field (search) whenever the
    /// window becomes active. That would make single-key shortcuts think you're
    /// typing, so take that automatic focus away unless you're actually searching.
    static func dropAutomaticSearchFocus() {
        NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { n in
            MainActor.assumeIsolated {
                guard let w = n.object as? NSWindow, w === WindowOpener.mainWindow else { return }
                DispatchQueue.main.async {
                    if !SearchController.shared.visible, w.firstResponder is NSTextView { w.makeFirstResponder(nil) }
                }
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Dock icon clicked. AppKit's default does nothing here because the hidden
    /// player's off-screen "parking" window always counts as a visible window,
    /// so a minimised (or closed) main window never came back. Handle it ourselves.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MenuBarActivation.reopenedAt = Date()
        WindowOpener.showMain()
        // A Dock click always wins: bring the window forward again once activation
        // has settled (in case anything sent it back meanwhile).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { WindowOpener.showMain() }
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { PlayerController.shared.save() }
    }

    /// An automatic update that was waiting installs as you quit (like other Mac apps).
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            let u = Updater.shared
            guard u.pendingAutomatic, u.status == .available else { return .terminateNow }
            u.installOnQuitIfPending()
            // The helper takes over once it has started; give it a moment.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { NSApp.reply(toApplicationShouldTerminate: true) }
            return .terminateLater
        }
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        do {
            let p = PlayerController.shared
            let menu = NSMenu()
            if let t = p.current {
                let title = NSMenuItem(title: t.title, action: nil, keyEquivalent: "")
                title.isEnabled = false
                menu.addItem(title)
                let artist = NSMenuItem(title: t.artistLine, action: nil, keyEquivalent: "")
                artist.isEnabled = false
                menu.addItem(artist)
                menu.addItem(.separator())
            }
            menu.addItem(DockItem(p.isPlaying ? "Pause" : "Play") { p.togglePlayPause() })
            menu.addItem(DockItem("Next") { p.next() })
            menu.addItem(DockItem("Previous") { p.previous() })
            if p.current != nil {
                menu.addItem(.separator())
                menu.addItem(DockItem(p.likeStatus == .like ? "Remove Like" : "Like") { p.toggleLike() })
                menu.addItem(DockItem("Shuffle: \(p.shuffle ? "On" : "Off")") { p.toggleShuffle() })
                menu.addItem(DockItem("Repeat: \(p.repeatMode.rawValue.capitalized)") { p.repeatMode = p.repeatMode.next })
            }
            return menu
        }
    }
}

/// NSMenuItem with a closure action (for the Dock menu).
final class DockItem: NSMenuItem {
    private let handler: () -> Void
    init(_ title: String, _ handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError() }
    @objc private func run() { handler() }
}

/// Keeps the player web view alive in an off-screen window when it isn't
/// being shown (video mode), so closing the main window never stops music.
@MainActor
final class WebHost {
    static let shared = WebHost()
    private lazy var parking: NSWindow = {
        let w = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 1280, height: 720),
                         styleMask: [.borderless], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.collectionBehavior = [.transient, .ignoresCycle, .canJoinAllSpaces]
        w.ignoresMouseEvents = true
        w.isExcludedFromWindowsMenu = true
        w.hasShadow = false
        // Fully transparent: macOS moves windows that sit off every screen back on
        // screen (after sleep or a display change), which showed up as a big grey
        // rectangle. Transparent, it can never be seen even if that happens.
        w.alphaValue = 0
        w.backgroundColor = .clear
        w.isOpaque = false
        return w
    }()
    private var observers: [NSObjectProtocol] = []

    func repark() { parking.setFrameOrigin(NSPoint(x: -20000, y: -20000)) }

    /// The hidden player window, so other code can tell it apart from real windows.
    var parkingWindow: NSWindow { parking }

    /// Puts the parking window back off-screen whenever the screen setup changes.
    func watchScreens() {
        let reposition: @Sendable (Notification) -> Void = { _ in
            MainActor.assumeIsolated { WebHost.shared.repark() }
        }
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main, using: reposition))
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main, using: reposition))
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main, using: reposition))
    }

    /// Moving a web view between windows can make WebKit pause media; resume it.
    private func keepPlaying(_ wasPlaying: Bool) {
        guard wasPlaying else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { WebBridge.shared.play() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            if PlayerController.shared.isPlaying, WebBridge.shared.snapshot.state == 2 { WebBridge.shared.play() }
        }
    }

    func park() {
        let wasPlaying = PlayerController.shared.isPlaying && WebBridge.shared.webView.superview != nil
        defer { keepPlaying(wasPlaying) }
        if let host = parking.contentView { move(WebBridge.shared.allWebViews, into: host) }
        parking.orderFrontRegardless()
        parking.setFrameOrigin(NSPoint(x: -20000, y: -20000))
    }

    func adopt(into view: NSView) {
        guard WebBridge.shared.webView.superview !== view else { pagesChanged(); return }
        let wasPlaying = PlayerController.shared.isPlaying
        defer { keepPlaying(wasPlaying) }
        move(WebBridge.shared.allWebViews, into: view)
    }

    /// Both player pages (two while Crossfade is on) live in the same place, the one
    /// that isn't playing fully transparent: switching between them never moves a
    /// page between windows (which can make WebKit pause it).
    private func move(_ views: [WKWebView], into host: NSView) {
        for web in views where web.superview !== host {
            web.removeFromSuperview()
            web.frame = host.bounds
            web.autoresizingMask = [.width, .height]
            host.addSubview(web, positioned: .below, relativeTo: nil)
        }
        showPlayingPage()
    }

    private func showPlayingPage() {
        let playing = WebBridge.shared.webView
        for web in WebBridge.shared.allWebViews { web.alphaValue = web === playing ? 1 : 0 }
    }

    /// A page was added or removed, or the other page became the player.
    private func pagesChanged() {
        let host = WebBridge.shared.webView.superview ?? parking.contentView
        if let host { move(WebBridge.shared.allWebViews, into: host) }
    }

    /// Follows the player pages as Crossfade adds, removes and swaps them.
    func watchPages() {
        for name in [Notification.Name.playerPagesChanged, .playerPageSwapped] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { WebHost.shared.pagesChanged() }
            })
        }
    }
}

struct PlayerCommands: Commands {
    @ObservedObject var player: PlayerController
    @ObservedObject var model: AppModel
    @ObservedObject var sidebarState = SidebarState.shared
    @ObservedObject var shortcuts = ShortcutStore.shared
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About \(AppInfo.name)") { openWindow(id: "about") }
            Button("Check for Updates…") { Task { await Updater.shared.check(userInitiated: true) } }
        }
        CommandMenu("Controls") {
            Button(player.isPlaying ? "Pause" : "Play") { player.togglePlayPause() }
            Button("Next") { player.next() }.shortcut(.next)
            Button("Previous") { player.previous() }.shortcut(.previous)
            Button("Skip Forward 10s") { player.skip(by: 10) }.shortcut(.skipForward)
            Button("Skip Back 10s") { player.skip(by: -10) }.shortcut(.skipBack)
            Divider()
            Button("Increase Volume") { player.volume = min(100, player.volume + 8) }.shortcut(.volumeUp)
            Button("Decrease Volume") { player.volume = max(0, player.volume - 8) }.shortcut(.volumeDown)
            Button(player.muted ? "Unmute" : "Mute") { player.toggleMute() }.shortcut(.mute)
            Divider()
            Toggle("Shuffle", isOn: Binding(get: { player.shuffle }, set: { _ in player.toggleShuffle() }))
                .shortcut(.shuffle)
            Button("Cycle Repeat (R)") { player.repeatMode = player.repeatMode.next }
                .shortcut(.repeatMode)
            Picker("Repeat", selection: $player.repeatMode) {
                Text("Off").tag(RepeatMode.off)
                Text("All").tag(RepeatMode.all)
                Text("One").tag(RepeatMode.one)
            }
            Toggle("Autoplay Similar Music", isOn: $player.autoplay)
            Picker("Playback Speed", selection: $player.playbackRate) {
                ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { r in Text(r == 1 ? "Normal" : "\(r, specifier: "%g")×").tag(r) }
            }
            Divider()
            Button(player.likeStatus == .like ? "Remove Like" : "Like Song") { player.toggleLike() }
                .shortcut(.like).disabled(player.current == nil)
            Button("Dislike Song") { player.toggleDislike() }.disabled(player.current == nil)
            Divider()
            Menu("Sleep Timer") {
                ForEach([5, 15, 30, 45, 60, 90], id: \.self) { m in Button("\(m) minutes") { player.setSleepTimer(minutes: m) } }
                Button("When Current Song Ends") { player.sleepAfterCurrentTrack() }
                if player.sleepAt != nil || player.sleepAtEndOfTrack { Divider(); Button("Turn Off") { player.setSleepTimer(minutes: nil) } }
            }
        }
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { model.showNowPlaying = false; model.selection = .settings }
                .shortcut(.settings)
        }
        CommandGroup(replacing: .sidebar) {
            Button(model.sidebarVisible ? "Hide Sidebar" : "Show Sidebar") { withAnimation(Motion.panel) { model.sidebarVisible.toggle() } }
                .shortcut(.toggleSidebar)
            Button("Edit Sidebar…") { model.editingSidebar = true }
        }
        CommandGroup(after: .textEditing) {
            Button("Search") { model.sidebarVisible = true; model.focusSearch = true }.shortcut(.search)
        }
        CommandGroup(after: .toolbar) {
            Button(model.showNowPlaying ? "Hide Now Playing" : "Show Now Playing") {
                withAnimation(.spring(duration: 0.45)) { model.showNowPlaying.toggle() }
            }.shortcut(.nowPlaying)
            Button(model.showQueue ? "Hide Playing Next" : "Show Playing Next") { withAnimation(Motion.panel) { model.showQueue.toggle() } }
                .shortcut(.queue)
            Button(model.miniPlayerOpen ? "Close Mini Player" : "Mini Player") { MiniPlayer.toggle(openWindow) }.shortcut(.miniPlayer)
            Divider()
            Button("Reload Player") { WebBridge.shared.reload() }
        }
    }
}


extension View {
    /// Shows the (customisable) shortcut beside a menu item. Only combos with ⌘/⌥/⌃
    /// go on menu items; plain keys are handled by the app so they never block typing.
    @MainActor func shortcut(_ a: ShortcutAction) -> some View {
        let c = ShortcutStore.shared.combo(a)
        return keyboardShortcut(c?.hasModifiers == true ? c?.swiftUI : nil)
    }
}


/// Menu-bar icon: a plain music note as a template image (adapts to the menu bar).
enum MenuBarIcon {
    static let image: NSImage = {
        let cfg = NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
        let img = NSImage(systemSymbolName: "music.note", accessibilityDescription: AppInfo.name)!.withSymbolConfiguration(cfg)!
        img.isTemplate = true
        return img
    }()
}


/// Brings the main window back from AppKit code (Dock clicks): restores it when it's
/// minimised or hidden, and reopens it through SwiftUI when it was closed.
@MainActor
enum WindowOpener {
    /// SwiftUI's openWindow action, captured from the main window's view.
    static var open: OpenWindowAction?

    static var mainWindow: NSWindow? {
        NSApp.windows.first { w in
            (w.identifier?.rawValue.hasPrefix("main") == true || w.title == AppInfo.name)
                && w.styleMask.contains(.titled)
        }
    }

    static func showMain() {
        // An explicit request to see the window: the menu-bar check must not undo it.
        MenuBarActivation.reopenedAt = Date()
        // After ⌘H the whole app is hidden; un-hiding brings every window back.
        if NSApp.isHidden { NSApp.unhide(nil) }
        if let w = mainWindow, w.isVisible || w.isMiniaturized {
            if w.isMiniaturized { w.deminiaturize(nil) }
            w.makeKeyAndOrderFront(nil)
        } else {
            open?(id: "main")
        }
        NSApp.activate(ignoringOtherApps: true)
    }
}


/// Clicking the menu-bar icon activates the app, and activation brings the main
/// window to the front too. When the activation came from opening the menu-bar
/// player, put the main window back where it was (behind the app you were using).
@MainActor
enum MenuBarActivation {
    private static var restoreBelow: Int?

    static func start() {
        NotificationCenter.default.addObserver(forName: NSApplication.willBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { snapshot() }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                // The panel can appear a moment after activation; check twice.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { restore(final: false) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { restore(final: true) }
            }
        }
    }

    /// Before activating: is another app's window in front of our main window?
    private static func snapshot() {
        restoreBelow = nil
        guard let main = WindowOpener.mainWindow, main.isVisible,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return }
        let pid = ProcessInfo.processInfo.processIdentifier
        let normal = list.filter { ($0[kCGWindowLayer as String] as? Int) == 0 }
        guard let mainIndex = normal.firstIndex(where: { ($0[kCGWindowNumber as String] as? Int) == main.windowNumber }),
              let otherIndex = normal.firstIndex(where: { ($0[kCGWindowOwnerPID as String] as? Int32) != pid }),
              otherIndex < mainIndex
        else { return }
        restoreBelow = normal[otherIndex][kCGWindowNumber as String] as? Int
    }

    /// The menu-bar player's panel: an untitled window floating above normal
    /// windows (not the hidden player window).
    static var menuBarPanelIsOpen: Bool {
        NSApp.windows.contains { w in
            // The status item's own little window (always present) must not count;
            // only the dropdown panel, which is much taller than the menu bar.
            let cls = NSStringFromClass(type(of: w))
            return w.isVisible && !w.styleMask.contains(.titled)
                && w.level.rawValue > NSWindow.Level.normal.rawValue
                && !cls.contains("StatusBar") && w.frame.height > 120
                && w !== WebHost.shared.parkingWindow
                && w.title != "Mini Player"   // frameless and floating too, but not the dropdown
        }
    }

    /// Set when the Dock icon is clicked: that activation must bring the window forward.
    static var reopenedAt = Date.distantPast

    /// After activating: if the menu-bar player is open, send the main window back
    /// behind the window that was in front before.
    private static func restore(final: Bool) {
        guard let other = restoreBelow else { return }
        if Date().timeIntervalSince(reopenedAt) < 1 { restoreBelow = nil; return }
        if final { restoreBelow = nil }
        guard menuBarPanelIsOpen, let main = WindowOpener.mainWindow else { return }
        main.order(.below, relativeTo: other)
        restoreBelow = nil
    }
}
