import SwiftUI
import AppKit

/// A key plus modifiers, e.g. ⌘→ or a single "R".
struct KeyCombo: Codable, Hashable {
    var key: String          // "space", "left", "right", "up", "down", "return", "delete", or a character
    var command = false, option = false, control = false, shift = false

    var hasModifiers: Bool { command || option || control }

    init(_ key: String, command: Bool = false, option: Bool = false, control: Bool = false, shift: Bool = false) {
        self.key = key; self.command = command; self.option = option; self.control = control; self.shift = shift
    }

    init?(event e: NSEvent) {
        let m = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
        switch e.keyCode {
        case 49: key = "space"
        case 123: key = "left"
        case 124: key = "right"
        case 125: key = "down"
        case 126: key = "up"
        case 36: key = "return"
        case 51: key = "delete"
        default:
            guard let c = e.charactersIgnoringModifiers?.lowercased(), let ch = c.first, !ch.isWhitespace else { return nil }
            key = String(ch)
        }
        command = m.contains(.command); option = m.contains(.option); control = m.contains(.control); shift = m.contains(.shift)
    }

    func matches(_ e: NSEvent) -> Bool { KeyCombo(event: e) == self }

    var display: String {
        var s = ""
        if control { s += "⌃" }
        if option { s += "⌥" }
        // A symbol like "+" already implies Shift; don't show "⇧+".
        if shift && !(key.count == 1 && !(key.first?.isLetter ?? false)) { s += "⇧" }
        if command { s += "⌘" }
        switch key {
        case "space": s += "Space"
        case "left": s += "←"
        case "right": s += "→"
        case "up": s += "↑"
        case "down": s += "↓"
        case "return": s += "↩"
        case "delete": s += "⌫"
        default: s += key.uppercased()
        }
        return s
    }

    /// For showing the shortcut next to menu items.
    var swiftUI: KeyboardShortcut? {
        let k: KeyEquivalent
        switch key {
        case "space": k = .space
        case "left": k = .leftArrow
        case "right": k = .rightArrow
        case "up": k = .upArrow
        case "down": k = .downArrow
        case "return": k = .return
        case "delete": k = .delete
        default: guard let c = key.first else { return nil }; k = KeyEquivalent(c)
        }
        var mods: EventModifiers = []
        if command { mods.insert(.command) }
        if option { mods.insert(.option) }
        if control { mods.insert(.control) }
        if shift { mods.insert(.shift) }
        return KeyboardShortcut(k, modifiers: mods)
    }
}

enum ShortcutAction: String, CaseIterable, Codable, Identifiable {
    case playPause, next, previous, skipForward, skipBack, volumeUp, volumeDown, mute,
         shuffle, repeatMode, like, nowPlaying, queue, miniPlayer, search, toggleSidebar, back, forward, settings
    var id: String { rawValue }

    var title: String {
        switch self {
        case .playPause: return "Play / Pause"
        case .next: return "Next song"
        case .previous: return "Previous song"
        case .skipForward: return "Skip forward 15 s"
        case .skipBack: return "Skip back 15 s"
        case .volumeUp: return "Volume up"
        case .volumeDown: return "Volume down"
        case .mute: return "Mute / Unmute"
        case .shuffle: return "Shuffle"
        case .repeatMode: return "Repeat (cycle)"
        case .like: return "Like song"
        case .nowPlaying: return "Show Now Playing"
        case .queue: return "Show queue"
        case .miniPlayer: return "Mini Player"
        case .search: return "Search"
        case .toggleSidebar: return "Show / hide sidebar"
        case .back: return "Back"
        case .forward: return "Forward"
        case .settings: return "Settings"
        }
    }

    var defaultCombo: KeyCombo {
        switch self {
        case .playPause: return KeyCombo("space")
        case .next: return KeyCombo("right", command: true)
        case .previous: return KeyCombo("left", command: true)
        case .skipForward: return KeyCombo("l")
        case .skipBack: return KeyCombo("j")
        case .volumeUp: return KeyCombo("up", command: true)
        case .volumeDown: return KeyCombo("down", command: true)
        case .mute: return KeyCombo("m")
        case .shuffle: return KeyCombo("s")
        case .repeatMode: return KeyCombo("r")
        case .like: return KeyCombo("+", shift: true)
        case .nowPlaying: return KeyCombo("l", command: true)
        case .queue: return KeyCombo("u", command: true, option: true)
        case .miniPlayer: return KeyCombo("m", command: true, shift: true)
        case .search: return KeyCombo("f", command: true)
        case .toggleSidebar: return KeyCombo("s", command: true, control: true)
        case .back: return KeyCombo("[", command: true)
        case .forward: return KeyCombo("]", command: true)
        case .settings: return KeyCombo(",", command: true)
        }
    }
}

extension Notification.Name { static let openMiniPlayer = Notification.Name("openMiniPlayer") }

@MainActor
final class ShortcutStore: ObservableObject {
    static let shared = ShortcutStore()
    /// While true, the app's shortcut handler ignores keys (a recorder is listening).
    static var recording = false

    @Published private(set) var overrides: [String: KeyCombo] { didSet { Persist.save(overrides, "shortcuts") } }

    init() { overrides = Persist.load("shortcuts", as: [String: KeyCombo].self) ?? [:] }

    func combo(_ a: ShortcutAction) -> KeyCombo? {
        if let o = overrides[a.rawValue] { return o.key.isEmpty ? nil : o }
        return a.defaultCombo
    }

    func set(_ a: ShortcutAction, _ c: KeyCombo?) {
        // A combo can only belong to one action.
        if let c { for other in ShortcutAction.allCases where other != a && combo(other) == c { overrides[other.rawValue] = KeyCombo("") } }
        overrides[a.rawValue] = c ?? KeyCombo("")
    }

    func reset(_ a: ShortcutAction) { overrides[a.rawValue] = nil }
    func resetAll() { overrides = [:] }

    /// Handles a key press; returns true if it triggered an action.
    func handle(_ e: NSEvent, typing: Bool) -> Bool {
        guard !Self.recording, let pressed = KeyCombo(event: e) else { return false }
        guard let action = ShortcutAction.allCases.first(where: { combo($0) == pressed }) else { return false }
        // Plain keys (no ⌘/⌥/⌃) never steal typing, and respect the single-key setting.
        if !pressed.hasModifiers && (typing || !Prefs.shared.singleKeyShortcuts) { return false }
        perform(action)
        return true
    }

    func perform(_ a: ShortcutAction) {
        let p = PlayerController.shared, m = AppModel.shared
        switch a {
        case .playPause: p.togglePlayPause()
        case .next: p.next()
        case .previous: p.previous()
        case .skipForward: p.skip(by: 15)
        case .skipBack: p.skip(by: -15)
        case .volumeUp: p.volume = min(100, p.volume + 8)
        case .volumeDown: p.volume = max(0, p.volume - 8)
        case .mute: p.toggleMute(); m.flash(p.muted ? "Muted" : "Unmuted")
        case .shuffle: p.toggleShuffle(); m.flash(p.shuffle ? "Shuffle On" : "Shuffle Off")
        case .repeatMode:
            p.repeatMode = p.repeatMode.next
            m.flash(p.repeatMode == .off ? "Repeat Off" : p.repeatMode == .all ? "Repeat All" : "Repeat One")
        case .like:
            guard p.current != nil else { return }
            p.toggleLike(); m.flash(p.likeStatus == .like ? "Liked" : "Like Removed")
        case .nowPlaying: withAnimation(.spring(duration: 0.45)) { m.showNowPlaying.toggle() }
        case .queue: withAnimation(Motion.panel) { m.showQueue.toggle() }
        case .miniPlayer: NotificationCenter.default.post(name: .openMiniPlayer, object: nil)
        case .search: m.focusSearch = true
        case .toggleSidebar: withAnimation(Motion.panel) { m.sidebarVisible.toggle() }
        case .back: m.goBack()
        case .forward: m.goForward()
        case .settings: m.showNowPlaying = false; m.selection = .settings
        }
    }
}

/// Click to record a new shortcut; Esc cancels, Delete clears.
struct ShortcutRecorder: View {
    let action: ShortcutAction
    @ObservedObject private var store = ShortcutStore.shared
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 6) {
            Button { recording ? stop() : start() } label: {
                Text(recording ? "Press keys…" : (store.combo(action)?.display ?? "None"))
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .frame(minWidth: 86)
                    .foregroundStyle(recording ? Color.accentColor : .primary)
            }
            .buttonStyle(CapsuleButtonStyle(prominent: false))
            .overlay(Capsule().strokeBorder(recording ? Color.accentColor : .clear, lineWidth: 1.2))
            if store.combo(action) != action.defaultCombo {
                Button { store.reset(action) } label: { Image(systemName: "arrow.uturn.backward") }
                    .buttonStyle(BarIconStyle(size: 11))
                    .hoverTip("Reset to \(action.defaultCombo.display)")
            }
        }
        .onDisappear { stop() }
    }

    private func start() {
        recording = true
        ShortcutStore.recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            if e.keyCode == 53 { stop(); return nil }                     // Esc: cancel
            if e.keyCode == 51 && e.modifierFlags.intersection([.command, .option, .control]).isEmpty {
                store.set(action, nil); stop(); return nil                 // Delete: clear
            }
            if let c = KeyCombo(event: e) { store.set(action, c); stop() }
            return nil
        }
    }

    private func stop() {
        recording = false
        ShortcutStore.recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
