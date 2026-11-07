// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Player",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(
            name: "Player",
            path: "Sources/Player",
            swiftSettings: [.defaultIsolation(MainActor.self)]
        )
    ]
)
