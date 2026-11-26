import AppKit
import Combine
import SwiftUI

/// Shows the song on the Mac's lock screen while music plays: the cover (breathing
/// like the Artwork view, on Core Animation) with a soft glow of its colours, and
/// the song's name. It sits in the band between the system clock and the password
/// field, never over them, never takes clicks or keys, and exists only while the
/// screen is locked. Settings › Lyrics › Lock Screen turns it off.
@MainActor
final class LockScreenArt {
    static let shared = LockScreenArt()

    private var window: NSWindow?
    private var space: LockScreenSpace?
    private var playing: AnyCancellable?
    private var watchdog: Timer?
    /// A developer test shows it without locking (perfLog on); until then, the
    /// watchdog leaves it up.
    private var testUntil = Date.distantPast

    func start() {
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { LockScreenArt.shared.screenLocked() }
        }
        dnc.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { LockScreenArt.shared.hide() }
        }
        if UserDefaults.standard.bool(forKey: "perfLog") {
            dnc.addObserver(forName: .init("local.ytmusicmac.debug.lockArt"), object: nil, queue: .main) { _ in
                MainActor.assumeIsolated {
                    let art = LockScreenArt.shared
                    art.testUntil = Date().addingTimeInterval(6)
                    art.show()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 6) { art.hide() }
                }
            }
        }
    }

    private static var screenIsLocked: Bool {
        guard let d = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return (d["CGSSessionScreenIsLocked"] as? NSNumber)?.boolValue ?? false
    }

    private func screenLocked() {
        guard Prefs.shared.lockScreenArtwork else { return }
        let player = PlayerController.shared
        // Music that starts while locked (media keys, headphones) brings it up too.
        playing = player.$isPlaying.removeDuplicates().sink { on in
            if on, player.current != nil { LockScreenArt.shared.show() }
        }
    }

    private func show() {
        guard window == nil, PlayerController.shared.current != nil else { return }
        guard let space = space ?? LockScreenSpace() else {
            PerfMonitor.note("lock screen: window-server space unavailable")
            return
        }
        self.space = space
        guard let screen = NSScreen.screens.first else { return }

        // A clear window over the whole screen; the card itself keeps to the band
        // between the clock and the password field (see LockScreenCard).
        let band = screen.frame
        let w = NSWindow(contentRect: band, styleMask: .borderless, backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.ignoresMouseEvents = true
        w.isReleasedWhenClosed = false
        w.animationBehavior = .none
        w.collectionBehavior = [.stationary, .ignoresCycle, .fullScreenAuxiliary]
        let host = NSHostingView(rootView: LockScreenCard())
        host.sizingOptions = []
        w.contentView = host
        w.setFrame(band, display: false)
        w.orderFrontRegardless()
        space.adopt(w)
        window = w
        PerfMonitor.note("lock screen: showing art (window \(w.windowNumber))")

        // If the unlock notice is ever missed, don't leave the art over the desktop.
        watchdog = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            MainActor.assumeIsolated {
                let art = LockScreenArt.shared
                if !Self.screenIsLocked, Date() > art.testUntil { art.hide() }
            }
        }
    }

    func hide() {
        playing = nil
        watchdog?.invalidate(); watchdog = nil
        guard let w = window else { return }
        window = nil
        w.orderOut(nil)
        w.contentView = nil
        space?.remove()
        space = nil
        PerfMonitor.note("lock screen: art hidden")
    }
}

/// The lock screen card: cover, glow and title, centred in its band.
private struct LockScreenCard: View {
    @ObservedObject private var player = PlayerController.shared
    @ObservedObject private var prefs = Prefs.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var glow: CGImage?

    /// The band the card keeps to: below the clock (top 31%), above the password
    /// field (bottom 25%).
    private static let top = 0.31, bottom = 0.25

    var body: some View {
        GeometryReader { g in
            let bandHeight = g.size.height * (1 - Self.top - Self.bottom)
            let side = max(140, min(bandHeight - 96, g.size.width * 0.5))
            VStack(spacing: 18) {
                TiltingArtwork(url: player.current?.largeArtwork, side: side,
                               breathing: player.isPlaying && prefs.artworkMotion && !reduceMotion)
                    .background {
                        if let glow {
                            Image(decorative: glow, scale: 1)
                                .resizable()
                                .frame(width: side * 1.12, height: side * 1.12)
                                .blur(radius: 34)
                                .opacity(0.7)
                        }
                    }
                    .scaleEffect(player.isPlaying ? 1 : 0.94)
                    .animation(.spring(duration: 0.6, bounce: 0.2), value: player.isPlaying)
                if let t = player.current {
                    VStack(spacing: 4) {
                        Text(t.title).font(.system(size: 20, weight: .bold)).lineLimit(1)
                        Text(t.artistLine).font(.system(size: 15, weight: .medium)).opacity(0.75).lineLimit(1)
                    }
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.5), radius: 8, y: 2)
                    .frame(maxWidth: max(side * 1.5, 320))
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: bandHeight)
            .position(x: g.size.width / 2, y: g.size.height * (Self.top + (1 - Self.top - Self.bottom) / 2))
        }
        .ignoresSafeArea()
        .environment(\.colorScheme, .dark)
        .task(id: player.current?.largeArtwork) {
            guard let url = player.current?.largeArtwork else { glow = nil; return }
            glow = await ImageLoader.shared.ambient(for: url)
        }
    }
}

/// A window-server space that shows above the lock screen, the way lock-screen
/// notifications and widgets appear there. These are private SkyLight calls,
/// looked up at run time: if any is missing (another macOS version), this is nil
/// and the lock screen art simply doesn't appear.
private final class LockScreenSpace {
    private typealias MainConnectionID = @convention(c) () -> Int32
    private typealias SpaceCreate = @convention(c) (Int32, Int, UnsafeRawPointer?) -> UInt64
    private typealias SpaceSetAbsoluteLevel = @convention(c) (Int32, UInt64, Int32) -> Int32
    private typealias ShowOrHideSpaces = @convention(c) (Int32, CFArray) -> Int32
    private typealias AddWindows = @convention(c) (Int32, UInt64, CFArray, Int32) -> Int32
    private typealias SpaceDestroy = @convention(c) (Int32, UInt64) -> Int32

    /// "Notification Center at screen lock": above the lock screen.
    private static let level: Int32 = 400

    private let connection: Int32
    private let id: UInt64
    private let addWindows: AddWindows
    private let hideSpaces: ShowOrHideSpaces
    private let destroy: SpaceDestroy

    init?() {
        guard let lib = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW) else { return nil }
        func fn<T>(_ name: String, _ type: T.Type) -> T? { dlsym(lib, name).map { unsafeBitCast($0, to: type) } }
        guard let main = fn("SLSMainConnectionID", MainConnectionID.self),
              let create = fn("SLSSpaceCreate", SpaceCreate.self),
              let setLevel = fn("SLSSpaceSetAbsoluteLevel", SpaceSetAbsoluteLevel.self),
              let show = fn("SLSShowSpaces", ShowOrHideSpaces.self),
              let hide = fn("SLSHideSpaces", ShowOrHideSpaces.self),
              let add = fn("SLSSpaceAddWindowsAndRemoveFromSpaces", AddWindows.self),
              let destroy = fn("SLSSpaceDestroy", SpaceDestroy.self)
        else { return nil }
        connection = main()
        id = create(connection, 1, nil)
        guard id != 0 else { return nil }
        _ = setLevel(connection, id, Self.level)
        _ = show(connection, [NSNumber(value: id)] as CFArray)
        addWindows = add; hideSpaces = hide; self.destroy = destroy
    }

    func adopt(_ window: NSWindow) {
        _ = addWindows(connection, id, [NSNumber(value: window.windowNumber)] as CFArray, 7)
    }

    func remove() {
        _ = hideSpaces(connection, [NSNumber(value: id)] as CFArray)
        _ = destroy(connection, id)
    }
}
