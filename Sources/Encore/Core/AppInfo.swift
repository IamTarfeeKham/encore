import Foundation

/// The app's name and version, read from the bundle so a single build setting
/// (`APP_NAME` in build.sh) controls what the app calls itself everywhere.
enum AppInfo {
    static let name: String =
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
        ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
        ?? "Encore"
    static let version: String =
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
}
