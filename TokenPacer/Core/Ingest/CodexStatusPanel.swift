import Foundation

/// Reads Codex's limits out of the CLI's own `/status` panel.
///
/// The same trade as Claude's `/usage` panel, for the same reason — the client
/// that holds the credentials does the fetching — but bought for a different
/// gain. Codex already states its limits in its rollout logs, so this is not how
/// the figure is normally learned; it is how the figure stays true when the work
/// happened somewhere that writes no log here: the Codex desktop app, the web
/// app, a cloud task. `PanelPoller` is what keeps it to that job.
///
/// Two differences from Claude's panel, both in the wording:
///
/// - it counts what is **left**, not what is used;
/// - reset stamps are local, 24-hour and dateless-by-default — `03:59 on 19 Sep`
///   — with no timezone printed, because the CLI already converted it.
struct CodexStatusPanel: UsagePanel {
    var read: PanelReader

    func fetch(now: Date = Date()) async throws -> RateLimits {
        let text = try await read()
        guard let limits = Self.parse(text, now: now) else {
            throw PanelText.looksLikeSignIn(text) ? PanelError.notSignedIn : PanelError.unreadable
        }
        return limits
    }

    // MARK: - Parsing

    static let sessionWindowMinutes = 300
    static let weeklyWindowMinutes = 10_080

    /// Nil when the 5-hour row was not drawn — every signed-in account has one,
    /// so its absence is a failure rather than an empty reading.
    static func parse(_ raw: String, now: Date) -> RateLimits? {
        let text = PanelText.normalize(raw)
        // `5h limit:` and not the status line's `5h 100% left`: that one is a
        // truncated summary the user can switch off, and it is drawn before the
        // panel is even asked for.
        guard let session = window(after: #"5h\s*limit\s*:"#, in: text,
                                   minutes: sessionWindowMinutes, now: now)
        else { return nil }

        return RateLimits(
            primary: session,
            secondary: window(after: #"Weekly\s*limit\s*:"#, in: text,
                              minutes: weeklyWindowMinutes, now: now),
            planType: plan(in: text),
            observedAt: now
            // No spend row: the panel points at chatgpt.com for credits instead.
        )
    }

    /// `5h limit: [████] 100% left (resets 03:59 on 19 Sep)`
    private static func window(
        after label: String, in text: String, minutes: Int, now: Date
    ) -> RateLimitWindow? {
        guard let section = PanelText.tail(after: label, in: text),
              let left = PanelText.firstCapture(#"([0-9]+(?:\.[0-9]+)?)\s*%\s*left"#, in: section)
                .flatMap(Double.init)
        else { return nil }

        return RateLimitWindow(
            usedPercent: min(100, max(0, 100 - left)),
            windowMinutes: minutes,
            resetsAt: resetDate(in: section, now: now)
                ?? now.addingTimeInterval(TimeInterval(minutes * 60))
        )
    }

    /// `Account: someone@example.com (Plus)` — the plan, never the address.
    private static func plan(in text: String) -> String? {
        guard let section = PanelText.tail(after: #"Account\s*:"#, in: text, span: 120),
              let plan = PanelText.firstCapture(#"\(\s*([A-Za-z][A-Za-z0-9 +]{1,20}?)\s*\)"#, in: section)
        else { return nil }
        return plan
    }

    // MARK: - Reset times

    /// `resets 03:59 on 19 Sep`, `resets 15:23`, and — once the cursor jumps that
    /// stood in for the spaces are gone — `resets03:59on19Sep`. No timezone is
    /// printed because the CLI has already converted it, so these are local.
    /// The year is never printed and the date often isn't, so both are inferred
    /// as the next such moment after `now`, which is what a reset is.
    static func resetDate(in section: String, now: Date, calendar: Calendar = .current) -> Date? {
        guard let parts = PanelText.groups(
            #"resets\s*([0-9]{1,2}):([0-9]{2})\s*(am|pm)?\s*(?:on\s*([0-9]{1,2})\s*([A-Za-z]{3,9}))?"#,
            in: section
        ) else { return nil }

        var hour = Int(parts[0]) ?? 0
        if parts[2].lowercased() == "pm", hour < 12 { hour += 12 }
        if parts[2].lowercased() == "am", hour == 12 { hour = 0 }

        var printed = DateComponents()
        printed.hour = hour
        printed.minute = Int(parts[1]) ?? 0

        let hasDate = !parts[3].isEmpty && !parts[4].isEmpty
        if hasDate {
            printed.day = Int(parts[3])
            printed.month = month(parts[4])
            guard printed.month != nil else { return nil }
        }
        return PanelText.roll(printed, after: now, in: calendar, byDay: !hasDate)
    }

    /// `Sep` / `September` → 9. Its own lookup rather than a `DateFormatter`
    /// round trip: the panel prints English month names whatever the locale.
    private static func month(_ name: String) -> Int? {
        let key = name.lowercased().prefix(3)
        return ["jan", "feb", "mar", "apr", "may", "jun",
                "jul", "aug", "sep", "oct", "nov", "dec"]
            .firstIndex(of: String(key))
            .map { $0 + 1 }
    }
}
