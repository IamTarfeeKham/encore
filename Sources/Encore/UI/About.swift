import AppKit
import SwiftUI

/// The About window: a glowing icon over slowly drifting colour, the version and
/// update status (with Check for Updates), and quick links.
struct AboutView: View {
    private static let repo = URL(string: "https://github.com/IamTarfeeKham/encore")!
    @Environment(\.openURL) private var openURL
    @ObservedObject private var updater = Updater.shared
    @ObservedObject private var player = PlayerController.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drift = false

    private var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "–"
    }

    /// When this copy of the app was built (the executable's date).
    private var buildDate: String {
        guard let url = Bundle.main.executableURL,
              let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        else { return "" }
        return date.formatted(.dateTime.month(.abbreviated).day().year())
    }

    private var updateLine: (String, Color) {
        switch updater.status {
        case .checking: return ("Checking for updates…", .white.opacity(0.7))
        case .installing: return ("Installing the update…", .white.opacity(0.8))
        case .available: return ("Version \(updater.latest?.version ?? "") is available", Color(red: 0.55, green: 0.95, blue: 0.6))
        case .failed: return ("Couldn't check for updates", .white.opacity(0.6))
        case .upToDate: return ("You're up to date", .white.opacity(0.7))
        case .idle: return ("", .clear)
        }
    }

    var body: some View {
        ZStack {
            background.ignoresSafeArea()
            VStack(spacing: 0) {
                icon.padding(.top, 44)

                Text(AppInfo.name)
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .padding(.top, 18)
                Text("A native Mac client for YouTube Music")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))
                    .padding(.top, 4)

                HStack(spacing: 6) {
                    Text("Version \(AppInfo.version)").fontWeight(.semibold)
                    Text("(\(build))").foregroundStyle(.white.opacity(0.6))
                    if !buildDate.isEmpty { Text("· \(buildDate)").foregroundStyle(.white.opacity(0.6)) }
                }
                .font(.system(size: 12))
                .monospacedDigit()
                .padding(.horizontal, 14).padding(.vertical, 7)
                .background(Capsule().fill(.white.opacity(0.1)))
                .overlay(Capsule().strokeBorder(.white.opacity(0.18), lineWidth: 0.5))
                .padding(.top, 16)

                VStack(spacing: 8) {
                    if updater.status == .available {
                        Button { updater.install(relaunch: true) } label: {
                            Label("Install Update and Relaunch", systemImage: "arrow.down.circle.fill")
                        }
                        .buttonStyle(AboutPrimaryStyle())
                    } else {
                        Button { Task { await updater.check(userInitiated: true) } } label: {
                            Label("Check for Updates", systemImage: "arrow.triangle.2.circlepath")
                        }
                        .buttonStyle(AboutPrimaryStyle())
                        .disabled(updater.status == .checking || updater.status == .installing)
                    }
                    let (line, color) = updateLine
                    Text(line.isEmpty ? " " : line).font(.system(size: 11.5, weight: .medium)).foregroundStyle(color)
                }
                .padding(.top, 20)

                HStack(spacing: 14) {
                    AboutLink(title: "Help", symbol: "questionmark") { openURL(Self.repo.appending(path: "blob/main/README.md")) }
                    AboutLink(title: "Report", symbol: "ladybug") { openURL(Self.repo.appending(path: "issues")) }
                    AboutLink(title: "Releases", symbol: "doc.text") { openURL(Self.repo.appending(path: "releases")) }
                    AboutLink(title: "Source", symbol: "chevron.left.forwardslash.chevron.right") { openURL(Self.repo) }
                }
                .padding(.top, 22)

                Text("Open source (MIT) · Not affiliated with Google, YouTube or Apple.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.white.opacity(0.45))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                    .padding(.top, 22)
                    .padding(.bottom, 22)
            }
            .foregroundStyle(.white)
        }
        .frame(width: 360)
        .fixedSize(horizontal: false, vertical: true)
        .environment(\.colorScheme, .dark)
        .onAppear { if !reduceMotion { drift = true } }
    }

    /// The app icon with a soft glow of its own colours beneath it.
    private var icon: some View {
        let img = Image(nsImage: NSApp.applicationIconImage).resizable().interpolation(.high)
        return ZStack {
            img.frame(width: 120, height: 120).blur(radius: 28).opacity(0.75)
                .scaleEffect(drift ? 1.08 : 0.96)
            img.frame(width: 112, height: 112)
                .shadow(color: .black.opacity(0.35), radius: 16, y: 10)
        }
        .animation(.easeInOut(duration: 4).repeatForever(autoreverses: true), value: drift)
    }

    /// The same moving background as the main window: the current cover's colours.
    private var background: some View {
        AmbientBackground(artwork: player.current?.largeArtwork, dim: 0.5, parallax: 0)
    }
}

/// The main action: a bright capsule.
private struct AboutPrimaryStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13.5, weight: .semibold))
            .foregroundStyle(.black)
            .padding(.horizontal, 20).frame(height: 36)
            .background(Capsule().fill(.white.opacity(configuration.isPressed ? 0.75 : 0.95)))
            .shadow(color: .black.opacity(0.25), radius: 8, y: 4)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(duration: 0.2), value: configuration.isPressed)
    }
}

/// A round glass button with a small label underneath.
private struct AboutLink: View {
    let title: String
    let symbol: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 46, height: 46)
                    .background(Circle().fill(.white.opacity(hover ? 0.2 : 0.1)))
                    .overlay(Circle().strokeBorder(.white.opacity(0.2), lineWidth: 0.5))
                    .scaleEffect(hover ? 1.06 : 1)
                Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.75))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.spring(duration: 0.25)) { hover = h } }
    }
}
