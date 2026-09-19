// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TokenPacer",
    platforms: [.macOS(.v15)],
    dependencies: [
        // In-app updates. Ships as an XCFramework, so `make app` copies it into
        // Contents/Frameworks and signs it — SPM links it but cannot embed it.
        // Vendored rather than fetched: Vendor/Sparkle/Package.swift says why.
        .package(path: "Vendor/Sparkle"),
    ],
    targets: [
        .executableTarget(
            name: "TokenPacer",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            path: "TokenPacer",
            // Xcode's synchronized group picks these up; SPM only builds the
            // binary and would warn about every file it cannot compile.
            exclude: ["Resources", "Info.plist", "TokenPacer.entitlements"]
        ),
        // Fixtures are read from disk via #filePath, not from a bundle.
        .testTarget(
            name: "TokenPacerTests",
            dependencies: ["TokenPacer"],
            path: "TokenPacerTests",
            exclude: ["Fixtures"]
        ),
    ]
)
