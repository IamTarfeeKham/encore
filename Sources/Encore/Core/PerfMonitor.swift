import AppKit
import SwiftUI
import QuartzCore

/// Optional frame-pacing logger (enable with `defaults write local.ytmusicmac perfLog -bool YES`).
/// While scrolling, records how many frames missed their deadline and writes a
/// summary to the app's tmp folder (perf.log). Off by default; costs nothing then.
@MainActor
final class PerfMonitor: NSObject {
    static let shared = PerfMonitor()
    private var link: CADisplayLink?
    private var last: CFTimeInterval = 0
    private var frames = 0, hitches = 0
    private var worst: CFTimeInterval = 0
    private var windowStart = Date()
    private var expected: CFTimeInterval = 1.0 / 60
    private let logAll = UserDefaults.standard.bool(forKey: "perfLogAll")
    /// Frames during a measured animation (the 0.7 s after a test toggle).
    private var animStart: CFTimeInterval = 0
    private var animFrames = 0, animHitches = 0
    private var animWorst: CFTimeInterval = 0

    func start(in view: NSView) {
        guard UserDefaults.standard.bool(forKey: "perfLog"), link == nil else { return }
        let l = view.displayLink(target: self, selector: #selector(tick(_:)))
        l.add(to: .main, forMode: .common)
        link = l
        log("started")
        // Measurement hook (only while perfLog is on): a script can toggle the
        // sidebar without keyboard focus or accessibility queries skewing results.
        DistributedNotificationCenter.default().addObserver(forName: .init("local.ytmusicmac.perf.toggleSidebar"),
                                                            object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                self.log("toggle sidebar")
                self.animStart = CACurrentMediaTime(); self.animFrames = 0; self.animHitches = 0; self.animWorst = 0
                withAnimation(Motion.panel) { AppModel.shared.sidebarVisible.toggle() }
            }
        }
        DistributedNotificationCenter.default().addObserver(forName: .init("local.ytmusicmac.perf.scrollTest"),
                                                            object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { self.startScrollTest() }
        }
    }

    // MARK: Developer scroll test
    // Scrolls the main page smoothly (like a trackpad: 1600 pt/s down, then up) and
    // logs every frame of it, so scrolling can be measured without a person.
    private var testScroll: NSScrollView?
    private var testStart: CFTimeInterval = 0
    private var testOrigin: CGFloat = 0

    private func startScrollTest() {
        guard let content = NSApp.windows.first(where: { $0.title != "Mini Player" && $0.isVisible && $0.frame.width > 600 })?.contentView
        else { return }
        // The tallest vertical scroll view is the page.
        var best: NSScrollView?
        func walk(_ v: NSView) {
            if let s = v as? NSScrollView, s.hasVerticalScroller || (s.documentView?.frame.height ?? 0) > s.frame.height + 200,
               (s.documentView?.frame.height ?? 0) > (best?.documentView?.frame.height ?? 0) { best = s }
            v.subviews.forEach(walk)
        }
        walk(content)
        guard let s = best else { log("scroll test: no scroll view"); return }
        testScroll = s
        testOrigin = s.contentView.bounds.origin.y
        testStart = CACurrentMediaTime()
        frames = 0; hitches = 0; worst = 0; windowStart = Date()
        ScrollActivity.setTestScrolling(true)
        log("scroll test: start")
    }

    private func stepScrollTest(_ now: CFTimeInterval) {
        guard let s = testScroll else { return }
        let t = now - testStart, speed: CGFloat = 1600, leg: Double = 3
        let maxY = max(0, (s.documentView?.frame.height ?? 0) - s.contentView.bounds.height)
        let y: CGFloat = t < leg ? testOrigin + speed * CGFloat(t) : testOrigin + speed * CGFloat(max(0, 2 * leg - t))
        s.contentView.scroll(to: NSPoint(x: 0, y: min(max(0, y), maxY)))
        s.reflectScrolledClipView(s.contentView)
        if t >= 2 * leg {
            testScroll = nil
            ScrollActivity.setTestScrolling(false)
            log(String(format: "scroll test: %d frames, %d hitches, worst %.1f ms", frames, hitches, worst * 1000))
            frames = 0; hitches = 0; worst = 0; windowStart = Date()
        }
    }

    @objc private func tick(_ l: CADisplayLink) {
        if testScroll != nil { stepScrollTest(l.targetTimestamp) }
        expected = max(l.targetTimestamp - l.timestamp, 1.0 / 240)
        let now = l.timestamp
        defer { last = now }
        // perfLogAll: measure every frame (e.g. panel animations), not just scrolling.
        guard last > 0, ScrollActivity.isScrolling || logAll else { return }
        let dt = now - last
        frames += 1
        if dt > expected * 1.6 { hitches += 1 }
        worst = max(worst, dt)
        if animStart > 0 {
            if now - animStart < 0.7 {
                animFrames += 1
                if dt > expected * 1.6 { animHitches += 1 }
                animWorst = max(animWorst, dt)
            } else {
                log(String(format: "anim: %d frames, %d hitches, worst %.1f ms", animFrames, animHitches, animWorst * 1000))
                animStart = 0
            }
        }
        if testScroll == nil, Date().timeIntervalSince(windowStart) > 2 {
            log(String(format: "frames: %d frames, %d hitches, worst %.1f ms, display %.0f Hz",
                       frames, hitches, worst * 1000, 1 / expected))
            frames = 0; hitches = 0; worst = 0; windowStart = Date()
        }
    }

    /// Developer notes (crossfade decisions etc.), written only while perfLog is on.
    nonisolated static func note(_ s: String) {
        guard UserDefaults.standard.bool(forKey: "perfLog") else { return }
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("perf.log")
        let line = "\(Date()) \(s)\n"
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
        else { try? line.write(to: url, atomically: true, encoding: .utf8) }
    }

    private func log(_ s: String) {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("perf.log")
        let line = "\(Date()) \(s)\n"
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
        else { try? line.write(to: url, atomically: true, encoding: .utf8) }
    }
}
