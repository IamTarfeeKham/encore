import AppKit
import SwiftUI

/// The app's About window (replaces the standard About panel): icon, name,
/// version, build date, and links to help and support.
struct AboutView: View {
    private static let repo = URL(string: "https://github.com/IamTarfeeKham/encore")!
    @Environment(\.openURL) private var openURL

    private var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "–"
    }

    /// When this copy of the app was built (the executable's date).
    private var buildDate: String {
        guard let url = Bundle.main.executableURL,
              let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        else { return "" }
        return date.formatted(.dateTime.month(.abbreviated).day().year().hour().minute())
    }

    var body: some View {
        VStack(spacing: 0) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 104, height: 104)
                .shadow(color: .black.opacity(0.28), radius: 14, y: 7)
                .padding(.top, 34)

            Text(AppInfo.name)
                .font(.system(size: 26, weight: .bold, design: .rounded))
                .padding(.top, 16)
            Text("A native Mac client for YouTube Music")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .padding(.top, 4)

            VStack(spacing: 4) {
                Text("Version \(AppInfo.version) (\(build))")
                if !buildDate.isEmpty { Text(buildDate) }
            }
            .font(.system(size: 13))
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .padding(.top, 16)

            VStack(spacing: 10) {
                Button("Help") { openURL(Self.repo.appending(path: "blob/main/README.md")) }
                Button("Get Support") { openURL(Self.repo.appending(path: "issues")) }
                Button("Release Notes") { openURL(Self.repo.appending(path: "releases")) }
            }
            .buttonStyle(AboutButtonStyle())
            .padding(.top, 26)
            .padding(.horizontal, 48)

            Text("Unofficial and open source (MIT).\nNot affiliated with Google, YouTube or Apple.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 22)
                .padding(.bottom, 26)
        }
        .frame(width: 340)
        .fixedSize(horizontal: false, vertical: true)
        .background(.regularMaterial)
    }
}

private struct AboutButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        AboutButtonBody(configuration: configuration)
    }

    fileprivate struct AboutButtonBody: View {
        let configuration: Configuration
        @State private var hover = false
        var body: some View {
            configuration.label
                .font(.system(size: 14, weight: .medium))
                .frame(maxWidth: .infinity)
                .frame(height: 38)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.primary.opacity(configuration.isPressed ? 0.14 : hover ? 0.09 : 0.05))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
                )
                .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .onHover { hover = $0 }
                .animation(.easeOut(duration: 0.12), value: hover)
        }
    }
}
