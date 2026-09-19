import Foundation

/// What the app knows about itself.
///
/// An accessory app has no Dock icon, no menu bar and therefore no About box, so
/// until the Preferences footer there was nowhere at all to read the version off.
enum AppInfo {
    /// Read from the bundle rather than written here, so the one in the plist and
    /// the one on screen cannot drift. A `swift run` build has no bundle at all.
    static var name: String { string("CFBundleName") ?? "Token Pacer" }

    static var version: String { string("CFBundleShortVersionString") ?? "0.0.0" }
    static var build: String { string("CFBundleVersion") ?? "0" }

    /// "1.2.0 (148)" — the marketing version with the build behind it, because a
    /// bug report that names only the first is a bug report about three builds.
    static var versionLine: String { "\(version) (\(build))" }

    /// Where "Send feedback" goes. One constant, so the day the page moves it
    /// moves once. Not the repo: that one is private, and every user who clicked
    /// this would have landed on a 404.
    static let feedbackPage: URL = {
        // `URL(string:)` is failable and this argument is a literal, so a nil here
        // is a typo in this file, not a runtime condition. `fatalError` names that
        // invariant where `!` only asserted it — and the rule is no force unwrap.
        guard let url = URL(string: "https://tokenpacer.com/#feedback") else {
            fatalError("AppInfo.feedbackPage is not a valid URL")
        }
        return url
    }()

    private static func string(_ key: String) -> String? {
        Bundle.main.object(forInfoDictionaryKey: key) as? String
    }
}
