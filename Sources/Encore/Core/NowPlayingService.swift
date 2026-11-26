import Foundation
import MediaPlayer
import AppKit
import Combine
import UserNotifications

/// Publishes the current track to Control Center / the Now Playing widget and
/// routes media keys, AirPods and Touch Bar controls back to the player.
@MainActor
final class NowPlayingService {
    static let shared = NowPlayingService()
    private let player = PlayerController.shared
    private var bag = Set<AnyCancellable>()
    private var lastNotified: String?

    private var sentMetaFor: String?

    func start() {
        player.objectWillChange
            .debounce(for: .milliseconds(150), scheduler: RunLoop.main)
            .sink { [weak self] in self?.update() }
            .store(in: &bag)
        player.clock.$duration.removeDuplicates()
            .sink { [weak self] _ in self?.update() }.store(in: &bag)
        // Re-sync elapsed time periodically and after seeks.
        player.clock.$time
            .scan((0.0, 0.0)) { ($0.1, $1) }
            .filter { abs($0.1 - $0.0) > 1.5 }
            .sink { [weak self] _ in self?.update() }
            .store(in: &bag)
        // The page reloads its session state when it (re)loads; after a crossfade the
        // other page is the player and needs the details too (even on repeat one,
        // where the song itself hasn't changed).
        NotificationCenter.default.publisher(for: .ytBridgeReady)
            .merge(with: NotificationCenter.default.publisher(for: .playerPageSwapped))
            .sink { [weak self] _ in self?.sentMetaFor = nil; self?.update() }
            .store(in: &bag)

        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { _, _ in }
    }

    /// Buttons from Control Center, the Now Playing widget, media keys and AirPods.
    func handleRemote(action: String, seekTime: Double?) {
        switch action {
        case "play": player.resume()
        case "pause", "stop": player.pause()
        case "nexttrack": player.next()
        case "previoustrack": player.previous()
        case "seekto": if let t = seekTime { player.seek(to: t) }
        default: break
        }
    }

    /// Publishes the current track through the page's Media Session, which WebKit
    /// shows as the app's single Now Playing entry (see WebBridge.injectedJS).
    private func update() {
        // Clear anything a previous version published natively.
        if MPNowPlayingInfoCenter.default().nowPlayingInfo != nil { MPNowPlayingInfoCenter.default().nowPlayingInfo = nil }
        var payload: [String: Any] = [:]
        if let t = player.current {
            if sentMetaFor != t.videoId {
                sentMetaFor = t.videoId
                var meta: [String: Any] = ["title": t.title, "artist": t.artistLine]
                // Control Center shows "artist – album"; never leave that slot empty.
                meta["album"] = t.album?.name ?? AppInfo.name
                if let art = t.largeArtwork?.absoluteString { meta["art"] = art }
                payload["meta"] = meta
                notify(t)
            }
            payload["state"] = player.isPlaying ? "playing" : "paused"
            payload["pos"] = ["duration": player.clock.duration, "position": player.clock.time,
                              "rate": player.playbackRate]
        } else {
            if sentMetaFor != nil { sentMetaFor = nil; payload["meta"] = NSNull() }
            payload["state"] = "none"
        }
        guard let data = try? JSONSerialization.data(withJSONObject: payload), let json = String(data: data, encoding: .utf8) else { return }
        Task { await WebBridge.shared.js("window.__ytmacNP && window.__ytmacNP(\(json))") }
    }

    private func notify(_ t: Track) {
        guard UserDefaults.standard.bool(forKey: "notifyOnTrackChange"), lastNotified != t.videoId,
              !NSApp.isActive else { return }
        lastNotified = t.videoId
        let c = UNMutableNotificationContent()
        c.title = t.title
        c.body = t.artistLine
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "track", content: c, trigger: nil))
    }
}
