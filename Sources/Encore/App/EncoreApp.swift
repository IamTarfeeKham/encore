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
                .frame(minWidth: 980, minHeight: 620)
                .preferredColorScheme(prefs.colorScheme)
                .tint(prefs.accentColor)
                .accentColor(prefs.accentColor)
        }
        .defaultSize(width: 1360, height: 880)
        .windowStyle(.hiddenTitleBar)
        .commands { PlayerCommands(player: player, model: model) }

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
            ScrollActivity.start()
            WebBridge.shared.start()
            NowPlayingService.shared.start()
            Equalizer.shared.start()
            AppIcon.start()
            Task { await AppModel.shared.refreshAccount() }
        }
        // Single-key shortcuts (only when not typing): Space play/pause, R repeat, S shuffle, L like.
        // All app shortcuts (customisable in Settings → Keyboard Shortcuts).
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let r = event.window?.firstResponder
            let typing = r is NSText || r is NSTextView || r is NSTextField || r is WKWebView
            let handled = MainActor.assumeIsolated { ShortcutStore.shared.handle(event, typing: typing) }
            return handled ? nil : event
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Dock icon clicked. AppKit's default does nothing here because the hidden
    /// player's off-screen "parking" window always counts as a visible window,
    /// so a minimised (or closed) main window never came back. Handle it ourselves.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        WindowOpener.showMain()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { PlayerController.shared.save() }
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
        return w
    }()

    /// Moving a web view between windows can make WebKit pause media; resume it.
    private func keepPlaying(_ wasPlaying: Bool) {
        guard wasPlaying else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { WebBridge.shared.play() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            if PlayerController.shared.isPlaying, WebBridge.shared.snapshot.state == 2 { WebBridge.shared.play() }
        }
    }

    func park() {
        let web = WebBridge.shared.webView
        let wasPlaying = PlayerController.shared.isPlaying && web.superview != nil
        defer { keepPlaying(wasPlaying) }
        web.removeFromSuperview()
        web.frame = parking.contentView?.bounds ?? .zero
        web.autoresizingMask = [.width, .height]
        parking.contentView?.addSubview(web)
        parking.orderFrontRegardless()
        parking.setFrameOrigin(NSPoint(x: -20000, y: -20000))
    }

    func adopt(into view: NSView) {
        let web = WebBridge.shared.webView
        guard web.superview !== view else { return }
        let wasPlaying = PlayerController.shared.isPlaying
        defer { keepPlaying(wasPlaying) }
        web.removeFromSuperview()
        web.frame = view.bounds
        web.autoresizingMask = [.width, .height]
        view.addSubview(web)
    }
}

struct PlayerCommands: Commands {
    @ObservedObject var player: PlayerController
    @ObservedObject var model: AppModel
    @ObservedObject var shortcuts = ShortcutStore.shared
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
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
            Button(model.sidebarVisible ? "Hide Sidebar" : "Show Sidebar") { model.sidebarVisible.toggle() }
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
            Button(model.showQueue ? "Hide Playing Next" : "Show Playing Next") { model.showQueue.toggle() }
                .shortcut(.queue)
            Button("Mini Player") { openWindow(id: "mini") }.shortcut(.miniPlayer)
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
        if let w = mainWindow, w.isVisible || w.isMiniaturized {
            if w.isMiniaturized { w.deminiaturize(nil) }
            w.makeKeyAndOrderFront(nil)
        } else {
            open?(id: "main")
        }
        NSApp.activate(ignoringOtherApps: true)
    }
}
