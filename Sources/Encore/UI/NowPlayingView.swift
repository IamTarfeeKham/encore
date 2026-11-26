import SwiftUI
import AppKit
import Combine

struct NowPlayingView: View {
    @EnvironmentObject var player: PlayerController
    @EnvironmentObject var model: AppModel
    @StateObject private var lyrics = LyricsService.shared
    @ObservedObject private var prefs = Prefs.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The Artwork view: just the cover, big, where the lyrics (or Up Next) would be.
    /// The Lyrics view is the cover beside the lyrics, or beside Up Next for a song
    /// without lyrics. Switched at the top of Now Playing (and in Settings › Lyrics).
    private var artworkOnly: Bool { prefs.nowPlayingLayout == .artwork }
    /// The artwork view moves gently (unless turned off, or Reduce Motion is on).
    private var artworkMoves: Bool { artworkOnly && prefs.artworkMotion && !reduceMotion }

    var body: some View {
        ZStack {
            if player.videoMode {
                // The video surface lives underneath (always mounted in ContentView);
                // keep this layer transparent apart from the controls.
                Color.clear
            } else {
                AmbientBackground(artwork: player.current?.largeArtwork, dim: 0.3, parallax: 1.5,
                                  energy: artworkMoves ? 1.7 : 1)
                content
            }
            VStack { topBar; Spacer() }
        }
        .environment(\.colorScheme, .dark)
        .onAppear { reloadLyrics() }
        .onChange(of: player.current?.videoId) { reloadLyrics() }
        .onChange(of: player.lyricsBrowseId) { reloadLyrics() }
    }

    private func reloadLyrics() { lyrics.load(for: player.current, ytLyricsBrowseId: player.lyricsBrowseId) }

    private var topBar: some View {
        HStack {
            Button { withAnimation(.spring(duration: 0.5, bounce: 0.12)) { model.showNowPlaying = false } } label: {
                Image(systemName: "chevron.down")
            }
            // The button is the whole glass circle, so its hover fill covers it.
            .buttonStyle(BarIconStyle(size: 14, diameter: 36))
            .glassPanel(18)
            .hoverTip("Close", edge: .bottom)
            .padding(.leading, 76)  // clear of the window buttons
            Spacer()
            HStack(spacing: 10) {
                // Lyrics (cover + lyrics, or cover + Up Next) or Artwork (just the cover).
                if !player.videoMode {
                    PillPicker(selection: $prefs.nowPlayingLayout,
                               options: [(.lyrics, "Lyrics", "quote.bubble"), (.artwork, "Artwork", "photo")], onGlass: true,
                               iconOnly: true, tipEdge: .bottom)
                        .glassPanel(18)
                        .transition(.opacity)
                }
                HStack(spacing: 2) {
                    Button { withAnimation(Motion.panel) { model.showQueue.toggle() } } label: {
                        Image(systemName: "list.bullet")
                            .foregroundStyle(model.showQueue ? Color.accentColor : .primary)
                    }
                    .hoverTip("Queue", edge: .bottom)
                    Menu {
                        if let item = currentItem { ItemMenu(item: item) }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .menuStyle(.button).menuIndicator(.hidden)
                    .hoverTip("More", edge: .bottom)
                }
                // No inset: the end buttons' hover circles meet the capsule's ends exactly.
                .buttonStyle(BarIconStyle(size: 14, diameter: 36))
                .glassPanel(18)
            }
        }
        // Song / Video stays in the middle of the window, whatever sits either side.
        .overlay {
            PillPicker(selection: Binding(get: { player.videoMode }, set: { player.setVideoMode($0) }),
                       options: [(false, "Song", "music.note"), (true, "Video", "play.rectangle")], onGlass: true)
                .glassPanel(18)
        }
        .padding(.horizontal, 20)
        // Row centre at half the top-bar height, level with the window buttons.
        .frame(height: ContentView.topBarHeight)
        .background(WindowDragArea())
    }

    private var currentItem: MediaItem? {
        guard let t = player.current else { return nil }
        return MediaItem(id: t.videoId, kind: .song, title: t.title, thumbnail: t.thumbnail, videoId: t.videoId,
                         artists: t.artists, album: t.album, duration: t.duration)
    }

    private var content: some View {
        GeometryReader { g in
            let wide = g.size.width > 880 && !artworkOnly
            if wide {
                HStack(spacing: 64) {
                    artworkColumn(maxSide: min(g.size.width * 0.34, g.size.height - 285))
                        .frame(maxWidth: g.size.width * 0.38)
                    LyricsPane(state: lyrics.state)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
                .padding(.horizontal, 70)
                .padding(.top, 60)
                .padding(.bottom, PlayerBar.height + 24)
            } else if !artworkOnly {
                // Narrow window: compact song header on top, lyrics below.
                VStack(alignment: .leading, spacing: 18) {
                    if let t = player.current {
                        HStack(spacing: 14) {
                            Artwork(url: t.largeArtwork, cornerRadius: 10, size: 72)
                                .frame(width: 72, height: 72)
                                .shadow(color: .black.opacity(0.4), radius: 12, y: 6)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(t.title).font(.system(size: 18, weight: .bold)).lineLimit(2)
                                ArtistLinks(artists: t.artists).font(.system(size: 14)).foregroundStyle(.white.opacity(0.65)).lineLimit(1)
                            }
                            Spacer(minLength: 0)
                        }
                        .foregroundStyle(.white)
                    }
                    LyricsPane(state: lyrics.state)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .padding(.horizontal, 36)
                .padding(.top, 64)
                .padding(.bottom, PlayerBar.height + 24)
            } else {
                HStack {
                    Spacer(minLength: 0)
                    artworkColumn(maxSide: min(g.size.width * 0.55, g.size.height - 285))
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 40)
                .padding(.top, 60)
                .padding(.bottom, PlayerBar.height + 24)
            }
        }
    }

    private func artworkColumn(maxSide: CGFloat) -> some View {
        let side = max(maxSide, 200)
        return VStack(alignment: .leading, spacing: 18) {
            Spacer(minLength: 0)
            TiltingArtwork(url: player.current?.largeArtwork, side: side, breathing: artworkMoves && player.isPlaying)
                .scaleEffect(player.isPlaying ? 1 : 0.92)
                .animation(.spring(duration: 0.6, bounce: 0.25), value: player.isPlaying)
            if let t = player.current {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(t.title).font(.system(size: 22, weight: .bold)).lineLimit(1)
                        if t.isExplicit { ExplicitBadge() }
                    }
                    ArtistLinks(artists: t.artists).font(.system(size: 17)).foregroundStyle(.white.opacity(0.65)).lineLimit(1)
                    if let a = t.album {
                        Text(a.name).font(.system(size: 13)).foregroundStyle(.white.opacity(0.45)).lineLimit(1)
                            .underlineOnHover().onTapGesture { model.openAlbum(a) }
                    }
                }
                .frame(width: side, alignment: .leading)
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(.white)
    }
}

/// The big cover: tilts toward the cursor and, in the Artwork view, "breathes"
/// (a slow scale and float).
struct TiltingArtwork: View {
    let url: URL?
    let side: CGFloat
    var breathing = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        BreathingHost(active: breathing) {
            TiltCard(url: url, side: side).environment(\.colorScheme, scheme)
        }
        .frame(width: side, height: side)
    }
}

/// The cover and its shadow, tilting a little toward the pointer. Isolated so
/// pointer movement only re-renders this, not the lyrics.
private struct TiltCard: View {
    let url: URL?
    let side: CGFloat
    @ObservedObject private var pointer = PointerTracker.shared
    var body: some View {
        Artwork(url: url, cornerRadius: 18, size: side)
            .frame(width: side, height: side)
            .shadow(color: .black.opacity(0.5), radius: 34, y: 20)
            .rotation3DEffect(.degrees((pointer.point.y - 0.5) * -7), axis: (x: 1, y: 0, z: 0), perspective: 0.6)
            .rotation3DEffect(.degrees((pointer.point.x - 0.5) * 9), axis: (x: 0, y: 1, z: 0), perspective: 0.6)
            .animation(.spring(response: 0.9, dampingFraction: 0.8), value: pointer.point)
    }
}

/// Shows its content in a layer that can "breathe" — a slow scale (7 s) and float
/// (11 s) — animated by Core Animation alone, so nothing in SwiftUI or AppKit runs
/// while it moves. (Driving it from SwiftUI made the window lay itself out 30
/// times a second: about a third of a CPU core.) The content may draw outside the
/// frame (shadow, tilt), and clicks pass through to whatever is underneath.
private struct BreathingHost<Content: View>: NSViewRepresentable {
    var active: Bool
    @ViewBuilder var content: () -> Content

    func makeNSView(context: Context) -> BreathingView<Content> { BreathingView(rootView: content()) }
    func updateNSView(_ v: BreathingView<Content>, context: Context) {
        v.host.rootView = BreathingRoot(content: content())
        v.setActive(active)
    }
}

private struct BreathingRoot<Content: View>: View {
    let content: Content
    var body: some View {
        content.frame(maxWidth: .infinity, maxHeight: .infinity).ignoresSafeArea()
    }
}

private let breatheDepth: CGFloat = 0.018, breathePeriod: CFTimeInterval = 7
private let floatHeight: CGFloat = 4, floatPeriod: CFTimeInterval = 11

private final class BreathingView<Content: View>: NSView {
    let host: NSHostingView<BreathingRoot<Content>>
    /// Room around the frame for the shadow, the tilt and the breathing itself.
    private let margin: CGFloat = 110
    private var active = false
    /// When the current breathing began (the motion keeps its phase across re-layouts).
    private var startedAt: CFTimeInterval = 0

    init(rootView: Content) {
        host = NSHostingView(rootView: BreathingRoot(content: rootView))
        super.init(frame: .zero)
        wantsLayer = true
        clipsToBounds = false
        host.sizingOptions = []
        host.safeAreaRegions = []
        host.wantsLayer = true
        addSubview(host)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }   // never steal clicks

    override func layout() {
        super.layout()
        let f = bounds.insetBy(dx: -margin, dy: -margin)
        guard host.frame != f else { return }
        host.frame = f
        if active { breathe() }   // new centre, same phase
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if active, window != nil, host.layer?.animation(forKey: "breathe") == nil { breathe() }
    }

    func setActive(_ on: Bool) {
        guard on != active else { return }
        active = on
        if on {
            startedAt = CACurrentMediaTime()
            host.layer?.removeAnimation(forKey: "settle")
            breathe()
        } else {
            settle()
        }
    }

    /// The layer's centre, relative to its anchor point (which transforms pivot on).
    private func centre(of layer: CALayer) -> CGPoint {
        CGPoint(x: (0.5 - layer.anchorPoint.x) * layer.bounds.width, y: (0.5 - layer.anchorPoint.y) * layer.bounds.height)
    }

    /// Scale `s` about `c`, then lift by `y`.
    private func transform(scale s: CGFloat, lift y: CGFloat, centre c: CGPoint) -> CATransform3D {
        let m = CATransform3DScale(CATransform3DMakeTranslation(c.x, c.y + y, 0), s, s, 1)
        return CATransform3DTranslate(m, -c.x, -c.y, 0)
    }

    private func breathe() {
        guard let layer = host.layer, layer.bounds.width > 0 else { return }
        let c = centre(of: layer)
        let begin = layer.convertTime(startedAt, from: nil)
        let steps = 48
        let scale = CAKeyframeAnimation(keyPath: "transform")
        scale.values = (0...steps).map { i in
            let s = 1 + breatheDepth * sin(Double(i) / Double(steps) * 2 * .pi)
            return NSValue(caTransform3D: transform(scale: s, lift: 0, centre: c))
        }
        scale.duration = breathePeriod
        let lift = CAKeyframeAnimation(keyPath: "transform.translation.y")
        lift.values = (0...steps).map { i in floatHeight * sin(Double(i) / Double(steps) * 2 * .pi) }
        lift.duration = floatPeriod
        for (key, a) in [("breathe", scale), ("float", lift)] {
            a.isAdditive = true
            a.repeatCount = .infinity
            a.beginTime = begin
            a.isRemovedOnCompletion = false
            layer.add(a, forKey: key)
        }
    }

    /// Glide back to rest from wherever the motion is now.
    private func settle() {
        guard let layer = host.layer, layer.animation(forKey: "breathe") != nil else { return }
        let t = CACurrentMediaTime() - startedAt
        let s = 1 + breatheDepth * sin(t / breathePeriod * 2 * .pi)
        let y = floatHeight * sin(t / floatPeriod * 2 * .pi)
        layer.removeAnimation(forKey: "breathe")
        layer.removeAnimation(forKey: "float")
        let back = CABasicAnimation(keyPath: "transform")
        back.fromValue = NSValue(caTransform3D: transform(scale: s, lift: y, centre: centre(of: layer)))
        back.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        back.isAdditive = true
        back.duration = 0.9
        back.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(back, forKey: "settle")
    }
}

// MARK: - Lyrics

struct LyricsPane: View {
    let state: LyricsService.State
    var body: some View {
        switch state {
        case .idle, .unavailable:
            UpNextPanel()
        case .loading:
            ProgressView().controlSize(.large).frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loaded(let l):
            if l.synced { SyncedLyricsView(lyrics: l) } else { PlainLyricsView(lyrics: l) }
        }
    }
}

private let fadeMask = LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.1),
                                             .init(color: .black, location: 0.84), .init(color: .clear, location: 1)],
                                      startPoint: .top, endPoint: .bottom)

struct PlainLyricsView: View {
    let lyrics: Lyrics
    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(lyrics.lines) { line in
                    Text(line.text.isEmpty ? " " : line.text)
                        .font(.system(size: 26, weight: .bold))
                        .foregroundStyle(.white.opacity(0.82))
                }
                Text("Lyrics: \(lyrics.source) · not time-synced").font(.system(size: 11)).foregroundStyle(.white.opacity(0.4)).padding(.top, 20)
            }
            .padding(.vertical, 60)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
        }
        .mask(fadeMask)
    }
}

/// Lyric display settings, snapshotted from Prefs so rows can be cheaply compared.
struct LyricLook: Equatable {
    var size: Double
    var center: Bool
    var blur: Bool
    var glow: Bool
    var style: Prefs.LyricsStyle
    var offset: Double
    var font: Font { .system(size: size, weight: .bold) }

    @MainActor static var current: LyricLook {
        let p = Prefs.shared
        return LyricLook(size: p.lyricsSize, center: p.lyricsAlign == .center, blur: p.lyricsBlur,
                         glow: p.lyricsGlow, style: p.lyricsStyle, offset: p.lyricsOffset)
    }
}

struct SyncedLyricsView: View {
    let lyrics: Lyrics
    @ObservedObject private var prefs = Prefs.shared
    @State private var active: Int?
    @State private var scrolledTo: Int?
    @State private var userScrolledAt: Date = .distantPast
    private var player: PlayerController { .shared }
    private let ticker = Timer.publish(every: 1.0 / 60, on: .main, in: .common).autoconnect()

    var body: some View {
        let look = LyricLook.current
        let anchor = UnitPoint(x: look.center ? 0.5 : 0, y: 0.37)
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                // 2 rem above and below each line, as Better Lyrics does.
                VStack(alignment: look.center ? .center : .leading, spacing: look.size * 1.33) {
                    Color.clear.frame(height: 150)
                    ForEach(lyrics.lines) { line in
                        LyricRow(line: line, distance: active.map { line.id - $0 } ?? (line.id + 1), look: look)
                            .equatable()
                            .id(line.id)
                            .onTapGesture {
                                player.seek(to: max(0, line.start - 0.05 - look.offset))
                                if !player.isPlaying { player.resume() }
                            }
                    }
                    Text("Lyrics: \(lyrics.source)").font(.system(size: 11)).foregroundStyle(.white.opacity(0.35))
                    Color.clear.frame(height: 320)
                }
                .padding(.horizontal, 12)
            }
            .modifier(UserScrollDetector { userScrolledAt = Date() })
            .onReceive(ticker) { _ in
                guard player.isPlaying || active == nil else { return }
                // Lines light 150 ms ahead (word-synced) / 115 ms (line-synced); the view
                // scrolls half a second ahead of that, so the eye arrives before the voice.
                let lead = (lyrics.lines.first { !$0.text.isEmpty }?.exactWords ?? false) ? 0.15 : 0.115
                let t = player.clock.now() + look.offset + lead
                let idx = activeIndex(at: t)
                if idx != active { active = idx }
                let target = activeIndex(at: t + 0.5)
                if target != scrolledTo {
                    scrolledTo = target
                    if let target, Date().timeIntervalSince(userScrolledAt) > 3 {
                        withAnimation(.timingCurve(0.86, 0, 0.2, 1, duration: 0.75)) { proxy.scrollTo(target, anchor: anchor) }
                    }
                }
            }
            .onAppear {
                active = activeIndex(at: player.clock.now() + look.offset)
                if let a = active { proxy.scrollTo(a, anchor: anchor) }
            }
        }
        .mask(fadeMask)
    }

    private func activeIndex(at t: Double) -> Int? {
        var lo = 0, hi = lyrics.lines.count - 1, ans: Int? = nil
        while lo <= hi {
            let mid = (lo + hi) / 2
            if lyrics.lines[mid].start <= t + 0.05 { ans = mid; lo = mid + 1 } else { hi = mid - 1 }
        }
        return ans
    }
}

/// A lyric line. Inactive lines are static (cheap); only the active line animates per frame.
struct LyricRow: View, Equatable {
    let line: LyricLine
    let distance: Int
    let look: LyricLook

    static func == (a: LyricRow, b: LyricRow) -> Bool { a.line.id == b.line.id && a.distance == b.distance && a.look == b.look }

    var body: some View {
        let isActive = distance == 0
        let align: Alignment = look.center ? .center : .leading
        ZStack(alignment: align) {
            if line.text.isEmpty {
                if isActive { BreathingDots(line: line, offset: look.offset).transition(.opacity) } else { Color.clear.frame(height: 2) }
            } else {
                // One renderer for every line (active or not): no second copy, no jump.
                KaraokeLineView(line: line, look: look, active: isActive,
                                dimAlpha: 0.3,
                                blur: isActive || !look.blur ? 0 : CGFloat(min(Double(abs(distance)) * 1.1, 4)))
                    .frame(maxWidth: .infinity, alignment: look.center ? .center : .leading)
            }
        }
        // Line grows 0.95 → 1 in 166 ms as it starts; lit words fade back over 0.5 s when it ends.
        .scaleEffect(isActive ? 1 : 0.95, anchor: look.center ? .center : .leading)
        .animation(isActive ? .easeOut(duration: 0.166) : .easeInOut(duration: 0.33), value: isActive)
        .animation(.easeOut(duration: 0.5), value: distance)
        .frame(maxWidth: .infinity, alignment: align)
        .contentShape(Rectangle())
    }
}

/// Per-character timing for one line. Letters inside a word are timed in
/// sequence across that word's sung duration, back to back, so the fill moves
/// continuously through the line with no steps.
struct KaraokeTiming {
    let text: String
    let starts: [Double]
    let ends: [Double]
    let wordStarts: [Double]
    let wordEnds: [Double]
    var count: Int { starts.count }

    init(_ line: LyricLine) {
        var text = "", starts: [Double] = [], ends: [Double] = [], ws: [Double] = [], we: [Double] = []
        func add(_ word: [Character], from: Double, to: Double) {
            let per = max(to - from, 0.06) / Double(max(word.count, 1))
            for (i, c) in word.enumerated() {
                text.append(c)
                starts.append(from + per * Double(i)); ends.append(from + per * Double(i + 1))
                ws.append(from); we.append(max(to, from + 0.06))
            }
        }
        if line.words.isEmpty {
            add(Array(line.text), from: line.start, to: max(line.end, line.start + 0.5))
        } else {
            for (wi, w) in line.words.enumerated() {
                add(Array(w.text.trimmingCharacters(in: .whitespaces)), from: w.start, to: w.end)
                if wi < line.words.count - 1, w.trailingSpace {
                    let next = max(w.end + 0.01, line.words[wi + 1].start)
                    text.append(" "); starts.append(w.end); ends.append(next); ws.append(w.end); we.append(next)
                }
            }
        }
        self.text = text; self.starts = starts; self.ends = ends; self.wordStarts = ws; self.wordEnds = we
    }

    /// 0…1 linear fill of character i at time t.
    func fill(_ i: Int, at t: Double) -> Double {
        guard i >= 0, i < count else { return 0 }
        return max(0, min(1, (t - starts[i]) / max(ends[i] - starts[i], 0.001)))
    }

    /// 0…1 eased fill of the whole word containing character i.
    func wordFill(_ i: Int, at t: Double) -> Double {
        guard i >= 0, i < count else { return 0 }
        let x = max(0, min(1, (t - wordStarts[i]) / max(min(wordEnds[i] - wordStarts[i], 0.35), 0.001)))
        return x * x * (3 - 2 * x)
    }

    /// Glow envelope: rises as the letter starts, holds while sung, then fades over ~0.6 s.
    func highlight(_ i: Int, at t: Double) -> Double {
        guard i >= 0, i < count else { return 0 }
        let rise = (t - (starts[i] - 0.06)) / 0.12
        if rise <= 0 { return 0 }
        if t <= ends[i] { return min(1, rise) }
        let x = 1 - (t - ends[i]) / 0.6
        return x > 0 ? x * x * (3 - 2 * x) : 0
    }
}

struct ActiveLyricLine: View {
    let line: LyricLine
    let look: LyricLook
    private var player: PlayerController { .shared }
    @ObservedObject private var now = PlayerController.shared.now

    var body: some View {
        let timing = KaraokeTiming(line)
        TimelineView(.animation(paused: !now.isPlaying)) { tl in
            let t = player.clock.now(tl.date) + look.offset
            Group {
                if look.style == .line {
                    Text(timing.text).foregroundStyle(.white)
                        .shadow(color: .white.opacity(look.glow ? 0.45 : 0), radius: 12)
                } else if #available(macOS 15.0, *) {
                    Text(timing.text)
                        .foregroundStyle(.white)
                        .textRenderer(KaraokeRenderer(timing: timing, time: t, glow: look.glow, perWord: look.style == .fade))
                } else {
                    timing.text.enumerated().reduce(Text("")) { acc, pair in
                        acc + Text(String(pair.element)).foregroundColor(.white.opacity(0.32 + 0.68 * timing.fill(pair.offset, at: t)))
                    }
                }
            }
            .font(look.font)
            .multilineTextAlignment(look.center ? .center : .leading)
        }
    }
}

/// Karaoke wipe: each glyph is drawn dim, then a bright copy is revealed left
/// to right through a soft-edged mask as it's sung. The letter currently being
/// sung glows and lifts slightly, and the glow trails off behind it.
@available(macOS 15.0, *)
struct KaraokeRenderer: TextRenderer {
    let timing: KaraokeTiming
    let time: Double
    var glow = true
    var perWord = false

    var displayPadding: EdgeInsets { EdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 16) }

    func draw(layout: Text.Layout, in ctx: inout GraphicsContext) {
        var total = 0
        for line in layout { for run in line { total += run.count } }
        let n = timing.count
        var g = 0
        for line in layout {
            for run in line {
                for slice in run {
                    let ci = (total == n || total == 0) ? g : min(n - 1, g * n / total)
                    g += 1
                    let f = perWord ? timing.wordFill(ci, at: time) : timing.fill(ci, at: time)
                    let h = timing.highlight(ci, at: time)
                    let r = slice.typographicBounds.rect
                    let lift = -2.2 * h - 0.8 * f
                    let scale = 1 + 0.04 * h

                    var c = ctx
                    c.translateBy(x: r.midX, y: r.midY + lift)
                    c.scaleBy(x: scale, y: scale)
                    c.translateBy(x: -r.midX, y: -r.midY)

                    // 1. Unsung glyph.
                    var dim = c
                    dim.opacity = 0.34
                    dim.draw(slice)
                    guard f > 0.001 else { continue }

                    // 2. Soft glow around the letter being sung, trailing off afterwards.
                    if glow && h > 0.02 {
                        var gl = c
                        gl.opacity = 0.85 * h * min(1, f * 3)
                        gl.addFilter(.blur(radius: 8))
                        gl.draw(slice)
                    }

                    // 3. Bright glyph, revealed by a feathered left-to-right wipe (or faded per word).
                    var lit = c
                    if perWord {
                        lit.opacity = f
                    } else if f < 1 {
                        let feather = max(r.width * 0.7, 7)
                        let span = r.width + feather
                        let edge = r.minX - feather + span * f
                        let x0 = r.minX - feather, x1 = r.maxX + feather
                        let a = min(1, max(0, (edge - x0) / (x1 - x0)))
                        let b = min(1, max(a, (edge + feather - x0) / (x1 - x0)))
                        lit.clipToLayer { mask in
                            mask.fill(Path(CGRect(x: x0, y: r.minY - 10, width: x1 - x0, height: r.height + 20)),
                                      with: .linearGradient(Gradient(stops: [
                                        .init(color: .black, location: a),
                                        .init(color: .clear, location: b),
                                      ]), startPoint: CGPoint(x: x0, y: 0), endPoint: CGPoint(x: x1, y: 0)))
                        }
                    }
                    lit.draw(slice)
                }
            }
        }
    }
}

struct BreathingDots: View {
    let line: LyricLine
    var offset: Double = 0
    private var player: PlayerController { .shared }
    var body: some View {
        TimelineView(.animation) { tl in
            let t = player.clock.now(tl.date) + offset
            let span = max(line.end - line.start, 0.1)
            let p = max(0, min(1, (t - line.start) / span))
            HStack(spacing: 10) {
                ForEach(0..<3) { i in
                    let local = max(0, min(1, p * 3 - Double(i)))
                    let breathe = 0.92 + 0.1 * sin(t * 2.6)
                    Circle().fill(.white.opacity(0.3 + 0.7 * local))
                        .frame(width: 12, height: 12)
                        .scaleEffect(breathe * (0.85 + 0.25 * local))
                }
            }
            .frame(height: 34)
        }
    }
}

/// Pauses lyric auto-scroll for a few seconds while the user scrolls manually.
struct UserScrollDetector: ViewModifier {
    let onScroll: () -> Void
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.onScrollPhaseChange { _, phase in if phase == .interacting { onScroll() } }
        } else {
            content
        }
    }
}

// MARK: - Video surface

/// Hosts the player web view inside the main window for its whole lifetime,
/// so switching to Video never moves it (moving it could pause playback).
struct VideoHost: NSViewRepresentable {
    final class Container: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }   // never steal clicks
    }
    func makeNSView(context: Context) -> NSView {
        let v = Container()
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor.black.cgColor
        DispatchQueue.main.async { WebHost.shared.adopt(into: v) }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
    static func dismantleNSView(_ nsView: NSView, coordinator: ()) {
        DispatchQueue.main.async { WebHost.shared.park() }
    }
}


/// Shown where lyrics would be when a song has none: what's playing next.
struct UpNextPanel: View {
    @EnvironmentObject var player: PlayerController
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Text("Up Next").font(.system(size: 26, weight: .bold))
                Spacer()
                Text("No lyrics for this song").font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.45))
            }
            if player.upNext.isEmpty {
                Text(player.autoplay ? "Similar music will play next." : "Nothing queued.")
                    .font(.system(size: 14)).foregroundStyle(.white.opacity(0.55))
            }
            ScrollView(showsIndicators: false) {
                VStack(spacing: 4) {
                    ForEach(Array(player.upNext.prefix(12))) { t in
                        UpNextRow(track: t)
                    }
                }
            }
        }
        .padding(.top, 40)
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct UpNextRow: View {
    let track: Track
    @State private var hover = false
    var body: some View {
        HStack(spacing: 14) {
            Artwork(url: track.thumbnail, cornerRadius: 8, size: 52).frame(width: 52, height: 52)
            VStack(alignment: .leading, spacing: 3) {
                Text(track.title).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                Text(track.artistLine).font(.system(size: 13)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
            }
            Spacer()
            if let d = track.duration { Text(formatTime(d)).font(.system(size: 12).monospacedDigit()).foregroundStyle(.white.opacity(0.5)) }
            Image(systemName: "play.fill").font(.system(size: 12)).opacity(hover ? 1 : 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(hover ? 0.1 : 0)))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { PlayerController.shared.jump(to: track) }
    }
}
