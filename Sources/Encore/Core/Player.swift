import Foundation
import Combine
import SwiftUI

/// Fast-changing playback position, split out so only views that show time re-render.
@MainActor
final class PlaybackClock: ObservableObject {
    /// Coarse, published values (a few times a second) for labels.
    @Published var time: Double = 0
    @Published var duration: Double = 0

    /// Bumped whenever the timeline jumps (seek, track change, play/pause,
    /// rate change) so Core Animation timelines can re-sync.
    @Published private(set) var epoch = 0

    // Smooth, extrapolated position for animations (not published).
    private var anchorTime: Double = 0
    private var anchorDate = Date()
    private(set) var rate: Double = 0

    /// Current position predicted for `date`, accurate to a frame between polls.
    func now(_ date: Date = Date()) -> Double {
        guard rate > 0 else { return anchorTime }
        let t = anchorTime + date.timeIntervalSince(anchorDate) * rate
        return duration > 0 ? min(t, duration) : t
    }

    /// Feed a measured position from the player. Small drift is corrected
    /// gradually so animations never visibly jump.
    func sync(time measured: Double, playing: Bool, rate playRate: Double, at: Date = Date()) {
        let r = playing ? playRate : 0
        // Compare like with like: what we predicted for the instant it was measured.
        let predicted = now(at)
        let error = measured - predicted
        if r != rate || abs(error) > 0.3 {
            anchorTime = measured; anchorDate = at          // big jump (seek, stall): snap
            rate = r
            epoch &+= 1
        } else if abs(error) > 0.012 {
            // Small drift: slew a fraction of it so motion never visibly steps.
            anchorTime = now() + error * 0.2; anchorDate = Date()
        }
        rate = r
        if abs(time - measured) > 0.05 { time = measured }
    }

    func jump(to t: Double) {
        anchorTime = t
        anchorDate = Date()
        time = t
        epoch &+= 1
    }
}

/// Just "what's playing and is it playing", so long lists don't re-render on every player change.
@MainActor
final class NowState: ObservableObject {
    @Published var videoId: String?
    @Published var isPlaying = false
}

enum RepeatMode: String, Codable { case off, all, one
    var symbol: String { self == .one ? "repeat.1" : "repeat" }
    var next: RepeatMode { self == .off ? .all : (self == .all ? .one : .off) }
}

@MainActor
final class PlayerController: ObservableObject {
    static let shared = PlayerController()

    let bridge = WebBridge.shared
    let api = InnerTube.shared
    let clock = PlaybackClock()
    let now = NowState()

    @Published private(set) var queue: [Track] = []
    @Published private(set) var index: Int?
    @Published private(set) var isPlaying = false
    @Published private(set) var isBuffering = false
    @Published var shuffle = false
    @Published var repeatMode: RepeatMode = .off { didSet { save() } }
    @Published var autoplay: Bool = UserDefaults.standard.object(forKey: "autoplay") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoplay, forKey: "autoplay") }
    }
    @Published var volume: Double = UserDefaults.standard.object(forKey: "volume") as? Double ?? 80
    @Published var muted = false
    @Published private(set) var likeStatus: LikeStatus = .indifferent
    @Published var videoMode = false { didSet { bridge.setVideoMode(videoMode) } }
    @Published var playbackRate: Double = 1 { didSet { bridge.setRate(playbackRate) } }
    @Published private(set) var history: [Track] = []
    @Published private(set) var lyricsBrowseId: String?
    @Published private(set) var lastError: String?

    // Sleep timer
    @Published private(set) var sleepAt: Date?
    @Published var sleepAtEndOfTrack = false
    private var sleepTimer: Timer?

    private var radioContinuation: String?
    private var radioPlaylistId: String?
    private var unshuffled: [Track]?
    private var needsLoad = false
    private var resumeTime: Double = 0
    private var lastLoadAt = Date.distantPast
    private var reassertCount = 0
    private var bag = Set<AnyCancellable>()
    private var fetchingMore = false
    private var pendingFadeIn = false

    var current: Track? { index.flatMap { queue.indices.contains($0) ? queue[$0] : nil } }
    var upNext: ArraySlice<Track> {
        guard let i = index, i + 1 < queue.count else { return [] }
        return queue[(i + 1)...]
    }
    var hasNext: Bool { index.map { $0 + 1 < queue.count } ?? false || repeatMode == .all || autoplay }
    var hasPrevious: Bool { current != nil }

    init() {
        bridge.$snapshot
            .receive(on: RunLoop.main)
            .sink { [weak self] s in self?.apply(s) }
            .store(in: &bag)
        bridge.onEvent = { [weak self] type, info in self?.handle(event: type, info: info) }
        $volume.dropFirst().debounce(for: .milliseconds(80), scheduler: RunLoop.main)
            .sink { [weak self] v in
                UserDefaults.standard.set(v, forKey: "volume")
                self?.bridge.setVolume(self?.muted == true ? 0 : v)
            }.store(in: &bag)
        NotificationCenter.default.publisher(for: .ytBridgeReady)
            .sink { [weak self] _ in
                guard let self else { return }
                self.bridge.setVolume(self.muted ? 0 : self.volume)
                if self.videoMode { self.bridge.setVideoMode(true) }
            }.store(in: &bag)
        restore()
    }

    // MARK: - Bridge state

    private func apply(_ s: WebBridge.PlayerSnapshot) {
        guard s.ready else { return }
        // Ignore stale snapshots from a previous track right after a load.
        let fresh = s.videoId == current?.videoId || s.videoId == current?.counterpartVideoId
        let playing = s.state == 1
        if fresh {
            if s.duration > 0, abs(clock.duration - s.duration) > 0.5 { clock.duration = s.duration }
            clock.sync(time: s.time, playing: playing, rate: s.rate, at: s.measuredAt)
        }
        if playing != isPlaying && (fresh || !playing) { isPlaying = playing; now.isPlaying = playing }
        // SponsorBlock: jump over non-music / sponsor segments.
        if fresh, playing, let seg = SponsorBlock.shared.check(time: s.time, videoId: s.videoId) {
            seek(to: seg.end)
            AppModel.shared.flash(SponsorBlock.label(seg.category))
        }
        let buffering = s.state == 3 || (Date().timeIntervalSince(lastLoadAt) < 8 && !fresh)
        if buffering != isBuffering { isBuffering = buffering }
        if playing, sleepAtEndOfTrack == false, let at = sleepAt, Date() >= at { fireSleep() }
    }

    private func handle(event type: String, info: [String: Any]) {
        let vid = info["videoId"] as? String
        switch type {
        case "ended":
            guard vid == nil || vid == current?.videoId || vid == current?.counterpartVideoId else { return }
            trackEnded()
        case "videochange":
            // YouTube's own autoplay jumped to something we didn't ask for: put ours back.
            guard let vid, let cur = current, vid != cur.videoId, vid != cur.counterpartVideoId,
                  !needsLoad, Date().timeIntervalSince(lastLoadAt) > 1.5, reassertCount < 3 else { return }
            reassertCount += 1
            loadCurrent(autoplay: true)
        case "error":
            lastError = "This track couldn't be played. Skipping…"
            Task { try? await Task.sleep(nanoseconds: 1_500_000_000); self.next() }
        case "crashed":
            needsLoad = true
            resumeTime = clock.time
        default: break
        }
    }

    // MARK: - Starting playback

    func play(tracks: [Track], startAt: Int = 0, shuffle: Bool = false, radioFrom playlistId: String? = nil) {
        guard !tracks.isEmpty else { return }
        var list = tracks.map { var t = $0; t.uid = UUID(); return t }
        var start = min(max(startAt, 0), list.count - 1)
        unshuffled = nil
        if shuffle {
            unshuffled = list
            let first = list.remove(at: start)
            list.shuffle()
            list.insert(first, at: 0)
            start = 0
        }
        self.shuffle = shuffle
        queue = list
        index = start
        radioContinuation = nil
        radioPlaylistId = playlistId
        loadCurrent(autoplay: true)
    }

    /// Plays any item the way YouTube Music does: songs start a radio, collections play in order.
    func play(_ item: MediaItem, shuffle: Bool = false) {
        if let t = item.track {
            play(tracks: [t])
            Task { await extendWithRadio(videoId: t.videoId, playlistId: item.playlistId) }
            return
        }
        Task {
            if item.kind == .artist {
                if let page = try? await api.artist(item.browseId ?? item.id) {
                    if let pid = shuffle ? page.shufflePlaylistId : (page.radioPlaylistId ?? page.shufflePlaylistId) {
                        await playPlaylist(pid, shuffle: false)
                    } else if let songs = page.shelves.first(where: { $0.style == .list }) {
                        play(tracks: songs.items.compactMap(\.track), shuffle: shuffle)
                    }
                }
                return
            }
            if let bid = item.browseId, let page = try? await api.collection(bid), !page.tracks.isEmpty {
                play(tracks: page.tracks.compactMap(\.track), shuffle: shuffle)
                return
            }
            if let pid = item.playlistId { await playPlaylist(pid, shuffle: shuffle) }
        }
    }

    func playPlaylist(_ playlistId: String, shuffle: Bool = false, startVideoId: String? = nil) async {
        do {
            let q = try await api.watchQueue(videoId: startVideoId, playlistId: playlistId)
            guard !q.tracks.isEmpty else { return }
            play(tracks: q.tracks, shuffle: shuffle, radioFrom: q.playlistId)
            radioContinuation = q.continuation
        } catch { lastError = error.localizedDescription }
    }

    func startRadio(_ item: MediaItem) {
        Task {
            if let vid = item.videoId {
                await playPlaylist("RDAMVM" + vid, startVideoId: vid)
            } else if let r = item.radioPlaylistId {
                await playPlaylist(r)
            } else if let pid = item.playlistId {
                await playPlaylist("RDAMPL" + pid)
            } else if item.kind == .artist {
                play(item)
            }
        }
    }

    func playNext(_ tracks: [Track]) {
        let fresh = tracks.map { var t = $0; t.uid = UUID(); return t }
        guard let i = index else { play(tracks: fresh); return }
        queue.insert(contentsOf: fresh, at: i + 1)
        save()
    }

    func addToQueue(_ tracks: [Track]) {
        let fresh = tracks.map { var t = $0; t.uid = UUID(); return t }
        guard index != nil else { play(tracks: fresh); return }
        queue.append(contentsOf: fresh)
        save()
    }

    func playNext(_ item: MediaItem) { Task { playNext(await tracks(for: item)) } }
    func addToQueue(_ item: MediaItem) { Task { addToQueue(await tracks(for: item)) } }

    private func tracks(for item: MediaItem) async -> [Track] {
        if let t = item.track { return [t] }
        if let bid = item.browseId, item.kind.isCollection, let page = try? await api.collection(bid) {
            return page.tracks.compactMap(\.track)
        }
        if let pid = item.playlistId, let q = try? await api.watchQueue(videoId: nil, playlistId: pid) { return q.tracks }
        return []
    }

    private func extendWithRadio(videoId: String, playlistId: String?) async {
        guard let q = try? await api.watchQueue(videoId: videoId, playlistId: playlistId ?? ("RDAMVM" + videoId)) else { return }
        guard current?.videoId == videoId else { return }
        var extra = q.tracks
        if extra.first?.videoId == videoId {
            // Adopt richer metadata (album, counterpart) for the current track.
            if let i = index {
                let uid = queue[i].uid
                var t = extra.removeFirst(); t.uid = uid
                if t.thumbnail == nil { t.thumbnail = queue[i].thumbnail }
                queue[i] = t
            }
        }
        queue.append(contentsOf: extra.filter { $0.videoId != videoId })
        radioContinuation = q.continuation
        radioPlaylistId = q.playlistId
        save()
    }

    // MARK: - Transport

    func togglePlayPause() { isPlaying ? pause() : resume() }

    func resume() {
        guard current != nil else { return }
        if needsLoad || bridge.snapshot.videoId != current?.videoId && bridge.snapshot.videoId != current?.counterpartVideoId {
            loadCurrent(autoplay: true, start: resumeTime)
        } else {
            bridge.play()
        }
        isPlaying = true
        now.isPlaying = true
    }

    func pause() {
        bridge.pause(); isPlaying = false; now.isPlaying = false
        clock.sync(time: clock.now(), playing: false, rate: 1)
        save()
    }

    func next() {
        guard let i = index else { return }
        if i + 1 < queue.count {
            addToHistory()
            index = i + 1
            loadCurrent(autoplay: true)
            if queue.count - (i + 1) < 3 { Task { await fetchMoreIfNeeded() } }
        } else if repeatMode == .all, !queue.isEmpty {
            addToHistory()
            index = 0
            loadCurrent(autoplay: true)
        } else if autoplay {
            Task {
                await fetchMoreIfNeeded()
                if let i2 = index, i2 + 1 < queue.count { next() }
            }
        }
    }

    func previous() {
        if clock.time > 3 || (index ?? 0) == 0 { seek(to: 0); return }
        index = (index ?? 1) - 1
        loadCurrent(autoplay: true)
    }

    func seek(to t: Double) {
        clock.jump(to: t)
        bridge.seek(to: t)
    }

    func skip(by seconds: Double) { seek(to: max(0, min(clock.duration, clock.time + seconds))) }

    func jump(to track: Track) {
        guard let i = queue.firstIndex(of: track) else { return }
        addToHistory()
        index = i
        loadCurrent(autoplay: true)
    }

    func remove(_ track: Track) {
        guard let i = queue.firstIndex(of: track), i != index else { return }
        queue.remove(at: i)
        if let cur = index, i < cur { index = cur - 1 }
        save()
    }

    func moveUpNext(from: IndexSet, to: Int) {
        guard let i = index else { return }
        var upcoming = Array(queue[(i + 1)...])
        upcoming.move(fromOffsets: from, toOffset: to)
        queue = Array(queue[...i]) + upcoming
        save()
    }

    func clearUpNext() {
        guard let i = index else { return }
        queue = Array(queue[...i])
        radioContinuation = nil
        save()
    }

    func toggleShuffle() {
        guard let i = index else { shuffle.toggle(); return }
        if !shuffle {
            unshuffled = queue
            var rest = Array(queue[(i + 1)...]); rest.shuffle()
            queue = Array(queue[...i]) + rest
            shuffle = true
        } else {
            if let orig = unshuffled, let cur = current, let pos = orig.firstIndex(of: cur) {
                let played = Set(queue[...i].map(\.uid))
                queue = Array(queue[...i]) + orig[(pos + 1)...].filter { !played.contains($0.uid) }
            }
            unshuffled = nil
            shuffle = false
        }
        save()
    }

    func toggleMute() {
        muted.toggle()
        bridge.setVolume(muted ? 0 : volume)
    }

    func setVideoMode(_ on: Bool) {
        videoMode = on
        guard let cur = current, let other = cur.counterpartVideoId else { return }
        // Switch between the audio-only song and its music video at the same position.
        let wantVideo = on
        if cur.isVideo != wantVideo, let i = index {
            var t = cur
            t.counterpartVideoId = cur.videoId
            t.videoId = other
            t.isVideo = wantVideo
            let resumeAt = clock.now(), wasPlaying = isPlaying
            Task {
                // Quick fade-out, switch stream, fade back in: a soft crossfade instead of a cut.
                if wasPlaying { await bridge.fade(to: 0, ms: 160); try? await Task.sleep(nanoseconds: 170_000_000) }
                queue[i] = t
                pendingFadeIn = wasPlaying
                loadCurrent(autoplay: wasPlaying, start: resumeAt)
            }
        }
    }

    private func trackEnded() {
        if sleepAtEndOfTrack { sleepAtEndOfTrack = false; fireSleep(); return }
        if repeatMode == .one { seek(to: 0); bridge.play(); return }
        next()
    }

    private func fetchMoreIfNeeded() async {
        guard autoplay, !fetchingMore else { return }
        fetchingMore = true
        defer { fetchingMore = false }
        let existing = Set(queue.map(\.videoId))
        do {
            var q: WatchQueue
            if let token = radioContinuation {
                q = try await api.watchContinuation(token, playlistId: radioPlaylistId)
            } else if let last = queue.last {
                q = try await api.watchQueue(videoId: last.videoId, playlistId: "RDAMVM" + last.videoId)
            } else { return }
            radioContinuation = q.continuation
            if q.playlistId != nil { radioPlaylistId = q.playlistId }
            let fresh = q.tracks.filter { !existing.contains($0.videoId) }
            queue.append(contentsOf: fresh)
            save()
        } catch {
            radioContinuation = nil
        }
    }

    private func addToHistory() {
        guard let c = current else { return }
        history.removeAll { $0.videoId == c.videoId }
        history.insert(c, at: 0)
        if history.count > 100 { history.removeLast(history.count - 100) }
    }

    // MARK: - Loading

    private func loadCurrent(autoplay: Bool, start: Double = 0) {
        guard let t = current else { return }
        needsLoad = false
        resumeTime = 0
        reassertCount = 0
        lastLoadAt = Date()
        clock.duration = t.duration ?? 0
        clock.jump(to: start)
        clock.sync(time: start, playing: false, rate: 1)
        now.videoId = t.videoId
        PlayStats.shared.record(t)
        isBuffering = true
        likeStatus = .indifferent
        lyricsBrowseId = nil
        lastError = nil
        let vid = t.videoId
        let fadeIn = pendingFadeIn
        pendingFadeIn = false
        Task {
            await bridge.load(videoId: vid, start: start)
            if !autoplay { bridge.pause() }
            // YouTube can reset the volume per video; always restore ours (faded in
            // after a Song↔Video switch so there's no jump).
            let target = muted ? 0 : volume
            if fadeIn {
                bridge.setVolume(0)
                try? await Task.sleep(nanoseconds: 120_000_000)
                await bridge.fade(to: target, ms: 380)
            } else {
                bridge.setVolume(target)
            }
            if videoMode { bridge.setVideoMode(true); bridge.requestHD() }
            await loadDetails(for: vid)
        }
        SponsorBlock.shared.load(videoId: vid)
        NotificationCenter.default.post(name: .trackChanged, object: nil)
        save()
    }

    /// Like status, lyrics id and song/video counterpart for the current track.
    private func loadDetails(for vid: String) async {
        guard let q = try? await api.watchQueue(videoId: vid, playlistId: nil) else { return }
        guard current?.videoId == vid, let i = index else { return }
        lyricsBrowseId = q.lyricsBrowseId
        if let first = q.tracks.first, first.videoId == vid {
            if queue[i].counterpartVideoId == nil { queue[i].counterpartVideoId = first.counterpartVideoId }
            if queue[i].album == nil { queue[i].album = first.album }
            if queue[i].duration == nil { queue[i].duration = first.duration }
        }
        if let s = await api.likeStatus(videoId: vid), current?.videoId == vid {
            likeStatus = s
            LikeStore.shared.set(vid, s)
            // Auto-skip songs you've disliked (but not one you picked deliberately to play alone).
            if s == .dislike, Prefs.shared.autoSkipDisliked, queue.count > 1 {
                AppModel.shared.flash("Skipped a song you disliked")
                next()
            }
        }
    }

    // MARK: - Likes

    func setLike(_ status: LikeStatus, for videoId: String? = nil) {
        guard let vid = videoId ?? current?.videoId else { return }
        if vid == current?.videoId { likeStatus = status }
        LikeStore.shared.set(vid, status)
        Task {
            do { try await api.rate(videoId: vid, status) }
            catch { lastError = error.localizedDescription }
        }
    }
    func toggleLike() { setLike(likeStatus == .like ? .indifferent : .like) }
    func toggleDislike() {
        let wasDislike = likeStatus == .dislike
        setLike(wasDislike ? .indifferent : .dislike)
        if !wasDislike { next() }
    }

    // MARK: - Sleep timer

    func setSleepTimer(minutes: Int?) {
        sleepTimer?.invalidate()
        sleepAtEndOfTrack = false
        guard let minutes else { sleepAt = nil; return }
        let at = Date().addingTimeInterval(TimeInterval(minutes * 60))
        sleepAt = at
        sleepTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(minutes * 60), repeats: false) { [weak self] _ in
            Task { @MainActor in self?.fireSleep() }
        }
    }

    func sleepAfterCurrentTrack() {
        sleepTimer?.invalidate()
        sleepAt = nil
        sleepAtEndOfTrack = true
    }

    private func fireSleep() {
        sleepTimer?.invalidate()
        sleepAt = nil
        sleepAtEndOfTrack = false
        pause()
    }

    // MARK: - Persistence (resume where you left off)

    private struct Saved: Codable {
        var queue: [Track]; var index: Int?; var time: Double; var repeatMode: RepeatMode
    }

    func save() {
        let s = Saved(queue: Array(queue.prefix(500)), index: index, time: clock.time, repeatMode: repeatMode)
        if let d = try? JSONEncoder().encode(s) { UserDefaults.standard.set(d, forKey: "savedQueue") }
    }

    private func restore() {
        guard Prefs.shared.rememberQueue, let d = UserDefaults.standard.data(forKey: "savedQueue"),
              let s = try? JSONDecoder().decode(Saved.self, from: d), !s.queue.isEmpty else { return }
        queue = s.queue
        index = s.index.flatMap { s.queue.indices.contains($0) ? $0 : nil } ?? 0
        repeatMode = s.repeatMode
        resumeTime = s.time
        clock.duration = current?.duration ?? 0
        clock.jump(to: s.time)
        now.videoId = current?.videoId
        needsLoad = true
    }
}

extension Notification.Name {
    static let trackChanged = Notification.Name("trackChanged")
}
