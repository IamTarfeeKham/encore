// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Encore",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Encore",
            path: "Sources/Encore"
        ),
        // Installs updates (the sandboxed app can't replace itself); bundled in
        // Contents/Helpers by build.sh.
        .executableTarget(
            name: "EncoreUpdater",
            path: "Sources/EncoreUpdater"
        ),
        // Desktop widgets (WidgetKit extension); bundled in Contents/PlugIns by build.sh.
        .executableTarget(
            name: "EncoreWidgets",
            path: "Sources/EncoreWidgets",
            swiftSettings: [.unsafeFlags(["-application-extension"])],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-application_extension"])]
        )
    ]
)
