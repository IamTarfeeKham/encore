import AppKit
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

    func start(in view: NSView) {
        guard UserDefaults.standard.bool(forKey: "perfLog"), link == nil else { return }
        let l = view.displayLink(target: self, selector: #selector(tick(_:)))
        l.add(to: .main, forMode: .common)
        link = l
        log("started")
    }

    @objc private func tick(_ l: CADisplayLink) {
        expected = max(l.targetTimestamp - l.timestamp, 1.0 / 240)
        let now = l.timestamp
        defer { last = now }
        guard last > 0, ScrollActivity.isScrolling else { return }
        let dt = now - last
        frames += 1
        if dt > expected * 1.6 { hitches += 1 }
        worst = max(worst, dt)
        if Date().timeIntervalSince(windowStart) > 2 {
            log(String(format: "scroll: %d frames, %d hitches, worst %.1f ms, display %.0f Hz",
                       frames, hitches, worst * 1000, 1 / expected))
            frames = 0; hitches = 0; worst = 0; windowStart = Date()
        }
    }

    private func log(_ s: String) {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("perf.log")
        let line = "\(Date()) \(s)\n"
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
        else { try? line.write(to: url, atomically: true, encoding: .utf8) }
    }
}
