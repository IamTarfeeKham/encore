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
    private var artworkFor: String?
    private var artwork: MPMediaItemArtwork?
    private var lastNotified: String?

    func start() {
        let cc = MPRemoteCommandCenter.shared()
        cc.playCommand.addTarget { [weak self] _ in self?.player.resume(); return .success }
        cc.pauseCommand.addTarget { [weak self] _ in self?.player.pause(); return .success }
        cc.togglePlayPauseCommand.addTarget { [weak self] _ in self?.player.togglePlayPause(); return .success }
        cc.nextTrackCommand.addTarget { [weak self] _ in self?.player.next(); return .success }
        cc.previousTrackCommand.addTarget { [weak self] _ in self?.player.previous(); return .success }
        cc.changePlaybackPositionCommand.addTarget { [weak self] e in
            guard let e = e as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            self?.player.seek(to: e.positionTime); return .success
        }
        cc.likeCommand.addTarget { [weak self] _ in self?.player.setLike(.like); return .success }
        cc.dislikeCommand.addTarget { [weak self] _ in self?.player.toggleDislike(); return .success }
        cc.likeCommand.localizedTitle = "Like"
        cc.dislikeCommand.localizedTitle = "Dislike"

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

        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { _, _ in }
    }

    private func update() {
        let center = MPNowPlayingInfoCenter.default()
        guard let t = player.current else {
            center.nowPlayingInfo = nil
            center.playbackState = .stopped
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: t.title,
            MPMediaItemPropertyArtist: t.artistLine,
            MPMediaItemPropertyPlaybackDuration: player.clock.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: player.clock.time,
            MPNowPlayingInfoPropertyPlaybackRate: player.isPlaying ? player.playbackRate : 0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
        ]
        if let a = t.album?.name { info[MPMediaItemPropertyAlbumTitle] = a }
        if artworkFor == t.videoId, let artwork { info[MPMediaItemPropertyArtwork] = artwork }
        center.nowPlayingInfo = info
        center.playbackState = player.isPlaying ? .playing : .paused

        let cc = MPRemoteCommandCenter.shared()
        cc.likeCommand.isActive = player.likeStatus == .like
        cc.dislikeCommand.isActive = player.likeStatus == .dislike

        if artworkFor != t.videoId, let url = t.largeArtwork {
            artworkFor = t.videoId
            artwork = nil
            Task {
                guard let img = await ImageLoader.shared.image(for: url) else { return }
                let art = MPMediaItemArtwork(boundsSize: img.size) { _ in img }
                if self.artworkFor == t.videoId { self.artwork = art; self.update() }
            }
            notify(t)
        }
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
