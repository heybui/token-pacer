// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BurnTracker",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(name: "BurnTracker", path: "Sources"),
        // Fixtures are read from disk via #filePath, not from a bundle.
        .testTarget(
            name: "BurnTrackerTests",
            dependencies: ["BurnTracker"],
            path: "Tests",
            exclude: ["Fixtures"]
        ),
    ]
)
