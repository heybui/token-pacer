// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BurnTracker",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(name: "BurnTracker", path: "Sources"),
        .testTarget(name: "BurnTrackerTests", dependencies: ["BurnTracker"], path: "Tests"),
    ]
)
