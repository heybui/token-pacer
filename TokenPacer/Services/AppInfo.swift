import Foundation

/// What the app knows about itself.
///
/// An accessory app has no Dock icon, no menu bar and therefore no About box, so
/// until the Preferences footer there was nowhere at all to read the version off.
enum AppInfo {
    static var version: String { string("CFBundleShortVersionString") ?? "0.0.0" }
    static var build: String { string("CFBundleVersion") ?? "0" }

    /// "1.2.0 (148)" — the marketing version with the build behind it, because a
    /// bug report that names only the first is a bug report about three builds.
    static var versionLine: String { "\(version) (\(build))" }

    /// Where "Send feedback" goes. One constant, so the day the page moves it
    /// moves once. Not the repo: that one is private, and every user who clicked
    /// this would have landed on a 404.
    static let landingPage = URL(string: "https://tokenpacer.com")!

    private static func string(_ key: String) -> String? {
        Bundle.main.object(forInfoDictionaryKey: key) as? String
    }
}
