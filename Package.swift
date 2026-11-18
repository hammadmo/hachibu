// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Hachibu",
    platforms: [.macOS(.v26)],
    targets: [
        // Rules and data logic with no SwiftUI, so tests run without the app.
        .target(name: "HachibuKit"),
        // C and Objective-C: reading the battery controller (SMC) and macOS's
        // own charge limit (the private PowerUI framework).
        .target(
            name: "HachibuSystem",
            linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("Foundation")]
        ),
        .executableTarget(
            name: "Hachibu",
            dependencies: ["HachibuKit", "HachibuSystem"],
            // App code runs on the main thread unless you say otherwise.
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
        .testTarget(name: "HachibuKitTests", dependencies: ["HachibuKit"]),
    ]
)
