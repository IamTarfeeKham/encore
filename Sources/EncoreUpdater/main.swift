import AppKit
import CryptoKit
import Foundation

// Encore Updater — installs an update for the main app. The app is sandboxed, so it
// can't replace itself; it launches this small helper (bundled inside it, not
// sandboxed) and quits. The helper:
//   1. downloads the release zip from GitHub,
//   2. checks its signature against the key the app was built with (an update that
//      wasn't signed with the release key is refused),
//   3. waits for the app to quit, moves the old copy to the Trash, puts the new one
//      in its place (keeping your name for the app), and
//   4. opens it again if asked to.
// Usage: EncoreUpdater --url <zip> --signature <base64> --app <path.app> --pid <pid> [--relaunch]

let releasePublicKey = "PDZQ3bNylBTy37lNevQatavup9mjtLLFkA+BWrkIJG8="
let appBundleID = "local.ytmusicmac"

let logURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Logs/Encore Updater.log")
func log(_ s: String) {
    let line = "\(Date()) \(s)\n"
    if let h = try? FileHandle(forWritingTo: logURL) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
    else { try? line.write(to: logURL, atomically: true, encoding: .utf8) }
}

// The request comes as arguments (manual use), or, when the sandboxed app starts
// us (it can't pass arguments), from the file it leaves in its own data folder.
let requestFile: URL = {
    let home = getpwuid(getuid()).flatMap { String(validatingCString: $0.pointee.pw_dir) } ?? NSHomeDirectory()
    return URL(fileURLWithPath: home).appendingPathComponent("Library/Containers/local.ytmusicmac/Data/Library/Caches/EncoreUpdate.json")
}()
let fileRequest: [String: Any] = {
    guard CommandLine.arguments.count <= 1, let d = try? Data(contentsOf: requestFile),
          let r = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return [:] }
    try? FileManager.default.removeItem(at: requestFile)
    return r
}()

func arg(_ name: String) -> String? {
    let a = CommandLine.arguments
    if let i = a.firstIndex(of: name), i + 1 < a.count { return a[i + 1] }
    let key = String(name.dropFirst(2))
    if let v = fileRequest[key] as? String { return v }
    if let v = fileRequest[key] as? Int { return String(v) }
    return nil
}

@discardableResult
func run(_ tool: String, _ args: [String]) -> (Int32, String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: tool)
    p.arguments = args
    // Standard output only (tools like codesign print status lines on stderr).
    let out = Pipe(), err = Pipe()
    p.standardOutput = out
    p.standardError = err
    do { try p.run() } catch { return (-1, "\(error)") }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    let errData = err.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    let text = String(decoding: data, as: UTF8.self)
    return (p.terminationStatus, p.terminationStatus == 0 ? text : text + String(decoding: errData, as: UTF8.self))
}

func bundleID(of app: URL) -> String? {
    (NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")) as? [String: Any])?["CFBundleIdentifier"] as? String
}

func reopen(_ app: URL) { run("/usr/bin/open", [app.path]) }

func fail(_ why: String, reopen app: URL?) -> Never {
    log("update failed: \(why)")
    if let app { reopen(app) }
    exit(1)
}

// The app usually downloads the zip itself (showing progress) and passes its path.
let localZip = arg("--zipPath").map(URL.init(fileURLWithPath:)).flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
guard let urlString = arg("--url"), let url = URL(string: urlString), url.scheme == "https",
      let host = url.host, host == "github.com" || host.hasSuffix(".githubusercontent.com"),
      let signature = arg("--signature").flatMap({ Data(base64Encoded: $0) }),
      let appPath = arg("--app"), appPath.hasSuffix(".app"),
      let pid = arg("--pid").flatMap(Int32.init)
else {
    log("bad request: \(CommandLine.arguments.dropFirst()) \(fileRequest.keys.sorted())")
    // Don't leave the app closed if it quit for this.
    if let app = fileRequest["app"] as? String, app.hasSuffix(".app") { reopen(URL(fileURLWithPath: app)) }
    exit(2)
}

let relaunch = CommandLine.arguments.contains("--relaunch") || (fileRequest["relaunch"] as? Bool ?? false)
let target = URL(fileURLWithPath: appPath).standardizedFileURL
guard bundleID(of: target) == appBundleID else { fail("\(target.path) isn't Encore", reopen: nil) }
let reopenOnFail: URL? = relaunch ? target : nil

log("updating \(target.path) from \(url.absoluteString)")

// 1. Download.
guard let zip = (localZip.flatMap { try? Data(contentsOf: $0) }) ?? (try? Data(contentsOf: url)), zip.count > 1000
else { fail("download failed", reopen: reopenOnFail) }
if let localZip { try? FileManager.default.removeItem(at: localZip) }

// 2. Signature.
guard let keyData = Data(base64Encoded: releasePublicKey),
      let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData),
      key.isValidSignature(signature, for: zip)
else { fail("the download's signature doesn't match the release key", reopen: reopenOnFail) }

// 3. Unpack and check what's inside.
let work = FileManager.default.temporaryDirectory.appendingPathComponent("EncoreUpdate-\(UUID().uuidString)")
try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
let zipFile = work.appendingPathComponent("update.zip")
guard (try? zip.write(to: zipFile)) != nil else { fail("couldn't save the download", reopen: reopenOnFail) }
let unpacked = work.appendingPathComponent("unpacked")
guard run("/usr/bin/ditto", ["-x", "-k", zipFile.path, unpacked.path]).0 == 0,
      let newApp = (try? FileManager.default.contentsOfDirectory(at: unpacked, includingPropertiesForKeys: nil))?
          .first(where: { $0.pathExtension == "app" }),
      bundleID(of: newApp) == appBundleID
else { fail("the download didn't contain Encore", reopen: reopenOnFail) }

// Keep the name you gave the app (e.g. "YouTube Music"): copy it into the new
// version and re-sign it, the same way build.sh signs it.
let oldInfo = NSDictionary(contentsOf: target.appendingPathComponent("Contents/Info.plist")) as? [String: Any] ?? [:]
let newInfoURL = newApp.appendingPathComponent("Contents/Info.plist")
if var newInfo = NSDictionary(contentsOf: newInfoURL) as? [String: Any],
   let oldName = oldInfo["CFBundleName"] as? String, oldName != newInfo["CFBundleName"] as? String {
    newInfo["CFBundleName"] = oldName
    newInfo["CFBundleDisplayName"] = oldInfo["CFBundleDisplayName"] ?? oldName
    (newInfo as NSDictionary).write(to: newInfoURL, atomically: true)
    let entitlements = work.appendingPathComponent("entitlements.plist")
    let (_, xml) = run("/usr/bin/codesign", ["-d", "--entitlements", "-", "--xml", newApp.path])
    try? Data(xml.utf8).write(to: entitlements)
    let (code, out) = run("/usr/bin/codesign", ["--force", "--sign", "-", "--timestamp=none", "--options", "runtime",
                                               "--entitlements", entitlements.path, newApp.path])
    if code != 0 { fail("re-signing failed: \(out)", reopen: reopenOnFail) }
}
run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", newApp.path])

// 4. Wait for the app to quit (up to two minutes).
var waited = 0.0
while kill(pid, 0) == 0, waited < 120 { Thread.sleep(forTimeInterval: 0.25); waited += 0.25 }
if kill(pid, 0) == 0 { fail("the app didn't quit", reopen: nil) }

// 5. Swap: old copy to the Trash, new one in its place.
var trashed: NSURL?
do {
    try FileManager.default.trashItem(at: target, resultingItemURL: &trashed)
} catch {
    // No Trash on this volume: remove it instead.
    do { try FileManager.default.removeItem(at: target) } catch { fail("couldn't remove the old version: \(error)", reopen: reopenOnFail) }
}
do {
    try FileManager.default.moveItem(at: newApp, to: target)
} catch {
    if let t = trashed as URL? { try? FileManager.default.moveItem(at: t, to: target) }
    fail("couldn't put the new version in place: \(error)", reopen: reopenOnFail)
}
try? FileManager.default.removeItem(at: work)
log("updated to \((NSDictionary(contentsOf: target.appendingPathComponent("Contents/Info.plist")) as? [String: Any])?["CFBundleShortVersionString"] ?? "?")")

// 6. Reopen.
if relaunch { reopen(target) }
exit(0)
