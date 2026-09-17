import Foundation

/// What can go wrong driving the CLI.
///
/// This replaces a set of HTTP status codes, and it is deliberately coarser. The
/// panel is a picture: it states what the limits are, never why a reading failed.
/// The distinctions that survive are the ones visible from outside the process.
enum PanelError: Error, Equatable {
    /// No `claude` binary in any known install location.
    case cliNotFound
    /// Every project in `~/.claude.json` still owes the trust dialog an answer,
    /// and an untrusted directory stops the CLI before it draws anything.
    case noTrustedDirectory
    case spawnFailed(code: Int32)
    case timedOut
    /// The CLI drew a sign-in prompt where the panel should have been.
    case notSignedIn
    /// The panel rendered but carried no figure we recognise — in practice a
    /// layout change in a new Claude Code release.
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

    var message: String {
        switch self {
        case .cliNotFound: "Claude Code CLI not found"
        case .noTrustedDirectory: "no trusted Claude Code project to read from"
        case .spawnFailed(let code): "could not start the CLI (\(code))"
        case .timedOut: "the CLI did not answer in time"
        case .notSignedIn: "sign in to Claude Code"
        case .unreadable: "could not read the usage panel"
        }
    }
}

/// Reads Claude's limits out of the CLI's own `/usage` panel.
///
/// The panel is what the OAuth endpoint returns, already fetched and rendered by
/// a client that owns the credentials — which is the whole point: no Keychain
/// prompt, no token of our own, nothing of Claude Code's to keep in sync.
///
/// The cost is stated plainly: the panel prints **whole percentages**. Anything
/// that needed a fraction of a point is gone with it.
struct ClaudeUsagePanel: Sendable {
    /// Returns one `/usage` run's raw terminal output, escape sequences and all.
    /// Injected so the parsing is testable without spawning anything.
    typealias Reader = @Sendable () async throws -> String

    var read: Reader

    func fetch(now: Date = Date()) async throws -> RateLimits {
        let text = try await read()
        guard let limits = Self.parse(text, now: now) else {
            throw Self.looksLikeSignIn(text) ? PanelError.notSignedIn : PanelError.unreadable
        }
        return limits
    }

    // MARK: - Parsing

    static let sessionWindowMinutes = 300
    static let weeklyWindowMinutes = 10_080

    /// Nil when nothing recognisable was drawn. A panel that renders but omits
    /// the session window is a failure, not an empty reading: every account the
    /// CLI signs in shows one.
    static func parse(_ raw: String, now: Date) -> RateLimits? {
        let text = normalize(raw)
        guard let session = window(after: #"Current\s*session"#, in: text,
                                   minutes: sessionWindowMinutes, now: now)
        else { return nil }

        return RateLimits(
            primary: session,
            secondary: window(after: #"Current\s*week\s*\(\s*all\s*models\s*\)"#, in: text,
                              minutes: weeklyWindowMinutes, now: now),
            // The panel never names the plan. `nil` is honest; guessing from the
            // window layout would not be.
            planType: nil,
            observedAt: now,
            spend: spend(in: text, now: now)
        )
    }

    /// Terminal output is a stream of cursor moves, not lines: the panel paints
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
        // carry none of it.
        text = text.replacingOccurrences(
            of: #"[\x{2500}-\x{259F}\x{25A0}-\x{25FF}\x{23F0}-\x{23FF}\x{2B00}-\x{2BFF}\x{00B7}\x{2022}]"#,
            with: " ", options: .regularExpression
        )
        return text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }

    /// The panel can repaint mid-read — a cached figure first, the refreshed one
    /// after — so the *last* match is the one that counts.
    private static func tail(after pattern: String, in text: String, span: Int = 220) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).last,
              let range = Range(match.range, in: text)
        else { return nil }

        let rest = text[range.upperBound...]
        return String(rest.prefix(span))
    }

    private static func window(
        after label: String, in text: String, minutes: Int, now: Date
    ) -> RateLimitWindow? {
        guard let section = tail(after: label, in: text),
              let percent = firstCapture(#"([0-9]+(?:\.[0-9]+)?)\s*%\s*used"#, in: section)
                .flatMap(Double.init)
        else { return nil }

        return RateLimitWindow(
            usedPercent: min(100, max(0, percent)),
            windowMinutes: minutes,
            // A window with no readable reset is still worth showing. Dating it
            // now makes it look like it resets this instant, so it is pushed out
            // by the window's own length instead.
            resetsAt: resetDate(in: section, now: now)
                ?? now.addingTimeInterval(TimeInterval(minutes * 60))
        )
    }

    /// `Usage credits  99% used  S$11.99 / S$12.00 spent`
    private static func spend(in text: String, now: Date) -> Spend? {
        guard let section = tail(after: #"Usage\s*credits"#, in: text) else { return nil }
        let percent = firstCapture(#"([0-9]+(?:\.[0-9]+)?)\s*%\s*used"#, in: section)
            .flatMap(Double.init)

        // Anchored on the digits, not on whitespace: the panel routinely runs the
        // previous label straight into the figure — `99%usedS$11.99` — and a
        // whitespace-delimited match swallows the lot.
        let amount = #"([A-Z]{0,3}[$\x{20AC}\x{00A3}\x{00A5}\x{20A9}\x{20B9}\x{0E3F}\x{20AB}]?[0-9][0-9,]*(?:\.[0-9]+)?)"#
        guard let pair = captures(amount + #"\s*/\s*"# + amount + #"\s*spent"#, in: section),
              let used = money(pair[0])
        else { return nil }

        return Spend(used: used, limit: money(pair[1]), percent: percent, isEnabled: true)
    }

    /// `S$11.99` → 1199 minor units of SGD. The symbol is what the panel prints;
    /// `Money` wants a code, so the ones that are unambiguous are mapped and the
    /// rest are carried through as they came.
    static func money(_ raw: String) -> Money? {
        guard let parts = captures(#"^([^0-9.,-]*)([0-9][0-9,]*(?:\.[0-9]+)?)$"#, in: raw)
        else { return nil }

        let digits = parts[1].replacingOccurrences(of: ",", with: "")
        let fraction = digits.split(separator: ".").dropFirst().first.map(\.count) ?? 0
        guard let value = Double(digits) else { return nil }

        let symbol = parts[0].trimmingCharacters(in: .whitespaces)
        return Money(
            amountMinor: Int((value * pow(10, Double(fraction))).rounded()),
            currency: currencyCodes[symbol] ?? (symbol.isEmpty ? "USD" : symbol),
            exponent: fraction
        )
    }

    private static let currencyCodes = [
        "$": "USD", "US$": "USD", "S$": "SGD", "A$": "AUD", "C$": "CAD",
        "NZ$": "NZD", "HK$": "HKD", "R$": "BRL", "₩": "KRW", "₹": "INR",
        "€": "EUR", "£": "GBP", "¥": "JPY", "฿": "THB", "₫": "VND",
    ]

    // MARK: - Reset times

    /// The panel writes reset times for people, not for parsers:
    /// `2:50pm (Asia/Saigon)`, `Sep 22 at 1am`, `Oct 1` — and just as often
    /// `ResetsSep22at1am(Asia/Saigon)`, with every space a cursor jump that did
    /// not survive. The year is never printed and the day often isn't, so both
    /// are inferred as the next such moment after `now`, which is what a reset is.
    static func resetDate(in section: String, now: Date) -> Date? {
        guard let parts = captures(#"Resets\s*([^()]{1,40}?)\s*\(([^)]+)\)"#, in: section),
              let zone = TimeZone(identifier: parts[1].trimmingCharacters(in: .whitespaces))
        else { return nil }

        let stamp = respace(parts[0])
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone

        for format in ["MMM d h:mm a", "MMM d h a", "MMM d", "h:mm a", "h a"] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = zone
            formatter.dateFormat = format
            guard let parsed = formatter.date(from: stamp) else { continue }

            let fields: Set<Calendar.Component> = format.hasPrefix("MMM")
                ? [.month, .day, .hour, .minute]
                : [.hour, .minute]
            return roll(calendar.dateComponents(fields, from: parsed),
                        after: now, in: calendar, byDay: !format.hasPrefix("MMM"))
        }
        return nil
    }

    /// Put the spaces back where the terminal dropped them, by splitting on the
    /// letter/digit boundaries the words were separated by anyway. `Sep22at1am`
    /// becomes `Sep 22 1 am`; an already-spaced stamp comes through unchanged.
    private static func respace(_ stamp: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"[A-Za-z]+|[0-9]+(?::[0-9]+)?"#)
        else { return stamp }

        let range = NSRange(stamp.startIndex..., in: stamp)
        return regex.matches(in: stamp, range: range)
            .compactMap { Range($0.range, in: stamp).map { String(stamp[$0]) } }
            .filter { $0.lowercased() != "at" }
            .joined(separator: " ")
    }

    /// Anchor the printed fields to the current year (or day), then step forward
    /// once if that lands in the past.
    private static func roll(
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

    // MARK: - Regex helpers

    static func looksLikeSignIn(_ raw: String) -> Bool {
        let text = normalize(raw)
        for pattern in [#"/login"#, #"Sign\s*in\s*to"#, #"Log\s*in\s*with"#, #"session\s*has\s*expired"#]
        where text.range(of: pattern, options: .regularExpression) != nil {
            return true
        }
        return false
    }

    private static func firstCapture(_ pattern: String, in text: String) -> String? {
        captures(pattern, in: text)?.first
    }

    /// Every capture group of the first match, in order.
    private static func captures(_ pattern: String, in text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
        else { return nil }

        return (1..<match.numberOfRanges).compactMap {
            Range(match.range(at: $0), in: text).map { String(text[$0]) }
        }
    }
}
