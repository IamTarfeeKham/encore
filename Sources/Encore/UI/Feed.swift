import AppKit
import SwiftUI

/// One row of an endless feed (a title, the chips, a shelf, the spinner…).
struct FeedRow: Identifiable {
    let id: String
    /// Height used for the row until it has been built and measured.
    let estimate: CGFloat
    /// Gap below the row.
    let spacing: CGFloat
    let content: () -> AnyView
}

/// The Home / Explore feed, built the way YouTube's is.
///
/// It stays a normal SwiftUI scroll view (so trackpad and mouse scrolling, and
/// sideways swipes on the carousels inside it, behave exactly as before), but which
/// rows exist is decided here instead of by a lazy stack:
/// - Rows are **prepared ahead, while you're not scrolling**: when the page comes to
///   rest, the next few screens of sections are built one per run-loop turn, so a
///   scroll rarely has to build anything mid-frame.
/// - Rows far from view are replaced by an empty space of their exact measured height
///   (nothing moves), freeing their views; they're rebuilt ahead of time on the way back.
struct FeedView: View {
    let rows: [FeedRow]
    /// Changes when the whole feed is replaced (another chip, a reload).
    let resetKey: String
    var onNearEnd: () -> Void = {}
    var onPull: (CGFloat) -> Void = { _ in }

    @StateObject private var model = FeedModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(rows) { row in
                    Group {
                        if model.built.contains(row.id) {
                            row.content()
                                .fixedSize(horizontal: false, vertical: true)
                                .modifier(FeedHeightReporter(id: row.id, model: model))
                        } else {
                            Color.clear.frame(height: model.heights[row.id] ?? row.estimate)
                        }
                    }
                    .padding(.bottom, row.spacing)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // While the width is animating, carousels keep one wide layout (clipped by
            // the window) instead of re-measuring every frame.
            .environment(\.carouselOverhangWidth, model.frozen ? model.overhangWidth : nil)
            .onPreferenceChange(FeedHeightsKey.self) { model.measured($0) }
            .background(FeedScrollObserver(model: model))
        }
        .onAppear { sync() }
        .onChange(of: rows.map(\.id)) { _, _ in sync() }
        .onChange(of: resetKey) { _, _ in model.reset(); sync() }
    }

    private func sync() {
        model.onNearEnd = onNearEnd
        model.onPull = onPull
        model.setRows(rows.map { FeedModel.Meta(id: $0.id, estimate: $0.estimate, spacing: $0.spacing) })
    }
}

private struct FeedHeightsKey: PreferenceKey {
    static let defaultValue: [String: CGFloat] = [:]
    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue()) { $1 }
    }
}

@MainActor
final class FeedModel: ObservableObject {
    struct Meta { let id: String; let estimate: CGFloat; let spacing: CGFloat }

    /// Rows that currently exist as real views.
    @Published private(set) var built: Set<String> = []
    /// Measured heights (kept after a row is released, so its space stays exact).
    private(set) var heights: [String: CGFloat] = [:]
    var onNearEnd: () -> Void = {}
    var onPull: (CGFloat) -> Void = { _ in }

    /// True while the page width is changing; see FeedView.
    @Published private(set) var frozen = false
    /// Width carousels are laid out at while frozen: wide enough for any page width.
    private(set) var overhangWidth: CGFloat = 0
    private var width: CGFloat = 0
    private var screenWidth: CGFloat = 0
    private var freezeGeneration = 0
    private var liveResizing = false
    private var observers: [NSObjectProtocol] = []

    init() {
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: .pageWidthWillAnimate, object: nil, queue: nil) { [weak self] _ in
            MainActor.assumeIsolated { self?.freeze(for: 0.75) }
        })
        observers.append(nc.addObserver(forName: NSWindow.willStartLiveResizeNotification, object: nil, queue: nil) { [weak self] _ in
            MainActor.assumeIsolated { self?.liveResizing = true; self?.freeze(for: nil) }
        })
        observers.append(nc.addObserver(forName: NSWindow.didEndLiveResizeNotification, object: nil, queue: nil) { [weak self] _ in
            MainActor.assumeIsolated { self?.liveResizing = false; self?.freeze(for: 0.05) }
        })
    }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    /// Keeps out-of-sight rows at the current width until `seconds` after the last
    /// call (nil: until told otherwise), then lets everything take the new width once.
    private func freeze(for seconds: Double?) {
        guard width > 0 else { return }
        if !frozen {
            overhangWidth = max(screenWidth, width) + 60
            // Rows out of sight are swapped for exact-height space for the duration
            // (rebuilt one at a time afterwards), so fewer views move with the page.
            let near = Set(range(from: top - viewport * 0.2, to: top + viewport * 1.2).map { rows[$0].id })
            let release = built.filter { !near.contains($0) && heights[$0] != nil }
            if !release.isEmpty { built.subtract(release) }
            frozen = true
        }
        freezeGeneration += 1
        guard let seconds else { return }
        let gen = freezeGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self, gen == self.freezeGeneration, !self.liveResizing else { return }
            self.frozen = false
            self.scheduleIdle()
        }
    }

    func widthChanged(_ w: CGFloat, screen: CGFloat) { width = w; screenWidth = screen }

    private var rows: [Meta] = []
    private var offsets: [CGFloat] = []
    private var top: CGFloat = 0
    private var viewport: CGFloat = 900
    private var idleScheduled = false
    private var nearEndFiredForCount = -1
    private var lastPull: CGFloat = 0

    func reset() {
        built = []; heights = [:]; nearEndFiredForCount = -1
    }

    func setRows(_ new: [Meta]) {
        rows = new
        let ids = Set(new.map(\.id))
        if !built.isSubset(of: ids) { built.formIntersection(ids) }
        recompute()
        // The first screen is built straight away.
        ensureVisible()
        scheduleIdle()
    }

    func measured(_ h: [String: CGFloat]) {
        var changed = false
        for (id, v) in h where v > 0 && abs((heights[id] ?? -1) - v) > 0.5 {
            heights[id] = v; changed = true
        }
        if changed { recompute() }
    }

    private func height(_ i: Int) -> CGFloat { heights[rows[i].id] ?? rows[i].estimate }

    private func recompute() {
        var y: CGFloat = 0
        offsets = rows.indices.map { i in
            defer { y += height(i) + rows[i].spacing }
            return y
        }
    }

    // MARK: Scroll position (from AppKit, no SwiftUI work per frame)

    func scrolled(top newTop: CGFloat, viewport h: CGFloat) {
        top = newTop
        viewport = max(h, 300)
        let pulled = max(0, -newTop)
        if pulled != lastPull { lastPull = pulled; onPull(pulled) }
        ensureVisible()
        scheduleIdle()
    }

    private func range(from a: CGFloat, to b: CGFloat) -> [Int] {
        guard offsets.count == rows.count else { return [] }
        return rows.indices.filter { offsets[$0] + height($0) >= a && offsets[$0] <= b }
    }

    /// What's on screen (plus a little below) must exist right now.
    private func ensureVisible() {
        let need = range(from: top - viewport * 0.25, to: top + viewport * 1.5).map { rows[$0].id }
        let missing = need.filter { !built.contains($0) }
        if !missing.isEmpty { built.formUnion(missing) }
    }

    private func scheduleIdle() {
        guard !idleScheduled else { return }
        idleScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
            guard let self else { return }
            self.idleScheduled = false
            self.idleStep()
        }
    }

    /// One row per step, only while the page is at rest: up to four screens ahead and
    /// one behind. Then release rows that are far away.
    private func idleStep() {
        guard !rows.isEmpty else { return }
        if ScrollActivity.isScrolling || frozen { if !frozen { scheduleIdle() }; return }
        let ahead = range(from: top - viewport, to: top + viewport * 5)
        if let last = rows.indices.last, ahead.contains(last), nearEndFiredForCount != rows.count {
            nearEndFiredForCount = rows.count
            onNearEnd()
        }
        let below = ahead.filter { offsets[$0] >= top }
        let above = ahead.filter { offsets[$0] < top }.reversed()
        if let next = (below + above).first(where: { !built.contains(rows[$0].id) }) {
            built.insert(rows[next].id)
            scheduleIdle()
            return
        }
        let keep = Set(range(from: top - viewport * 3, to: top + viewport * 6).map { rows[$0].id })
        // Only release rows that have been measured, so their space stays exact.
        let release = built.filter { !keep.contains($0) && heights[$0] != nil }
        if !release.isEmpty { built.subtract(release) }
    }
}

/// Watches the enclosing NSScrollView's clip view and reports the scroll position.
private struct FeedScrollObserver: NSViewRepresentable {
    let model: FeedModel
    func makeNSView(context: Context) -> ObserverView { ObserverView(model: model) }
    func updateNSView(_ v: ObserverView, context: Context) {}

    final class ObserverView: NSView {
        private let model: FeedModel
        private var token: NSObjectProtocol?
        init(model: FeedModel) { self.model = model; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError() }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let t = token { NotificationCenter.default.removeObserver(t); token = nil }
            guard window != nil, let sv = enclosingScrollView else { return }
            sv.contentView.postsBoundsChangedNotifications = true
            token = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification,
                                                           object: sv.contentView, queue: .main) { [weak self, weak sv] _ in
                guard let self, let sv else { return }
                MainActor.assumeIsolated { self.report(sv) }
            }
            report(sv)
        }

        private func report(_ sv: NSScrollView) {
            guard let doc = sv.documentView else { return }
            let r = sv.documentVisibleRect
            let top = (doc.isFlipped ? r.minY : doc.bounds.height - r.maxY) + sv.contentInsets.top
            MainActor.assumeIsolated {
                model.widthChanged(r.width, screen: sv.window?.screen?.frame.width ?? r.width)
                model.scrolled(top: top, viewport: r.height)
            }
        }

        deinit { if let t = token { NotificationCenter.default.removeObserver(t) } }
    }
}

/// Reports a row's height to the model. On macOS 15+ this only fires when the
/// height actually changes (not on every layout pass, e.g. each frame of a width
/// animation); older systems fall back to a preference.
private struct FeedHeightReporter: ViewModifier {
    let id: String
    let model: FeedModel
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.onGeometryChange(for: CGFloat.self) { $0.size.height } action: { h in
                model.measured([id: h])
            }
        } else {
            content.background(GeometryReader { g in
                Color.clear.preference(key: FeedHeightsKey.self, value: [id: g.size.height])
            })
        }
    }
}
