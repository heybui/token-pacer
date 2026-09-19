// swift-tools-version: 6.0
import PackageDescription

/// Sparkle, vendored.
///
/// Upstream ships the framework as a release asset rather than as source, and
/// SwiftPM fetches that asset once per clean checkout with no retry, no timeout
/// and no progress output — on a runner a stalled connection is indistinguishable
/// from a hung build. The bytes are here instead, so a checkout is a build.
///
/// A package rather than a bare `binaryTarget` in the root manifest: Xcode
/// reaches Sparkle through a package reference of its own, and a local package
/// keeps that reference working — and keeps Xcode embedding and signing the
/// framework the way it already did.
///
/// What is here is the published artifact minus its `dSYMs`, which are only
/// symbols for crash reports in code nobody here debugs, and minus the DSA
/// scripts, which the EdDSA key replaced. `DebugSymbolsPath` is out of the
/// XCFramework's `Info.plist` to match.
///
/// Upgrading: download `Sparkle-for-Swift-Package-Manager.zip` for the new tag,
/// drop in `Sparkle.xcframework`, `bin` and `LICENSE`, then repeat those two
/// removals. `VERSION` beside this file records what is here.
let package = Package(
    name: "Sparkle",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "Sparkle", targets: ["Sparkle"]),
    ],
    targets: [
        .binaryTarget(name: "Sparkle", path: "Sparkle.xcframework"),
    ]
)
