import AppKit
import Combine
import Foundation
import SwiftUI

/// In-app updates from GitHub Releases. Checks quietly (at launch, then every few
/// hours), and installs either when you say so (Check for Updates…) or by itself,
/// following Settings › General › Updates: right away, after a day or a week, or
/// once you're two or three versions behind. An automatic install waits until
/// music isn't playing, or happens when you quit.
///
/// Installing hands over to the bundled Encore Updater helper (the app is
/// sandboxed and can't replace itself): it downloads the zip, checks it was signed
/// with the release key, swaps the old copy (to the Trash) for the new one and
/// reopens it.
@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()
    static let repo = "IamTarfeeKham/encore"

    struct Release: Equatable {
        let version: String
        let notes: String
        let published: Date
        let zip: URL
        let signature: URL
        let page: URL
    }

    enum Status: Equatable {
        case idle, checking, upToDate, available, installing
        case failed(String)
    }

    @Published private(set) var status: Status = .idle
    @Published private(set) var latest: Release?
    /// How many releases are newer than this copy.
    @Published private(set) var behind = 0
    @Published private(set) var lastChecked: Date?
    /// While installing: what's happening, and download progress (0…1).
    @Published private(set) var phase = ""
    @Published private(set) var progress: Double = 0
    @Published private(set) var bytesText = ""
    private var progressPanel: NSPanel?

    private var timer: Timer?
    private var waitForPause: AnyCancellable?
    /// An automatic install that's waiting (for music to stop, or for you to quit).
    private(set) var pendingAutomatic = false

    static var current: String { AppInfo.version }

    var helperURL: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/Encore Updater.app")
    }

    func start() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 25) { [weak self] in self?.automaticCheck() }
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { _ in
            MainActor.assumeIsolated { Updater.shared.automaticCheck() }
        }
    }

    private func automaticCheck() {
        guard Prefs.shared.autoCheckUpdates else { return }
        Task { await check(userInitiated: false) }
    }

    // MARK: Checking

    func check(userInitiated: Bool) async {
        guard status != .checking, status != .installing else { return }
        status = .checking
        do {
            let releases = try await fetchReleases()
            lastChecked = Date()
            let newer = releases.filter { Self.isNewer($0.version, than: Self.current) }
            behind = newer.count
            latest = newer.max { Self.isNewer($1.version, than: $0.version) }
            status = latest == nil ? .upToDate : .available
        } catch {
            status = .failed("Couldn't reach GitHub. \(error.localizedDescription)")
        }
        if userInitiated {
            presentResult()
        } else if latest != nil, automaticInstallDue {
            scheduleAutomaticInstall()
        }
    }

    /// Reads the repository's releases feed (not the GitHub API, which allows only
    /// 60 anonymous requests an hour per network and runs out on shared networks).
    /// Downloads follow GitHub's fixed pattern for release files.
    private func fetchReleases() async throws -> [Release] {
        var req = URLRequest(url: URL(string: "https://github.com/\(Self.repo)/releases.atom")!)
        req.setValue("Encore-Updater", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 20
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw APIError.message("GitHub didn't answer.") }
        let feed = String(decoding: data, as: UTF8.self)
        let iso = ISO8601DateFormatter()
        func field(_ tag: String, in entry: String) -> String? {
            guard let a = entry.range(of: "<\(tag)"), let open = entry[a.upperBound...].range(of: ">"),
                  let close = entry[open.upperBound...].range(of: "</\(tag)>") else { return nil }
            return String(entry[open.upperBound..<close.lowerBound])
        }
        return feed.components(separatedBy: "<entry>").dropFirst().compactMap { entry in
            guard let id = field("id", in: entry), let tag = id.split(separator: "/").last.map(String.init) else { return nil }
            let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            guard version.first?.isNumber == true else { return nil }
            let base = "https://github.com/\(Self.repo)/releases/download/\(tag)/Encore-\(version)-macOS-arm64.zip"
            return Release(version: version,
                           notes: Self.plainText(field("content", in: entry) ?? ""),
                           published: field("updated", in: entry).flatMap(iso.date(from:)) ?? Date(),
                           // ".sig" next to the zip (1.0.18's updater looked for ".zip.sig" and
                           // can't hand over; without that file it stops safely instead).
                           zip: URL(string: base)!, signature: URL(string: base.replacingOccurrences(of: ".zip", with: ".sig"))!,
                           page: URL(string: "https://github.com/\(Self.repo)/releases/tag/\(tag)")!)
        }
    }

    /// The feed's notes are escaped HTML: turn them into readable text.
    private static func plainText(_ html: String) -> String {
        var s = html
        for (a, b) in [("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&amp;", "&")] { s = s.replacingOccurrences(of: a, with: b) }
        s = s.replacingOccurrences(of: "<li>", with: "• ")
        s = s.replacingOccurrences(of: "</h2>", with: "\n").replacingOccurrences(of: "</li>", with: "\n")
        s = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        // The checksum is for GitHub downloads; not useful in the prompt.
        s = s.components(separatedBy: "\n").filter { !$0.hasPrefix("SHA-256") }.joined(separator: "\n")
        return s.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        return false
    }

    // MARK: Automatic installs

    var automaticInstallDue: Bool {
        let prefs = Prefs.shared
        guard prefs.autoInstallUpdates, let latest else { return false }
        let age = Date().timeIntervalSince(latest.published)
        switch prefs.autoInstallWhen {
        case .rightAway: return true
        case .afterDay: return age >= 86_400
        case .afterWeek: return age >= 7 * 86_400
        case .twoVersions: return behind >= 2
        case .threeVersions: return behind >= 3
        }
    }

    /// Installs when music isn't playing (now, or after a minute's pause), or on quit.
    private func scheduleAutomaticInstall() {
        pendingAutomatic = true
        let player = PlayerController.shared
        if !player.isPlaying { install(relaunch: true); return }
        waitForPause = player.$isPlaying
            .removeDuplicates()
            .debounce(for: .seconds(60), scheduler: RunLoop.main)
            .sink { playing in
                guard !playing else { return }
                Updater.shared.waitForPause = nil
                Updater.shared.install(relaunch: true)
            }
    }

    /// From the quit path: if an automatic install is waiting, hand it to the helper
    /// (without reopening the app afterwards).
    func installOnQuitIfPending() {
        quitWaiting = true
        guard pendingAutomatic, latest != nil, status != .installing else { endQuitWait(); return }
        install(relaunch: false)
    }

    /// The app's quit is on hold (`.terminateLater`) until the helper has started.
    private var quitWaiting = false

    /// Lets a held quit go ahead (once the helper has started, or the install stopped).
    private func endQuitWait() {
        guard quitWaiting else { return }
        quitWaiting = false
        NSApp.reply(toApplicationShouldTerminate: true)
    }

    // MARK: Installing

    func install(relaunch: Bool) {
        guard let release = latest, status != .installing else { return }
        // The helper only finds requests from (and only installs over) the standard bundle ID,
        // so a build with its own BUNDLE_ID updates from the release page instead.
        guard Bundle.main.bundleIdentifier == "local.ytmusicmac",
              FileManager.default.fileExists(atPath: helperURL.path) else {
            if !quitWaiting { NSWorkspace.shared.open(release.page) }   // e.g. a development build
            endQuitWait()
            return
        }
        status = .installing
        showProgress(release.version)
        Task {
            do {
                // Download here (with progress shown), then hand the file to the helper.
                phase = "Downloading \(AppInfo.name) \(release.version)…"
                var zipReq = URLRequest(url: release.zip)
                zipReq.setValue("Encore-Updater", forHTTPHeaderField: "User-Agent")
                let data = try await UpdateDownload.fetch(zipReq) { done, total in
                    Task { @MainActor in
                        let u = Updater.shared
                        u.progress = total > 0 ? Double(done) / Double(total) : 0
                        u.bytesText = String(format: "%.1f of %.1f MB", Double(done) / 1_048_576, Double(max(total, done)) / 1_048_576)
                    }
                }
                progress = 1
                phase = "Installing… \(AppInfo.name) will reopen in a moment."
                bytesText = ""
                let cachesDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                try FileManager.default.createDirectory(at: cachesDir, withIntermediateDirectories: true)
                let zipFile = cachesDir.appendingPathComponent("EncoreUpdate.zip")
                try data.write(to: zipFile, options: .atomic)
                var req = URLRequest(url: release.signature)
                req.setValue("Encore-Updater", forHTTPHeaderField: "User-Agent")
                let (sigData, _) = try await URLSession.shared.data(for: req)
                let sig = String(decoding: sigData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                guard Data(base64Encoded: sig) != nil else { throw APIError.message("The release has no valid signature.") }
                // A sandboxed app can't pass launch arguments, so the request goes in a
                // small file in this app's own data folder, which the helper reads.
                let request: [String: Any] = ["url": release.zip.absoluteString, "zipPath": zipFile.path, "signature": sig,
                                              "app": Bundle.main.bundleURL.path,
                                              "pid": Int(ProcessInfo.processInfo.processIdentifier),
                                              "relaunch": relaunch]
                let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                try FileManager.default.createDirectory(at: caches, withIntermediateDirectories: true)
                try JSONSerialization.data(withJSONObject: request).write(to: caches.appendingPathComponent("EncoreUpdate.json"), options: .atomic)
                let config = NSWorkspace.OpenConfiguration()
                config.activates = false
                config.createsNewApplicationInstance = true
                // Start the installer without waiting: it's a background tool that never
                // reports "finished launching", so waiting held the app open ~25 s.
                NSWorkspace.shared.openApplication(at: helperURL, configuration: config) { _, error in
                    if let error { Task { @MainActor in Updater.shared.status = .failed(error.localizedDescription) } }
                }
                try? await Task.sleep(nanoseconds: 400_000_000)
                PlayerController.shared.save()
                if relaunch {
                    try? await Task.sleep(nanoseconds: 700_000_000)   // let "Installing…" be seen
                    NSApp.terminate(nil)
                } else { hideProgress(); endQuitWait() }
            } catch {
                hideProgress()
                status = .failed("The update couldn't finish. \(error.localizedDescription)")
                if quitWaiting { endQuitWait(); return }   // quitting: no alert, just let the app close
                let alert = NSAlert()
                alert.messageText = "The update couldn't finish"
                alert.informativeText = error.localizedDescription + "\nNothing was changed. You can try again from Check for Updates."
                alert.runModal()
            }
        }
    }

    // MARK: Progress window

    private func showProgress(_ version: String) {
        progress = 0; bytesText = ""; phase = "Getting ready…"
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 150),
                        styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        p.titlebarAppearsTransparent = true
        p.titleVisibility = .hidden
        p.isMovableByWindowBackground = true
        p.level = .floating
        p.contentView = NSHostingView(rootView: UpdateProgressView(version: version))
        p.center()
        p.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        progressPanel = p
    }

    private func hideProgress() { progressPanel?.close(); progressPanel = nil }

    // MARK: Check for Updates…

    private func presentResult() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        switch status {
        case .available:
            guard let r = latest else { return }
            alert.messageText = "\(AppInfo.name) \(r.version) is available"
            let notes = r.notes.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "## ", with: "")
            alert.informativeText = "You have \(Self.current).\n\n" + String(notes.prefix(700))
                + (notes.count > 700 ? "…" : "")
            alert.addButton(withTitle: "Install and Relaunch")
            alert.addButton(withTitle: "Later")
            alert.addButton(withTitle: "Release Notes")
            switch alert.runModal() {
            case .alertFirstButtonReturn: install(relaunch: true)
            case .alertThirdButtonReturn: NSWorkspace.shared.open(r.page)
            default: break
            }
        case .upToDate:
            alert.messageText = "You're up to date"
            alert.informativeText = "\(AppInfo.name) \(Self.current) is the newest version."
            alert.runModal()
        case .failed(let why):
            alert.messageText = "Couldn't check for updates"
            alert.informativeText = why
            alert.runModal()
        default: break
        }
    }
}


/// The update window: what's happening and how far along it is.
private struct UpdateProgressView: View {
    let version: String
    @ObservedObject private var updater = Updater.shared
    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 56, height: 56)
            VStack(alignment: .leading, spacing: 8) {
                Text("Updating to \(version)").font(.system(size: 15, weight: .semibold))
                Text(updater.phase).font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if updater.progress < 1 {
                    ProgressView(value: updater.progress).progressViewStyle(.linear)
                } else {
                    ProgressView().progressViewStyle(.linear)
                }
                Text(updater.bytesText.isEmpty ? " " : updater.bytesText)
                    .font(.system(size: 11)).monospacedDigit().foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 22).padding(.top, 28).padding(.bottom, 18)
        .frame(width: 360)
    }
}


/// Downloads a file with progress reports (fast: whole chunks, not byte by byte).
private final class UpdateDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private var data = Data()
    private var expected: Int64 = 0
    private let progress: (Int64, Int64) -> Void
    private var continuation: CheckedContinuation<Data, Error>?

    private init(progress: @escaping (Int64, Int64) -> Void) { self.progress = progress }

    static func fetch(_ request: URLRequest, progress: @escaping (Int64, Int64) -> Void) async throws -> Data {
        let d = UpdateDownload(progress: progress)
        let session = URLSession(configuration: .ephemeral, delegate: d, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        return try await withCheckedThrowingContinuation { c in
            d.continuation = c
            session.dataTask(with: request).resume()
        }
    }

    func urlSession(_ s: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        expected = response.expectedContentLength
        if expected > 0 { data.reserveCapacity(Int(expected)) }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            continuation?.resume(throwing: APIError.message("The download didn't start (\((response as? HTTPURLResponse)?.statusCode ?? 0)).")); continuation = nil
            completionHandler(.cancel); return
        }
        completionHandler(.allow)
    }

    func urlSession(_ s: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
        data.append(chunk)
        progress(Int64(data.count), expected)
    }

    func urlSession(_ s: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let c = continuation else { return }
        continuation = nil
        if let error { c.resume(throwing: error) }
        else if data.count < 1000 { c.resume(throwing: APIError.message("The download didn't finish.")) }
        else { c.resume(returning: data) }
    }
}
