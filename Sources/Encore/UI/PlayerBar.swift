import SwiftUI

struct PlayerBar: View {
    static let height: CGFloat = 78
    @ObservedObject private var prefs = Prefs.shared
    @EnvironmentObject var player: PlayerController
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        // Three balanced zones: song (left), transport (centre, fixed), tools (right),
        // separated by hairlines so each reads as its own group.
        GeometryReader { g in
            let compact = g.size.width < 1200
            // Half- and quarter-screen windows: fewer buttons, tighter transport.
            let narrow = g.size.width < 980
            HStack(spacing: 0) {
                nowPlaying(narrow: narrow)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Separator()
                VStack(spacing: 2) {
                    TransportControls(size: .regular, spread: true)
                        .padding(.horizontal, 28)
                    ScrubberBar()
                }
                .frame(width: narrow ? max(230, g.size.width * 0.36) : min(460, max(320, g.size.width * 0.34)))
                .padding(.horizontal, narrow ? 8 : (compact ? 12 : 18))
                Separator()
                right(compact: compact, narrow: narrow)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .padding(.horizontal, 16)
            .frame(height: Self.height)
        }
        .frame(height: Self.height)
        .glassPanel(22, dense: true)
        .shadow(color: .black.opacity(0.28), radius: 18, y: 8)
    }

    private struct Separator: View {
        var body: some View { Rectangle().fill(Color.primary.opacity(0.1)).frame(width: 1, height: 36) }
    }

    private func nowPlaying(narrow: Bool) -> some View {
        HStack(spacing: narrow ? 10 : 12) {
            if let t = player.current {
                Artwork(url: t.thumbnail, cornerRadius: 8, size: 52)
                    .frame(width: 52, height: 52)
                    .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
                    .onTapGesture { withAnimation(.spring(duration: 0.5, bounce: 0.15)) { model.showNowPlaying.toggle() } }
                    .help("Show Now Playing")
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(t.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        if t.isExplicit { ExplicitBadge() }
                    }
                    ArtistLinks(artists: t.artists).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(1)
                if !narrow {
                HStack(spacing: 8) {
                    Button { player.toggleLike() } label: {
                        Image(systemName: player.likeStatus == .like ? "hand.thumbsup.fill" : "hand.thumbsup")
                            .foregroundStyle(player.likeStatus == .like ? Color.accentColor : .primary)
                    }.hoverTip(player.likeStatus == .like ? "Remove like" : "Like")
                    Button { player.toggleDislike() } label: {
                        Image(systemName: player.likeStatus == .dislike ? "hand.thumbsdown.fill" : "hand.thumbsdown")
                            .foregroundStyle(player.likeStatus == .dislike ? Color.accentColor : .primary)
                    }.hoverTip(player.likeStatus == .dislike ? "Remove dislike" : "Dislike")
                    Menu {
                        if let item = currentItem { ItemMenu(item: item) }
                    } label: { Image(systemName: "ellipsis") }
                        .menuStyle(.button).menuIndicator(.hidden)
                        .hoverTip("More")
                }
                .buttonStyle(BarIconStyle(size: 14))
                .padding(.trailing, 18)
                }
            } else {
                RoundedRectangle(cornerRadius: 8).fill(.quaternary).frame(width: 52, height: 52)
                    .overlay(Image(systemName: "music.note").foregroundStyle(.tertiary))
                Text("Not Playing").foregroundStyle(.secondary).font(.system(size: 13))
            }
        }
    }

    private var currentItem: MediaItem? {
        guard let t = player.current else { return nil }
        return MediaItem(id: t.videoId, kind: t.isVideo ? .video : .song, title: t.title, thumbnail: t.thumbnail,
                         videoId: t.videoId, artists: t.artists, album: t.album, duration: t.duration)
    }

    private func right(compact: Bool, narrow: Bool) -> some View {
        HStack(spacing: 0) {
            if narrow {
                // No room for the slider: a speaker button that opens it.
                CompactVolumeButton().padding(.leading, 8)
            } else {
                VolumeControl()
                    .frame(minWidth: 110, maxWidth: compact ? 150 : 230)
                    .padding(.leading, compact ? 12 : 20)
            }
            Spacer(minLength: narrow ? 8 : 14)
            HStack(spacing: narrow ? 4 : (compact ? 8 : 16)) {
                // Always lands on the lyrics (even from the Artwork view); closes them if showing.
                let lyricsShown = model.showNowPlaying && prefs.nowPlayingLayout == .lyrics
                Button {
                    withAnimation(.spring(duration: 0.45)) {
                        if lyricsShown { model.showNowPlaying = false } else {
                            prefs.nowPlayingLayout = .lyrics
                            model.showNowPlaying = true
                        }
                    }
                } label: {
                    Image(systemName: lyricsShown ? "quote.bubble.fill" : "quote.bubble")
                }
                .foregroundStyle(lyricsShown ? Color.accentColor : .primary)
                .hoverTip("Lyrics")
                Button { withAnimation(Motion.panel) { model.showQueue.toggle() } } label: { Image(systemName: "list.bullet") }
                    .foregroundStyle(model.showQueue ? Color.accentColor : .primary)
                    .hoverTip("Queue")
                if !narrow { FadeControl() }
                Button { openWindow(id: "mini") } label: { Image(systemName: "pip") }
                    .hoverTip("Mini Player")
                Button { withAnimation(.spring(duration: 0.45)) { model.showNowPlaying.toggle() } } label: {
                    Image(systemName: model.showNowPlaying ? "chevron.down" : "chevron.up")
                }
                .hoverTip(model.showNowPlaying ? "Close Now Playing" : "Open Now Playing")
            }
            .buttonStyle(BarIconStyle(size: 14))
        }
    }
}

/// Icon button: soft circular highlight on hover, quick press-in, and the
/// action fires on the first click.
struct BarIconStyle: ButtonStyle {
    var size: CGFloat = 15
    /// Hit/hover circle; pass the housing's size so the hover fill covers it exactly.
    var diameter: CGFloat? = nil
    func makeBody(configuration: Configuration) -> some View { IconButtonBody(configuration: configuration, size: size, diameter: diameter ?? max(30, size * 2)) }

    private struct IconButtonBody: View {
        let configuration: Configuration
        let size: CGFloat
        let diameter: CGFloat
        @State private var hover = false
        @Environment(\.isEnabled) private var enabled
        var body: some View {
            configuration.label
                .font(.system(size: size, weight: .medium))
                .frame(width: diameter, height: diameter)
                .background(Circle().fill(Color.primary.opacity(configuration.isPressed ? 0.28 : (hover ? 0.16 : 0))))
                .overlay(Circle().strokeBorder(Color.primary.opacity(hover ? 0.12 : 0), lineWidth: 0.5))
                .cursorSheen(Circle(), strength: 0.16)
                .contentShape(Circle())
                .scaleEffect(configuration.isPressed ? 0.86 : 1)
                .opacity(enabled ? (hover ? 1 : 0.85) : 0.35)
                .animation(.spring(duration: 0.2, bounce: 0.4), value: configuration.isPressed)
                .animation(.easeOut(duration: 0.15), value: hover)
                .onHover { hover = $0 && enabled }
        }
    }
}

struct TransportControls: View {
    enum Size { case regular, compact, large }
    var size: Size = .regular
    var showShuffleRepeat = true
    /// Spread the controls evenly across all available width.
    var spread = false
    @EnvironmentObject var player: PlayerController

    var body: some View {
        let s: CGFloat = size == .compact ? 13 : (size == .large ? 22 : 15)
        let playSize: CGFloat = size == .compact ? 30 : (size == .large ? 58 : 36)
        HStack(spacing: spread ? 0 : (size == .compact ? 8 : 18)) {
            if spread { Spacer(minLength: 0) }
            if showShuffleRepeat {
                Button { player.toggleShuffle() } label: { Image(systemName: "shuffle") }
                    .foregroundStyle(player.shuffle ? Color.accentColor : .primary)
                    .overlay(alignment: .bottom) { if player.shuffle { Circle().fill(Color.accentColor).frame(width: 4, height: 4).offset(y: 8) } }
                    .hoverTip(player.shuffle ? "Shuffle: On" : "Shuffle: Off")
            }
            if spread && showShuffleRepeat { Spacer(minLength: 6) }
            Button { player.previous() } label: { Image(systemName: "backward.fill") }.hoverTip("Previous")
            if spread { Spacer(minLength: 6) }
            Button { player.togglePlayPause() } label: {
                ZStack {
                    // The glyph stays in place (never rebuilt), so its play ⇄ pause
                    // morph is never cut short; the spinner just fades over it.
                    let spinning = player.isBuffering && player.isPlaying
                    PlayPauseGlyph(playing: player.isPlaying, size: playSize)
                        .opacity(spinning ? 0 : 1)
                    if spinning { ProgressView().controlSize(.small).transition(.opacity) }
                }
                .animation(.easeOut(duration: 0.15), value: player.isBuffering)
                .frame(width: playSize, height: playSize)
            }
            .buttonStyle(PlayButtonStyle(size: playSize))
            .hoverTip(player.isPlaying ? "Pause" : "Play")
            .disabled(player.current == nil)
            if spread { Spacer(minLength: 6) }
            Button { player.next() } label: { Image(systemName: "forward.fill") }.hoverTip("Next")
            if spread && showShuffleRepeat { Spacer(minLength: 6) }
            if showShuffleRepeat {
                Button { player.repeatMode = player.repeatMode.next } label: { Image(systemName: player.repeatMode.symbol) }
                    .foregroundStyle(player.repeatMode != .off ? Color.accentColor : .primary)
                    .overlay(alignment: .bottom) { if player.repeatMode != .off { Circle().fill(Color.accentColor).frame(width: 4, height: 4).offset(y: 8) } }
                    .hoverTip("Repeat: \(player.repeatMode.rawValue.capitalized)")
            }
            if spread { Spacer(minLength: 0) }
        }
        .buttonStyle(BarIconStyle(size: s))
    }
}

/// Progress bar that swells and magnifies when the pointer is over it, shows
/// the time under the cursor, and is easy to grab (tall invisible hit area).
struct ScrubberBar: View {
    var showTimes = true
    @EnvironmentObject var player: PlayerController
    @EnvironmentObject var clock: PlaybackClock
    @State private var dragValue: Double?
    @State private var hoverX: CGFloat?
    @State private var hover = false

    var body: some View {
        HStack(spacing: 10) {
            if showTimes { time(dragValue ?? clock.time).frame(width: 40, alignment: .trailing) }
            GeometryReader { g in
                let w = g.size.width
                let active = hover || dragValue != nil
                Group {
                if !active {
                    // At rest: Core Animation glides the bar on its own, so playback
                    // costs no per-frame work in the app. Re-synced each second.
                    let t = clock.now()
                    CAProgressBar(fraction: clock.duration > 0 ? t / clock.duration : 0,
                                  perSecond: player.isPlaying && clock.duration > 0 ? clock.rate / clock.duration : 0,
                                  syncTick: Int(clock.time) &+ clock.epoch)
                        .frame(height: 4)
                        .frame(maxHeight: .infinity)
                } else {
                TimelineView(.animation(minimumInterval: 1 / 60, paused: !player.isPlaying || dragValue != nil)) { tl in
                    let t = dragValue ?? clock.now(tl.date)
                    let p = clock.duration > 0 ? max(0, min(1, t / clock.duration)) : 0
                    ZStack(alignment: .leading) {
                        Capsule().fill(.primary.opacity(0.16))
                        Capsule().fill(.primary.opacity(active ? 0.95 : 0.7))
                            .frame(width: max(active ? 8 : 4, p * w))
                    }
                    .frame(height: active ? 9 : 4)
                    .overlay(alignment: .leading) {
                        Circle().fill(.white)
                            .frame(width: active ? 15 : 0, height: active ? 15 : 0)
                            .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
                            .offset(x: p * w - (active ? 7.5 : 0))
                    }
                    .frame(maxHeight: .infinity)
                }
                }
                }
                .overlay(alignment: .topLeading) {
                    if let hx = hoverX, dragValue == nil, clock.duration > 0 {
                        Text(formatTime(Double(hx / w) * clock.duration))
                            .font(.system(size: 10, weight: .semibold).monospacedDigit())
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .glassPanel(6)
                            .fixedSize()
                            .offset(x: min(max(hx - 18, -6), w - 30), y: -14)
                            .transition(.opacity)
                    }
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { v in dragValue = max(0, min(1, v.location.x / w)) * clock.duration }
                    .onEnded { _ in if let d = dragValue { player.seek(to: d) }; dragValue = nil })
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let p): hoverX = max(0, min(w, p.x))
                    case .ended: hoverX = nil
                    }
                }
                .onHover { h in withAnimation(.spring(duration: 0.25, bounce: 0.3)) { hover = h } }
                .scaleEffect(x: 1, y: hover ? 1.08 : 1)
                .animation(.spring(duration: 0.25, bounce: 0.3), value: dragValue != nil)
            }
            .frame(height: 22)
            if showTimes { time(clock.duration).frame(width: 40, alignment: .leading) }
        }
    }

    private func time(_ t: Double) -> some View {
        Text(formatTime(t))
            .font(.system(size: hover || dragValue != nil ? 11.5 : 10.5, weight: hover || dragValue != nil ? .semibold : .medium).monospacedDigit())
            .foregroundStyle(hover || dragValue != nil ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            .animation(.spring(duration: 0.25), value: hover || dragValue != nil)
    }
}

/// Big, bright, perfectly centred play/pause disc that reacts to hover and press.
struct PlayButtonStyle: ButtonStyle {
    var size: CGFloat
    @State private var hover = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Color.black)
            .background(Circle().fill(Color.white))
            .overlay(Circle().strokeBorder(.white.opacity(0.6), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.35), radius: hover ? 10 : 6, y: 3)
            .shadow(color: .white.opacity(hover ? 0.35 : 0.15), radius: hover ? 14 : 8)
            .scaleEffect(configuration.isPressed ? 0.9 : (hover ? 1.07 : 1))
            .animation(.spring(duration: 0.25, bounce: 0.35), value: configuration.isPressed)
            .animation(.spring(duration: 0.3, bounce: 0.3), value: hover)
            .onHover { hover = $0 }
            .contentShape(Circle())
    }
}

struct TimeLabel: View {
    @EnvironmentObject var clock: PlaybackClock
    var body: some View {
        Text("\(formatTime(clock.time)) / \(formatTime(clock.duration))")
            .font(.system(size: 11).monospacedDigit())
            .foregroundStyle(.secondary)
    }
}

/// Volume: speaker button plus a slim track that thickens on hover. The level
/// shows in a bubble above while you adjust it (never over the track itself).
/// Volume for narrow windows: the speaker icon (showing the level); clicking it
/// opens the full volume slider in a small popover.
struct CompactVolumeButton: View {
    @EnvironmentObject var player: PlayerController
    @State private var open = false
    var body: some View {
        let level = player.muted ? 0 : player.volume / 100
        Button { open.toggle() } label: {
            Image(systemName: level == 0 ? "speaker.slash.fill" : "speaker.wave.3.fill", variableValue: level)
        }
        .buttonStyle(BarIconStyle(size: 13))
        .hoverTip("Volume")
        .popover(isPresented: $open, arrowEdge: .top) {
            VolumeControl().environmentObject(player).frame(width: 190).padding(.horizontal, 14).padding(.vertical, 10)
        }
    }
}

struct VolumeControl: View {
    @EnvironmentObject var player: PlayerController
    @State private var hover = false
    @State private var dragging = false
    @State private var bubbleUntil = Date.distantPast

    var body: some View {
        let level = player.muted ? 0 : player.volume / 100
        let active = hover || dragging
        HStack(spacing: 8) {
            Button { player.toggleMute() } label: {
                Image(systemName: level == 0 ? "speaker.slash.fill" : "speaker.wave.3.fill", variableValue: level)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(BarIconStyle(size: 13))
            .hoverTip(player.muted ? "Unmute" : "Mute")
            GeometryReader { g in
                let w = g.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.18))
                    Capsule().fill(Color.primary.opacity(active ? 1 : 0.8))
                        .frame(width: max(0, CGFloat(level) * w))
                }
                .frame(height: active ? 6 : 4)
                .overlay(alignment: .leading) {
                    Circle().fill(.white)
                        .frame(width: active ? 13 : 0, height: active ? 13 : 0)
                        .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                        .offset(x: CGFloat(level) * w - (active ? 6.5 : 0))
                }
                .frame(maxHeight: .infinity)
                .overlay(alignment: .topLeading) {
                    if dragging || Date() < bubbleUntil {
                        Text("\(Int((level * 100).rounded()))%")
                            .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(Capsule().fill(Color.black.opacity(0.8)))
                            .fixedSize()
                            .offset(x: min(max(CGFloat(level) * w - 18, -8), w - 30), y: -22)
                            .transition(.opacity)
                            .allowsHitTesting(false)
                    }
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        if !dragging { withAnimation(.easeOut(duration: 0.12)) { dragging = true } }
                        if player.muted { player.toggleMute() }
                        player.volume = max(0, min(100, Double(v.location.x / w) * 100))
                    }
                    .onEnded { _ in withAnimation(.easeOut(duration: 0.25)) { dragging = false } })
            }
            .frame(height: 24)
            .animation(.spring(duration: 0.25, bounce: 0.3), value: active)
        }
        .onHover { hover = $0 }
        .background(ScrollWheelCatcher { dy in
            if player.muted { player.toggleMute() }
            player.volume = max(0, min(100, player.volume + dy))
            bubbleUntil = Date().addingTimeInterval(0.9)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { bubbleUntil = .distantPast }
        })
    }
}

/// Lets the volume slider be adjusted with the scroll wheel / two-finger swipe.
struct ScrollWheelCatcher: NSViewRepresentable {
    let onScroll: (Double) -> Void
    func makeNSView(context: Context) -> NSView { Catcher(onScroll: onScroll) }
    func updateNSView(_ nsView: NSView, context: Context) {}
    final class Catcher: NSView {
        let onScroll: (Double) -> Void
        init(onScroll: @escaping (Double) -> Void) { self.onScroll = onScroll; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError() }
        override func scrollWheel(with e: NSEvent) {
            let d = abs(e.scrollingDeltaX) > abs(e.scrollingDeltaY) ? e.scrollingDeltaX : -e.scrollingDeltaY
            onScroll(Double(d) * (e.hasPreciseScrollingDeltas ? 0.25 : 2))
        }
    }
}


/// Play/pause drawn as shapes so they're mathematically centred in the disc
/// (SF Symbols carry uneven side bearings). The triangle is nudged right by its
/// optical centre (one third of its width), as a real play button should be.
struct PlayPauseGlyph: View {
    let playing: Bool
    let size: CGFloat
    var body: some View {
        ZStack {
            HStack(spacing: size * 0.11) {
                RoundedRectangle(cornerRadius: size * 0.03).frame(width: size * 0.115, height: size * 0.36)
                RoundedRectangle(cornerRadius: size * 0.03).frame(width: size * 0.115, height: size * 0.36)
            }
            .opacity(playing ? 1 : 0)
            .scaleEffect(playing ? 1 : 0.6)
            PlayTriangle()
                .frame(width: size * 0.34, height: size * 0.38)
                .offset(x: size * 0.034)
                .opacity(playing ? 0 : 1)
                .scaleEffect(playing ? 0.6 : 1)
        }
        .frame(width: size, height: size)
        .animation(.spring(duration: 0.25, bounce: 0.3), value: playing)
    }
}

struct PlayTriangle: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        let k = min(r.width, r.height) * 0.12   // corner rounding
        p.move(to: CGPoint(x: r.minX + k * 0.4, y: r.minY + k))
        p.addQuadCurve(to: CGPoint(x: r.minX + k * 1.2, y: r.minY + k * 0.2), control: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX - k * 0.8, y: r.midY - k * 0.55))
        p.addQuadCurve(to: CGPoint(x: r.maxX - k * 0.8, y: r.midY + k * 0.55), control: CGPoint(x: r.maxX, y: r.midY))
        p.addLine(to: CGPoint(x: r.minX + k * 1.2, y: r.maxY - k * 0.2))
        p.addQuadCurve(to: CGPoint(x: r.minX + k * 0.4, y: r.maxY - k), control: CGPoint(x: r.minX, y: r.maxY))
        p.closeSubpath()
        return p
    }
}


/// A slim progress bar animated entirely by Core Animation: given where playback is
/// and how fast it moves, the fill glides to the end by itself (no app work per frame).
struct CAProgressBar: NSViewRepresentable {
    var fraction: Double
    var perSecond: Double
    var syncTick: Int

    final class BarView: NSView {
        let track = CALayer(), fill = CALayer()
        var fraction = 0.0, perSecond = 0.0
        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.addSublayer(track); layer?.addSublayer(fill)
            fill.anchorPoint = CGPoint(x: 0, y: 0.5)
        }
        required init?(coder: NSCoder) { fatalError() }
        override func layout() { super.layout(); apply() }
        override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); apply() }

        func apply() {
            let b = bounds
            CATransaction.begin(); CATransaction.setDisableActions(true)
            effectiveAppearance.performAsCurrentDrawingAppearance {
                track.backgroundColor = NSColor.labelColor.withAlphaComponent(0.16).cgColor
                fill.backgroundColor = NSColor.labelColor.withAlphaComponent(0.7).cgColor
            }
            track.frame = b
            track.cornerRadius = b.height / 2
            fill.cornerRadius = b.height / 2
            let f = max(0, min(1, fraction))
            let w0 = max(4, b.width * f)
            fill.bounds = CGRect(x: 0, y: 0, width: w0, height: b.height)
            fill.position = CGPoint(x: 0, y: b.midY)
            fill.removeAnimation(forKey: "p")
            CATransaction.commit()
            guard perSecond > 0, f < 1, b.width > 0 else { return }
            let anim = CABasicAnimation(keyPath: "bounds.size.width")
            anim.fromValue = w0
            anim.toValue = b.width
            anim.duration = (1 - f) / perSecond
            anim.timingFunction = CAMediaTimingFunction(name: .linear)
            anim.fillMode = .forwards
            anim.isRemovedOnCompletion = false
            fill.add(anim, forKey: "p")
        }
    }

    func makeNSView(context: Context) -> BarView { BarView() }
    func updateNSView(_ v: BarView, context: Context) {
        v.fraction = fraction; v.perSecond = perSecond
        v.apply()
    }
}

/// Crossfade: a button beside the volume showing "song → song" (a faded note, an
/// arrow, a solid note). Lit in the accent colour, with a dot underneath like shuffle
/// and repeat, while it's on. Opens a slider (Off–12 s).
struct FadeControl: View {
    @EnvironmentObject var player: PlayerController
    @State private var open = false

    var body: some View {
        let on = player.fadeSeconds > 0
        Button { open.toggle() } label: {
            HStack(spacing: 1) {
                Image(systemName: "music.note").opacity(0.45)
                Image(systemName: "arrow.right").font(.system(size: 8, weight: .heavy))
                Image(systemName: "music.note")
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(on ? Color.accentColor : .primary)
        }
        .buttonStyle(BarIconStyle(size: 12, diameter: 36))
        .overlay(alignment: .bottom) {
            if on { Circle().fill(Color.accentColor).frame(width: 4, height: 4).offset(y: 6) }
        }
        .hoverTip(on ? "Crossfade: \(Int(player.fadeSeconds)) s" : "Crossfade: Off")
        .popover(isPresented: $open, arrowEdge: .top) {
            FadePopover().environmentObject(player)
        }
    }
}

private struct FadePopover: View {
    @EnvironmentObject var player: PlayerController

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Crossfade").font(.system(size: 13, weight: .semibold))
                Spacer()
                Text(player.fadeSeconds > 0 ? "\(Int(player.fadeSeconds)) s" : "Off")
                    .font(.system(size: 13).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: $player.fadeSeconds, in: 0...12, step: 1) {
                EmptyView()
            } minimumValueLabel: {
                Text("Off").font(.system(size: 11)).foregroundStyle(.secondary)
            } maximumValueLabel: {
                Text("12 s").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Text("The next song starts while this one fades out, so the two blend into each other. On repeat one, a song crossfades into its own start.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            Toggle(isOn: $player.smartFade) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Smart").font(.system(size: 13, weight: .semibold))
                    Text("Songs from the same album run straight into each other, and short songs get a shorter crossfade.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .disabled(player.fadeSeconds == 0)
        }
        .padding(16)
        .frame(width: 290)
    }
}
