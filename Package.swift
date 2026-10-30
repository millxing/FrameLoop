// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "FrameLoop2",
    platforms: [.macOS(.v26)],
    targets: [
        // Rules and data logic with no SwiftUI, so tests run without the app.
        .target(name: "FrameLoop2Kit"),
        .executableTarget(
            name: "FrameLoop2",
            dependencies: ["FrameLoop2Kit"],
            // App code runs on the main thread unless you say otherwise.
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
        .testTarget(name: "FrameLoop2KitTests", dependencies: ["FrameLoop2Kit"]),
    ]
)
