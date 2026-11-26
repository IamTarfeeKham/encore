import AppKit
import Combine
import Foundation
import JavaScriptCore
import UserNotifications

/// Your own extensions: small JavaScript files that react to what's playing and
/// control the player. Each runs in its own JavaScriptCore engine inside the app
/// (no access to your files or the YouTube page), with only this API:
///
///     encore.on("track", t => {})     // a new song: {title, artist, album, videoId, duration}
///     encore.on("play" | "pause", () => {})
///     encore.nowPlaying()             // the current song, or null
///     encore.player.play() / pause() / toggle() / next() / previous() / seek(seconds) / setVolume(0…100) / like()
///     encore.toast("text")            // a short message in the app
///     encore.notify("title", "body")  // a macOS notification
///     encore.storage.get(key) / set(key, value)   // remembered between launches
///     await encore.fetch(url, {method, headers, body})  // → {status, text}
///     console.log(…), setTimeout(fn, ms)
///
/// Extensions are stored in UserDefaults; Settings › Extensions manages them.
@MainActor
final class UserExtensions: ObservableObject {
    static let shared = UserExtensions()

    struct Ext: Codable, Identifiable, Hashable {
        var id = UUID()
        var name: String
        var code: String
        var enabled = true
    }

    @Published var items: [Ext] { didSet { Persist.save(items, "userExtensions"); reload() } }
    /// Recent console output and errors, per extension.
    @Published private(set) var logs: [UUID: [String]] = [:]

    private var contexts: [UUID: JSContext] = [:]
    private var handlers: [UUID: [String: [JSValue]]] = [:]
    private var bag = Set<AnyCancellable>()
    private var lastTrack: String?

    init() { items = Persist.load("userExtensions", as: [Ext].self) ?? [] }

    func start() {
        reload()
        let player = PlayerController.shared
        player.$isPlaying.removeDuplicates().dropFirst()
            .sink { [weak self] on in self?.emit(on ? "play" : "pause", nil) }
            .store(in: &bag)
        player.objectWillChange
            .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
            .sink { [weak self] in
                guard let self, let t = player.current, t.videoId != self.lastTrack else { return }
                self.lastTrack = t.videoId
                self.emit("track", self.trackObject())
            }
            .store(in: &bag)
    }

    // MARK: Running

    private func reload() {
        contexts.removeAll(); handlers.removeAll()
        for e in items where e.enabled { load(e) }
    }

    private func load(_ e: Ext) {
        guard let ctx = JSContext() else { return }
        ctx.name = e.name
        let id = e.id
        ctx.exceptionHandler = { _, err in
            MainActor.assumeIsolated { UserExtensions.shared.log(id, "Error: \(err?.toString() ?? "unknown")") }
        }
        install(into: ctx, id: id)
        contexts[id] = ctx
        ctx.evaluateScript(e.code)
    }

    private func emit(_ event: String, _ payload: Any?) {
        for (id, byEvent) in handlers {
            for fn in byEvent[event] ?? [] {
                _ = payload.map { fn.call(withArguments: [$0]) } ?? fn.call(withArguments: [])
                if let ex = contexts[id]?.exception { log(id, "Error in \(event): \(ex)"); contexts[id]?.exception = nil }
            }
        }
    }

    private func trackObject() -> [String: Any]? {
        guard let t = PlayerController.shared.current else { return nil }
        return ["title": t.title, "artist": t.artistLine, "album": t.album?.name ?? "",
                "videoId": t.videoId, "duration": PlayerController.shared.clock.duration]
    }

    func log(_ id: UUID, _ line: String) {
        var l = logs[id] ?? []
        l.append(line)
        logs[id] = Array(l.suffix(60))
    }

    func clearLog(_ id: UUID) { logs[id] = [] }

    /// The `encore`, `console` and `setTimeout` objects for one extension.
    private func install(into ctx: JSContext, id: UUID) {
        let player = PlayerController.shared
        let encore = JSValue(newObjectIn: ctx)!

        let on: @convention(block) (String, JSValue) -> Void = { event, fn in
            MainActor.assumeIsolated { UserExtensions.shared.handlers[id, default: [:]][event, default: []].append(fn) }
        }
        encore.setObject(on, forKeyedSubscript: "on" as NSString)

        let nowPlaying: @convention(block) () -> Any? = {
            MainActor.assumeIsolated { UserExtensions.shared.trackObject() as Any? }
        }
        encore.setObject(nowPlaying, forKeyedSubscript: "nowPlaying" as NSString)

        let p = JSValue(newObjectIn: ctx)!
        func action(_ name: String, _ f: @escaping @MainActor () -> Void) {
            let block: @convention(block) () -> Void = { MainActor.assumeIsolated { f() } }
            p.setObject(block, forKeyedSubscript: name as NSString)
        }
        action("play") { player.resume() }
        action("pause") { player.pause() }
        action("toggle") { player.togglePlayPause() }
        action("next") { player.next() }
        action("previous") { player.previous() }
        action("like") { player.toggleLike() }
        let seek: @convention(block) (Double) -> Void = { t in MainActor.assumeIsolated { player.seek(to: t) } }
        p.setObject(seek, forKeyedSubscript: "seek" as NSString)
        let volume: @convention(block) (Double) -> Void = { v in MainActor.assumeIsolated { player.volume = min(max(v, 0), 100) } }
        p.setObject(volume, forKeyedSubscript: "setVolume" as NSString)
        encore.setObject(p, forKeyedSubscript: "player" as NSString)

        let toast: @convention(block) (String) -> Void = { s in MainActor.assumeIsolated { AppModel.shared.flash(s) } }
        encore.setObject(toast, forKeyedSubscript: "toast" as NSString)
        let notify: @convention(block) (String, String) -> Void = { title, body in
            let c = UNMutableNotificationContent()
            c.title = title; c.body = body
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
        }
        encore.setObject(notify, forKeyedSubscript: "notify" as NSString)

        let store = JSValue(newObjectIn: ctx)!
        let key = "userExtension.\(id.uuidString)."
        let get: @convention(block) (String) -> Any? = { k in UserDefaults.standard.object(forKey: key + k) }
        let set: @convention(block) (String, JSValue) -> Void = { k, v in
            if v.isUndefined || v.isNull { UserDefaults.standard.removeObject(forKey: key + k) }
            else if let o = v.toObject(), JSONSerialization.isValidJSONObject([o]) { UserDefaults.standard.set(o, forKey: key + k) }
        }
        store.setObject(get, forKeyedSubscript: "get" as NSString)
        store.setObject(set, forKeyedSubscript: "set" as NSString)
        encore.setObject(store, forKeyedSubscript: "storage" as NSString)

        let fetch: @convention(block) (String, JSValue) -> JSValue = { urlString, options in
            JSValue(newPromiseIn: ctx) { resolve, reject in
                guard let url = URL(string: urlString), ["https", "http"].contains(url.scheme ?? "") else {
                    reject?.call(withArguments: ["Only http(s) addresses can be fetched"]); return
                }
                var req = URLRequest(url: url)
                req.timeoutInterval = 30
                if options.isObject {
                    if let m = options.forProperty("method"), m.isString { req.httpMethod = m.toString() }
                    if let h = options.forProperty("headers")?.toDictionary() as? [String: Any] {
                        for (k, v) in h { req.setValue("\(v)", forHTTPHeaderField: k) }
                    }
                    if let b = options.forProperty("body"), b.isString { req.httpBody = Data(b.toString().utf8) }
                }
                URLSession.shared.dataTask(with: req) { data, resp, err in
                    DispatchQueue.main.async {
                        if let err { reject?.call(withArguments: [err.localizedDescription]); return }
                        resolve?.call(withArguments: [["status": (resp as? HTTPURLResponse)?.statusCode ?? 0,
                                                       "text": String(decoding: data ?? Data(), as: UTF8.self)]])
                    }
                }.resume()
            }
        }
        encore.setObject(fetch, forKeyedSubscript: "fetch" as NSString)
        ctx.setObject(encore, forKeyedSubscript: "encore" as NSString)

        let consoleObj = JSValue(newObjectIn: ctx)!
        let logFn: @convention(block) () -> Void = {
            let parts = (JSContext.currentArguments() as? [JSValue] ?? []).map { $0.toString() ?? "" }
            MainActor.assumeIsolated { UserExtensions.shared.log(id, parts.joined(separator: " ")) }
        }
        consoleObj.setObject(logFn, forKeyedSubscript: "log" as NSString)
        consoleObj.setObject(logFn, forKeyedSubscript: "error" as NSString)
        ctx.setObject(consoleObj, forKeyedSubscript: "console" as NSString)

        let timeout: @convention(block) (JSValue, Double) -> Void = { fn, ms in
            DispatchQueue.main.asyncAfter(deadline: .now() + max(ms, 0) / 1000) {
                MainActor.assumeIsolated {
                    guard UserExtensions.shared.contexts[id] != nil else { return }   // removed or turned off
                    fn.call(withArguments: [])
                }
            }
        }
        ctx.setObject(timeout, forKeyedSubscript: "setTimeout" as NSString)
    }

    // MARK: Editing

    static let template = """
    // name: My Extension
    // Runs inside Encore. See the examples for what you can do.

    encore.on("track", song => {
      console.log("Now playing:", song.title, "by", song.artist)
    })
    """

    static let examples: [(String, String)] = [
        ("Skip very short songs", """
        // name: Skip very short songs
        // Skips anything under a minute (intros, skits, interludes).
        encore.on("track", song => {
          setTimeout(() => {
            const now = encore.nowPlaying()
            if (now && now.duration > 0 && now.duration < 60) {
              encore.toast("Skipped a short track")
              encore.player.next()
            }
          }, 1500)
        })
        """),
        ("Song-change banner", """
        // name: Song-change banner
        // Shows a macOS notification for every new song.
        encore.on("track", song => encore.notify(song.title, song.artist))
        """),
        ("Bedtime volume", """
        // name: Bedtime volume
        // After 11 pm, keeps the volume at 30 for each new song.
        encore.on("track", () => {
          const hour = new Date().getHours()
          if (hour >= 23 || hour < 6) encore.player.setVolume(30)
        })
        """),
        ("Count plays", """
        // name: Count plays
        // Keeps a running count of songs played (see the log).
        encore.on("track", song => {
          const n = (encore.storage.get("count") || 0) + 1
          encore.storage.set("count", n)
          console.log(n + " songs played; latest:", song.title)
        })
        """),
        ("Send to a webhook", """
        // name: Send to a webhook
        // Posts each song to a web address of yours (e.g. a scrobbler or home automation).
        const URL = "https://example.com/your-webhook"
        encore.on("track", async song => {
          const r = await encore.fetch(URL, {
            method: "POST",
            headers: {"Content-Type": "application/json"},
            body: JSON.stringify(song)
          })
          console.log("Webhook answered", r.status)
        })
        """),
    ]

    /// "// name: …" on the first lines, if present.
    static func name(in code: String) -> String? {
        for line in code.split(separator: "\n").prefix(5) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.lowercased().hasPrefix("// name:") { return String(t.dropFirst(8)).trimmingCharacters(in: .whitespaces) }
        }
        return nil
    }
}
