// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Encore",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Encore",
            path: "Sources/Encore"
        )
    ]
)
