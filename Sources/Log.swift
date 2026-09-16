import os

/// Cross-cutting, owned by no layer.
///
/// `os.Logger` rather than print: a bundled app launched from Finder has nowhere
/// to send stdout, and this is readable live with
/// `log stream --predicate 'subsystem == "com.redevify.tokenburn"'`.
///
/// Dynamic values are redacted as `<private>` by default, so anything safe to read
/// is marked `.public` explicitly. The token never is.
enum Log {
    private static let subsystem = "com.redevify.tokenburn"

    static let usage = Logger(subsystem: subsystem, category: "usage-api")
    static let ingest = Logger(subsystem: subsystem, category: "ingest")
    static let notch = Logger(subsystem: subsystem, category: "notch")
}
