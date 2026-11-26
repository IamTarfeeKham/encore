import AppKit
import Combine

/// Keeps the Dock icon matched to the user's choice (Settings › Appearance › App Icon)
/// and, on Automatic, to macOS itself: light or dark mode, and the icon style chosen in
/// System Settings › Appearance (Default, Dark, Clear or Tinted, with its tint colour).
@MainActor
enum AppIcon {
    private static var bag = Set<AnyCancellable>()
    private static var observers: [Any] = []
    private static var themeObservation: NSKeyValueObservation?
    private static var shown: (IconSymbol, IconLook, String)?
    private static var generation = 0

    static func start() {
        update()
        let prefs = Prefs.shared
        prefs.$appIconSymbol.dropFirst().sink { _ in DispatchQueue.main.async { update() } }.store(in: &bag)
        prefs.$appIconStyle.dropFirst().sink { _ in DispatchQueue.main.async { update() } }.store(in: &bag)
        // macOS appearance, accent colour and icon style changes.
        let dnc = DistributedNotificationCenter.default()
        for name in ["AppleInterfaceThemeChangedNotification", "AppleColorPreferencesChangedNotification", "AppleIconAppearanceThemeChangedNotification"] {
            observers.append(dnc.addObserver(forName: .init(name), object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { update() }
            })
        }
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { update() }
        })
        themeObservation = UserDefaults.standard.observe(\.appleIconTheme, options: [.new]) { _, _ in
            DispatchQueue.main.async { update() }
        }
    }

    /// macOS's own settings: is the system in dark mode, and which icon style is chosen.
    static var systemIsDark: Bool { UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark" }
    static var systemIconTheme: String { UserDefaults.standard.string(forKey: "AppleIconAppearanceTheme") ?? "RegularAutomatic" }

    /// The look to use for a style, right now.
    static func look(for style: Prefs.AppIconStyle) -> IconLook {
        let dark = systemIsDark
        switch style {
        case .dark: return .dark
        case .light: return .pearl
        case .graphite: return .graphite
        case .red: return .red
        case .clear: return dark ? .clearDark : .clearLight
        case .automatic:
            let theme = systemIconTheme
            let iconsDark = theme.hasSuffix("Dark") ? true : theme.hasSuffix("Light") ? false : dark
            if theme.hasPrefix("Clear") { return iconsDark ? .clearDark : .clearLight }
            if theme.hasPrefix("Tinted") { return iconsDark ? .tintedDark : .tintedLight }
            return iconsDark ? .dark : .pearl
        }
    }

    /// The system accent colour (used for the Tinted look).
    static var tint: CGColor { NSColor.controlAccentColor.usingColorSpace(.displayP3)?.cgColor ?? NSColor.systemRed.cgColor }

    static func update() {
        let symbol = Prefs.shared.appIconSymbol
        let look = look(for: Prefs.shared.appIconStyle)
        let tintKey = look == .tintedDark || look == .tintedLight ? "\(NSColor.controlAccentColor)" : ""
        if let s = shown, s.0 == symbol, s.1 == look, s.2 == tintKey { return }
        shown = (symbol, look, tintKey)
        generation += 1
        let gen = generation, tint = tint
        // Rendering takes a few tens of milliseconds: off the main thread.
        Task.detached(priority: .utility) {
            let image = IconArt.nsImage(symbol: symbol, look: look, size: 512, tint: tint)
            await MainActor.run {
                guard gen == generation, let image else { return }
                NSApp.applicationIconImage = image
            }
        }
    }
}

private extension UserDefaults {
    /// KVO handle for macOS's icon style (System Settings › Appearance).
    @objc dynamic var appleIconTheme: String? { string(forKey: "AppleIconAppearanceTheme") }
}
