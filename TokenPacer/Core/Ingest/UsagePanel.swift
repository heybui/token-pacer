import Foundation

/// One CLI's own account reading, already fetched by the client that holds the
/// credentials. Claude Code and Copilot render theirs on `/usage` and are read
/// back off a terminal; Codex answers `account/rateLimits/read` over JSON-RPC
/// and is read as numbers. Either way the app never holds a token.
protocol UsagePanel: Sendable {
    func fetch(now: Date) async throws -> RateLimits
}

/// Returns one run's raw output — a terminal render, escape sequences and all,
/// or a line of JSON. Injected so every parser is testable without spawning
/// anything.
typealias PanelReader = @Sendable () async throws -> String

/// What can go wrong driving a CLI.
///
/// This replaces a set of HTTP status codes, and it is deliberately coarser. A
/// panel is a picture: it states what the limits are, never why a reading failed.
/// The distinctions that survive are the ones visible from outside the process.
enum PanelError: Error, Equatable {
    /// No binary in any known install location.
    case cliNotFound
    /// Every project the CLI knows still owes the trust dialog an answer, and an
    /// untrusted directory stops it before it draws anything.
    case noTrustedDirectory
    case spawnFailed(code: Int32)
    case timedOut
    /// The CLI drew a sign-in prompt where the panel should have been.
    case notSignedIn
    /// The panel rendered but carried no figure we recognise — in practice a
    /// layout change in a new release.
    case unreadable

    /// Only a refusal that cannot change on its own stops us asking for good.
    /// A timeout, a missing sign-in and an unreadable panel all resolve without
    /// any action from this app; a missing binary does not.
    var isFatal: Bool {
        switch self {
        case .cliNotFound, .noTrustedDirectory: true
        case .spawnFailed, .timedOut, .notSignedIn, .unreadable: false
        }
    }

    /// Named for the CLI it came from: the pill shows this on its own, with
    /// nothing else on screen to say which provider is broken.
    func message(for cli: String) -> String {
        switch self {
        case .cliNotFound: "\(cli) CLI not found"
        case .noTrustedDirectory: "No trusted \(cli) project to read from"
        case .spawnFailed(let code): "Could not start \(cli) (\(code))"
        case .timedOut: "\(cli) did not answer in time"
        case .notSignedIn: "Sign in to \(cli)"
        case .unreadable: "Could not read \(cli)'s usage panel"
        }
    }
}

/// Turning a terminal render back into text, and finding things in it.
///
/// Shared because the TUI panels are drawn with the same two habits: they
/// position the cursor instead of emitting padding, and they wedge bars and
/// glyphs between a label and its number.
enum PanelText {
    /// Terminal output is a stream of cursor moves, not lines: a panel paints
    /// itself in place, so newlines say nothing about layout, and the spaces
    /// between words are often cursor jumps rather than characters — stripping
    /// the escapes welds `Current session` into `Currentsession`. Flatten it to
    /// one string, and let every pattern treat whitespace as optional.
    static func normalize(_ raw: String) -> String {
        var text = raw
        for pattern in [
            #"\x{1B}\][^\x{07}\x{1B}]*(?:\x{07}|\x{1B}\\)"#,   // OSC
            #"\x{1B}\[[0-9;?]*[ -/]*[@-~]"#,                    // CSI
            #"\x{1B}[()][AB012]"#,                              // charset
            #"\x{1B}[>=<]"#,                                    // keypad mode
            #"[\x{0000}-\x{0008}\x{000B}\x{000C}\x{000E}-\x{001F}]"#,
        ] {
            text = text.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        // Bars, rules and status glyphs sit between a label and its number, and
        // carry none of it. Codex draws its panel inside a box, so the frame goes
        // the same way.
        text = text.replacingOccurrences(
            of: #"[\x{2500}-\x{259F}\x{25A0}-\x{25FF}\x{23F0}-\x{23FF}\x{2B00}-\x{2BFF}\x{00B7}\x{2022}]"#,
            with: " ", options: .regularExpression
        )
        return text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }

    /// A panel can repaint mid-read — a cached figure first, the refreshed one
    /// after — so the *last* match is the one that counts.
    static func tail(after pattern: String, in text: String, span: Int = 220) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).last,
              let range = Range(match.range, in: text)
        else { return nil }

        let rest = text[range.upperBound...]
        return String(rest.prefix(span))
    }

    static func firstCapture(_ pattern: String, in text: String) -> String? {
        captures(pattern, in: text)?.first
    }

    /// Every capture group of the first match, in order.
    static func captures(_ pattern: String, in text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
        else { return nil }

        return (1..<match.numberOfRanges).compactMap {
            Range(match.range(at: $0), in: text).map { String(text[$0]) }
        }
    }

    /// Anchor the printed fields to the current year (or day), then step forward
    /// once if that lands in the past.
    static func roll(
        _ printed: DateComponents, after now: Date, in calendar: Calendar, byDay: Bool
    ) -> Date? {
        var components = calendar.dateComponents([.year, .month, .day], from: now)
        components.hour = printed.hour ?? 0
        components.minute = printed.minute ?? 0
        components.second = 0
        if !byDay {
            components.month = printed.month
            components.day = printed.day
        }
        guard let candidate = calendar.date(from: components) else { return nil }
        guard candidate <= now else { return candidate }
        return calendar.date(byAdding: byDay ? .day : .year, value: 1, to: candidate)
    }

    /// Every capture group, positionally — a group that did not participate
    /// comes back as `""` rather than being dropped, which is what a pattern
    /// with optional groups needs to keep its indexes.
    static func groups(_ pattern: String, in text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
        else { return nil }

        return (1..<match.numberOfRanges).map {
            Range(match.range(at: $0), in: text).map { String(text[$0]) } ?? ""
        }
    }

    static func looksLikeSignIn(_ raw: String) -> Bool {
        let text = normalize(raw)
        for pattern in [
            #"/login"#, #"Sign\s*in\s*to"#, #"Log\s*in\s*with"#,
            #"session\s*has\s*expired"#, #"Not\s*signed\s*in"#,
            // How `codex app-server` says it: an error object reading
            // `codex account authentication required to read rate limits`.
            #"authentication\s*required"#,
        ] where text.range(of: pattern, options: .regularExpression) != nil {
            return true
        }
        return false
    }
}
