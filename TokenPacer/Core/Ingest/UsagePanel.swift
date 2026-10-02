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
    /// The CLI could not reach its own server. Codex's app-server says so as
    /// `error sending request for url (…/wham/usage)` where the figures go.
    case offline
    /// The panel rendered but carried no figure we recognise — in practice a
    /// layout change in a new release.
    case unreadable

    /// Only a refusal that cannot change on its own stops us asking for good.
    /// A timeout, a missing sign-in and an unreadable panel all resolve without
    /// any action from this app; a missing binary does not.
    var isFatal: Bool {
        switch self {
        case .cliNotFound, .noTrustedDirectory: true
        case .spawnFailed, .timedOut, .notSignedIn, .offline, .unreadable: false
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
        case .offline: "\(cli) can't connect right now"
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

    /// The screen the stream draws, rather than the stream.
    ///
    /// Claude Code repaints by moving the cursor over cells that did not
    /// change: `Resets Oc\e[13G 6 a\e[18G 1am` is "Resets Oct 6 at 1am" with
    /// both `t`s left standing from the frame before. Stripping the escapes
    /// loses those letters for good, so the moves are played onto a grid
    /// instead. Relative moves only — the CLI uses no absolute positioning, so
    /// the grid never needs to know where the viewport's top is.
    /// ponytail: CUU/CUD/CUF/CUB/CHA/EL, CR, LF, BS, TAB; one cell per
    /// character. A panel that starts drawing wide glyphs or absolute CUP
    /// moves wants a real emulator.
    static func screen(_ raw: String) -> String {
        var rows: [[Character]] = [[]]
        var row = 0, column = 0
        var characters = raw.makeIterator()

        func put(_ character: Character) {
            while rows[row].count <= column { rows[row].append(" ") }
            rows[row][column] = character
            column += 1
        }

        while let character = characters.next() {
            switch character {
            case "\u{1B}":
                guard let kind = characters.next() else { break }
                if kind == "[" {
                    var parameters = ""
                    var final: Character?
                    while let next = characters.next() {
                        if let ascii = next.asciiValue, (0x40...0x7E).contains(ascii) { final = next; break }
                        parameters.append(next)
                    }
                    let n = max(1, Int(parameters.filter(\.isNumber)) ?? 1)
                    switch final {
                    case "A": row = max(0, row - n)
                    case "B": row += n
                    case "C": column += n
                    case "D": column = max(0, column - n)
                    case "G": column = n - 1
                    case "K":
                        while rows.count <= row { rows.append([]) }
                        switch parameters {
                        case "", "0": if rows[row].count > column { rows[row].removeSubrange(column...) }
                        case "1": for i in 0..<min(column + 1, rows[row].count) { rows[row][i] = " " }
                        default: rows[row] = []
                        }
                    default: break
                    }
                } else if kind == "]" {
                    // OSC, to BEL or ST.
                    while let next = characters.next(), next != "\u{07}" {
                        if next == "\u{1B}" { _ = characters.next(); break }
                    }
                } else if kind == "(" || kind == ")" {
                    _ = characters.next()
                }
            case "\n", "\r\n":
                row += 1
                column = 0
            case "\r": column = 0
            case "\u{08}": column = max(0, column - 1)
            case "\t": column = (column / 8 + 1) * 8
            default:
                guard !(character.unicodeScalars.first.map(CharacterSet.controlCharacters.contains) ?? false)
                else { continue }
                while rows.count <= row { rows.append([]) }
                put(character)
            }
            while rows.count <= row { rows.append([]) }
        }
        return rows.map { String($0) }.joined(separator: "\n")
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

    /// What follows every match, newest first. A repaint redraws only the
    /// cells that changed, so the newest copy of a section can be missing a
    /// word the one before it still has.
    static func tails(after pattern: String, in text: String, span: Int = 220) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
            .reversed()
            .compactMap { Range($0.range, in: text).map { String(text[$0.upperBound...].prefix(span)) } }
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

    /// Why a reply that carried no figure carried none. Shared so every
    /// provider tells the same three apart the same way.
    static func failure(in raw: String) -> PanelError {
        if looksLikeSignIn(raw) { return .notSignedIn }
        let text = normalize(raw)
        for pattern in [
            #"error\s*sending\s*request"#, #"failed\s*to\s*fetch"#,
            #"could\s*not\s*resolve"#, #"network\s*(is\s*)?unreachable"#,
            #"connection\s*(refused|reset|failed)"#,
        ] where text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil {
            return .offline
        }
        return .unreadable
    }

    static func looksLikeSignIn(_ raw: String) -> Bool {
        let text = normalize(raw)
        for pattern in [
            #"/login"#, #"Sign\s*in\s*to"#, #"Log\s*in\s*with"#,
            #"session\s*has\s*expired"#, #"Not\s*signed\s*in"#,
            // How `codex app-server` says it: an error object reading
            // `codex account authentication required to read rate limits`.
            #"authentication\s*required"#,
            // And how `copilot --headless --stdio` says it: `Not
            // authenticated. Please authenticate first.`
            #"Not\s*authenticated"#,
        ] where text.range(of: pattern, options: .regularExpression) != nil {
            return true
        }
        return false
    }
}
