import SwiftUI
import AppKit

/// All user preferences, persisted in UserDefaults and observable by views.
@MainActor
final class Prefs: ObservableObject {
    static let shared = Prefs()
    private let d = UserDefaults.standard

    enum Appearance: String, CaseIterable, Identifiable { case system = "System", dark = "Dark", light = "Light"; var id: String { rawValue } }
    enum GlassStyle: String, CaseIterable, Identifiable { case liquid = "Liquid Glass", frosted = "Frosted", solid = "Solid"; var id: String { rawValue } }
    enum CardSize: String, CaseIterable, Identifiable { case small = "Small", medium = "Medium", large = "Large"; var id: String { rawValue } }
    enum LyricsSource: String, CaseIterable, Identifiable {
        case auto = "Best available", wordSynced = "Word-synced only", lineSynced = "Line-synced (LRCLIB)", youtube = "YouTube Music (unsynced)"
        var id: String { rawValue }
    }
    enum LyricsStyle: String, CaseIterable, Identifiable { case wipe = "Letter sweep", fade = "Word fade", line = "Whole line"; var id: String { rawValue } }
    enum LyricsAlign: String, CaseIterable, Identifiable { case leading = "Left", center = "Centre"; var id: String { rawValue } }
    /// What Now Playing shows beside the controls: the cover with the lyrics (or with
    /// Up Next when a song has none), or just the cover, big.
    /// When automatic updates install themselves.
    enum AutoInstallWhen: String, CaseIterable, Identifiable {
        case rightAway = "Right away", afterDay = "After a day", afterWeek = "After a week",
             twoVersions = "Every 2 versions", threeVersions = "Every 3 versions"
        var id: String { rawValue }
    }
    /// How the sidebar and player bar look with Liquid Glass panels.
    enum BarSurface: String, CaseIterable, Identifiable { case frosted = "Frosted", liquid = "Liquid Glass"; var id: String { rawValue } }
    enum NowPlayingLayout: String, CaseIterable, Identifiable { case lyrics = "Lyrics", artwork = "Artwork"; var id: String { rawValue } }
    /// The Dock icon's look. Automatic follows macOS: light or dark mode, and the icon
    /// style in System Settings › Appearance (Default, Dark, Clear or Tinted).
    enum AppIconStyle: String, CaseIterable, Identifiable {
        case automatic = "Automatic", dark = "Dark", light = "Light", clear = "Clear", graphite = "Graphite", red = "Red"
        var id: String { rawValue }
    }

    /// Accent colours of popular apps (hex), offered as one-click presets.
    static let popularAccents: [(String, String)] = [
        ("Spotify Green", "#1DB954"), ("YouTube Red", "#FF0000"), ("Discord Blurple", "#5865F2"),
        ("Apple Music Red", "#FA2D48"), ("Twitch Purple", "#9146FF"), ("SoundCloud Orange", "#FF5500"),
        ("Netflix Red", "#E50914"), ("Instagram Pink", "#E1306C"), ("X Blue", "#1D9BF0"),
        ("WhatsApp Green", "#25D366"), ("Telegram Blue", "#229ED9"), ("Reddit Orange", "#FF4500"),
        ("Amazon Orange", "#FF9900"), ("Snapchat Yellow", "#FFFC00"), ("Tidal Teal", "#33FFEE"), ("Deezer Purple", "#A238FF"),
    ]

    static let accents: [(String, Color)] = [
        ("Pink", Color(red: 1.0, green: 0.27, blue: 0.48)), ("Red", .red), ("Orange", .orange), ("Yellow", .yellow),
        ("Green", .green), ("Mint", .mint), ("Teal", .teal), ("Blue", .blue), ("Indigo", .indigo),
        ("Purple", .purple), ("Graphite", .gray),
    ]

    // Appearance
    @Published var appearance: Appearance { didSet { d.set(appearance.rawValue, forKey: "appearance") } }
    @Published var accent: String { didSet { d.set(accent, forKey: "accent") } }
    /// Used when `accent == "Custom"`: any colour, stored as #RRGGBB.
    @Published var customAccentHex: String { didSet { d.set(customAccentHex, forKey: "customAccentHex") } }
    /// Home sections the user chose to hide (by title).
    @Published var hiddenHomeSections: [String] { didSet { d.set(hiddenHomeSections, forKey: "hiddenHomeSections") } }
    @Published var glassStyle: GlassStyle { didSet { d.set(glassStyle.rawValue, forKey: "glassStyle") } }
    /// How dark/opaque glass panels are (0 = fully clear, 0.6 = nearly solid).
    @Published var barSurface: BarSurface { didSet { d.set(barSurface.rawValue, forKey: "barSurface") } }
    @Published var glassTint: Double { didSet { d.set(glassTint, forKey: "glassTint") } }
    @Published var animatedBackground: Bool { didSet { d.set(animatedBackground, forKey: "animatedBackground") } }
    /// Lyrics (cover beside the lyrics, or beside Up Next) or Artwork (just the cover).
    @Published var nowPlayingLayout: NowPlayingLayout { didSet { d.set(nowPlayingLayout.rawValue, forKey: "nowPlayingLayout") } }
    /// App icon: which symbol, and which look (Automatic matches macOS).
    @Published var appIconSymbol: IconSymbol { didSet { d.set(appIconSymbol.rawValue, forKey: "appIconSymbol") } }
    @Published var appIconStyle: AppIconStyle { didSet { d.set(appIconStyle.rawValue, forKey: "appIconStyle") } }
    /// The mini player and menu bar player are clear Liquid Glass (off: the cover's colours).
    @Published var glassMiniPlayers: Bool { didSet { d.set(glassMiniPlayers, forKey: "glassMiniPlayers") } }
    /// While music plays, the cover and song name appear on the Mac's lock screen.
    @Published var lockScreenArtwork: Bool { didSet { d.set(lockScreenArtwork, forKey: "lockScreenArtwork") } }
    /// The artwork view moves gently: the cover breathes, the background drifts a little more.
    @Published var artworkMotion: Bool { didSet { d.set(artworkMotion, forKey: "artworkMotion") } }
    @Published var backgroundMotion: Double { didSet { d.set(backgroundMotion, forKey: "backgroundMotion") } }
    @Published var followCursor: Bool { didSet { d.set(followCursor, forKey: "followCursor") } }
    @Published var backgroundDim: Double { didSet { d.set(backgroundDim, forKey: "backgroundDim") } }
    @Published var cardSize: CardSize { didSet { d.set(cardSize.rawValue, forKey: "cardSize") } }
    @Published var showHomeChips: Bool { didSet { d.set(showHomeChips, forKey: "showHomeChips") } }

    // Lyrics
    @Published var lyricsSource: LyricsSource { didSet { d.set(lyricsSource.rawValue, forKey: "lyricsSource") } }
    @Published var lyricsStyle: LyricsStyle { didSet { d.set(lyricsStyle.rawValue, forKey: "lyricsStyle") } }
    @Published var lyricsAlign: LyricsAlign { didSet { d.set(lyricsAlign.rawValue, forKey: "lyricsAlign") } }
    @Published var lyricsSize: Double { didSet { d.set(lyricsSize, forKey: "lyricsSize2") } }
    @Published var lyricsOffset: Double { didSet { d.set(lyricsOffset, forKey: "lyricsOffset") } }
    @Published var lyricsGlow: Bool { didSet { d.set(lyricsGlow, forKey: "lyricsGlow") } }
    @Published var lyricsBlur: Bool { didSet { d.set(lyricsBlur, forKey: "lyricsBlur2") } }
    /// Letters float up as the voice reaches them, and stay up while the line plays.
    @Published var lyricsLift: Bool { didSet { d.set(lyricsLift, forKey: "lyricsLift") } }
    /// Small soft sparkles drift up off long, held notes.
    @Published var lyricsParticles: Bool { didSet { d.set(lyricsParticles, forKey: "lyricsParticles") } }
    /// Run the Better Lyrics extension (downloaded from its GitHub release) for songs
    /// Encore's own sources can't time word by word.
    @Published var lyricsBetterLyricsExtension: Bool { didSet { d.set(lyricsBetterLyricsExtension, forKey: "lyricsBetterLyricsExtension") } }

    // Extensions
    @Published var sponsorBlock: Bool { didSet { d.set(sponsorBlock, forKey: "sponsorBlock") } }
    @Published var sponsorCategories: [String] { didSet { d.set(sponsorCategories, forKey: "sponsorCategories") } }
    @Published var eqEnabled: Bool { didSet { d.set(eqEnabled, forKey: "eqEnabled") } }
    @Published var eqPreset: String { didSet { d.set(eqPreset, forKey: "eqPreset") } }
    @Published var eqGains: [Double] { didSet { d.set(eqGains, forKey: "eqGains") } }
    @Published var autoSkipDisliked: Bool { didSet { d.set(autoSkipDisliked, forKey: "autoSkipDisliked") } }

    static let eqBands: [Double] = [60, 150, 400, 1000, 2400, 6000, 12000, 16000]
    static let eqPresets: [(String, [Double])] = [
        ("Flat", [0, 0, 0, 0, 0, 0, 0, 0]),
        ("Bass Boost", [6, 4.5, 2, 0, 0, 0, 0, 0]),
        ("Bass Reducer", [-6, -4, -2, 0, 0, 0, 0, 0]),
        ("Vocal", [-2, -1, 1, 3.5, 4, 2, 0, -1]),
        ("Treble Boost", [0, 0, 0, 0, 1.5, 3.5, 5, 6]),
        ("Loudness", [5, 3, 0, -1, 0, 2, 4, 5]),
        ("Electronic", [4.5, 3.5, 0.5, -1, 1.5, 2.5, 3.5, 4]),
        ("Hip-Hop", [5, 4, 1, 2, -1, 0.5, 1.5, 2.5]),
        ("Rock", [4.5, 3, -1, -1.5, 0.5, 2.5, 4, 4.5]),
        ("Acoustic", [3.5, 2.5, 1.5, 0.5, 1.5, 2.5, 3, 2]),
        ("Classical", [3.5, 2.5, 0, 0, 0, 0, -1.5, -2.5]),
        ("Late Night", [2, 1.5, 1, 0.5, 0, -1, -2.5, -4]),
    ]
    static let sponsorCategoryNames: [(String, String)] = [
        ("music_offtopic", "Non-music sections of music videos"),
        ("sponsor", "Sponsor segments"),
        ("selfpromo", "Self-promotion"),
        ("intro", "Intros / intermissions"),
        ("outro", "Outros / end cards"),
        ("interaction", "Subscribe / like reminders"),
    ]

    // Layout
    @Published var sidebarWidth: Double { didSet { d.set(sidebarWidth, forKey: "sidebarWidth") } }
    /// Sidebar panel height as a fraction of the space available (0.35…1).
    @Published var sidebarHeight: Double { didSet { d.set(sidebarHeight, forKey: "sidebarHeight") } }

    // Updates
    @Published var autoCheckUpdates: Bool { didSet { d.set(autoCheckUpdates, forKey: "autoCheckUpdates") } }
    @Published var autoInstallUpdates: Bool { didSet { d.set(autoInstallUpdates, forKey: "autoInstallUpdates") } }
    @Published var autoInstallWhen: AutoInstallWhen { didSet { d.set(autoInstallWhen.rawValue, forKey: "autoInstallWhen") } }

    // General
    @Published var notifyOnTrackChange: Bool { didSet { d.set(notifyOnTrackChange, forKey: "notifyOnTrackChange") } }
    @Published var showMenuBarPlayer: Bool { didSet { d.set(showMenuBarPlayer, forKey: "showMenuBarPlayer") } }
    @Published var rememberQueue: Bool { didSet { d.set(rememberQueue, forKey: "rememberQueue") } }
    @Published var singleKeyShortcuts: Bool { didSet { d.set(singleKeyShortcuts, forKey: "singleKeyShortcuts") } }

    init() {
        let d = UserDefaults.standard
        func s<T: RawRepresentable>(_ k: String, _ def: T) -> T where T.RawValue == String {
            d.string(forKey: k).flatMap(T.init(rawValue:)) ?? def
        }
        func b(_ k: String, _ def: Bool) -> Bool { d.object(forKey: k) as? Bool ?? def }
        func n(_ k: String, _ def: Double) -> Double { d.object(forKey: k) as? Double ?? def }
        appearance = s("appearance", .dark)
        accent = d.string(forKey: "accent") ?? "Pink"
        customAccentHex = d.string(forKey: "customAccentHex") ?? "#FF4579"
        hiddenHomeSections = d.stringArray(forKey: "hiddenHomeSections") ?? []
        glassStyle = s("glassStyle", .liquid)
        barSurface = s("barSurface", .frosted)
        animatedBackground = b("animatedBackground", true)
        // Earlier versions had a lyrics on/off button; "off" was this artwork view.
        nowPlayingLayout = s("nowPlayingLayout", b("showLyrics", true) ? .lyrics : .artwork)
        artworkMotion = b("artworkMotion", true)
        appIconSymbol = s("appIconSymbol", .note)
        appIconStyle = s("appIconStyle", .automatic)
        lockScreenArtwork = b("lockScreenArtwork", true)
        glassMiniPlayers = b("glassMiniPlayers", true)
        autoCheckUpdates = b("autoCheckUpdates", true)
        autoInstallUpdates = b("autoInstallUpdates", true)
        autoInstallWhen = s("autoInstallWhen", .rightAway)
        glassTint = n("glassTint", 0.12)
        backgroundMotion = n("backgroundMotion", 1)
        followCursor = b("followCursor", true)
        backgroundDim = n("backgroundDim", 0.46)
        cardSize = s("cardSize", .medium)
        showHomeChips = b("showHomeChips", true)
        lyricsSource = s("lyricsSource", .auto)
        lyricsStyle = s("lyricsStyle", .wipe)
        lyricsAlign = s("lyricsAlign", .leading)
        lyricsSize = n("lyricsSize2", 30)
        lyricsOffset = n("lyricsOffset", 0)
        lyricsGlow = b("lyricsGlow", true)
        lyricsBlur = b("lyricsBlur2", false)
        lyricsLift = b("lyricsLift", true)
        lyricsParticles = b("lyricsParticles", true)
        lyricsBetterLyricsExtension = b("lyricsBetterLyricsExtension", true)
        sponsorBlock = b("sponsorBlock", true)
        sponsorCategories = d.stringArray(forKey: "sponsorCategories") ?? ["music_offtopic", "sponsor", "selfpromo", "interaction"]
        eqEnabled = b("eqEnabled", false)
        eqPreset = d.string(forKey: "eqPreset") ?? "Flat"
        eqGains = (d.array(forKey: "eqGains") as? [Double]) ?? Array(repeating: 0, count: 8)
        autoSkipDisliked = b("autoSkipDisliked", true)
        sidebarWidth = n("sidebarWidth", 236)
        sidebarHeight = n("sidebarHeight", 1)
        notifyOnTrackChange = b("notifyOnTrackChange", false)
        showMenuBarPlayer = b("showMenuBarPlayer", true)
        rememberQueue = b("rememberQueue", true)
        singleKeyShortcuts = b("singleKeyShortcuts", true)
    }

    var accentColor: Color {
        if accent == "Custom" { return Color(hex: customAccentHex) ?? Self.accents[0].1 }
        return Self.accents.first { $0.0 == accent }?.1 ?? Self.accents[0].1
    }

    func setCustomAccent(_ c: Color) {
        customAccentHex = c.hexString
        accent = "Custom"
    }

    func hideHomeSection(_ title: String) {
        guard !title.isEmpty, !hiddenHomeSections.contains(title) else { return }
        hiddenHomeSections.append(title)
    }
    var colorScheme: ColorScheme? { appearance == .system ? nil : (appearance == .dark ? .dark : .light) }
    var cardWidth: CGFloat { cardSize == .small ? 148 : (cardSize == .large ? 220 : 180) }

    func resetAppearance() {
        appearance = .dark; accent = "Pink"; glassStyle = .liquid; animatedBackground = true
        backgroundMotion = 1; followCursor = true; backgroundDim = 0.46; cardSize = .medium; showHomeChips = true
        glassTint = 0.12
    }
    func resetLyrics() {
        lyricsSource = .auto; lyricsStyle = .wipe; lyricsAlign = .leading; lyricsSize = 30
        lyricsOffset = 0; lyricsGlow = true; lyricsBlur = false; lyricsLift = true; lyricsParticles = true; lyricsBetterLyricsExtension = true
    }
}


extension Color {
    init?(hex: String) {
        var h = hex.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if h.hasPrefix("#") { h.removeFirst() }
        if h.count == 3 { h = h.map { "\($0)\($0)" }.joined() }
        guard h.count == 6, let v = UInt32(h, radix: 16) else { return nil }
        self = Color(.sRGB, red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }
    var hexString: String {
        let c = NSColor(self).usingColorSpace(.sRGB) ?? .systemPink
        return String(format: "#%02X%02X%02X", Int(round(c.redComponent * 255)), Int(round(c.greenComponent * 255)), Int(round(c.blueComponent * 255)))
    }
}
