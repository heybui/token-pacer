// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BurnTracker",
    platforms: [.macOS(.v15)],
    dependencies: [
        // In-app updates. Ships as an XCFramework, so `make app` copies it into
        // Contents/Frameworks and signs it — SPM links it but cannot embed it.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        .executableTarget(
            name: "BurnTracker",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            path: "Sources"
        ),
        // Fixtures are read from disk via #filePath, not from a bundle.
        .testTarget(
            name: "BurnTrackerTests",
            dependencies: ["BurnTracker"],
            path: "Tests",
            exclude: ["Fixtures"]
        ),
    ]
)
