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

    func fetch(now: Date = Date.now) async throws -> RateLimits {
        let text = try await read()
        guard let limits = Self.parse(text, now: now) else {
            throw PanelText.looksLikeSignIn(text) ? PanelError.notSignedIn : PanelError.unreadable
        }
        return limits
    }

    // MARK: - Parsing

    static let sessionWindowMinutes = 300
    static let weeklyWindowMinutes = 10_080
    static let monthlyWindowMinutes = 43_200

    /// Every limit row the panel can draw, and how long the window behind it is.
    ///
    /// Codex names a window by its own length — `5h`, `Daily`, `Weekly`,
    /// `Monthly`, `Annual` — and an account metered in credits draws none of
    /// them: an Enterprise workspace on a credit budget prints a single
    /// `Monthly credit limit` row instead. Which rows exist is the shape of the
    /// account, not of the release, so take whatever was drawn and order it by
    /// window length. Insisting on the five-hour one read every credit account
    /// as a broken panel.
    ///
    /// Every pattern carries `limit:` and the status line's summary — `5h 100%
    /// left`, drawn before the panel is asked for and switchable off — does not.
    static let rows: [(label: String, minutes: Int)] = [
        (#"5h\s*limit\s*:"#, sessionWindowMinutes),
        (#"Daily\s*limit\s*:"#, 1_440),
        (#"Weekly\s*limit\s*:"#, weeklyWindowMinutes),
        (#"Monthly\s*credit\s*limit\s*:"#, monthlyWindowMinutes),
        (#"Monthly\s*limit\s*:"#, monthlyWindowMinutes),
        (#"Annual\s*limit\s*:"#, 525_600),
    ]

    /// Nil when no limit row was drawn at all — a signed-in account always has
    /// one of them, so their absence is a failure rather than an empty reading.
    static func parse(_ raw: String, now: Date) -> RateLimits? {
        let text = PanelText.normalize(raw)
        let windows = rows
            .compactMap { window(after: $0.label, in: text, minutes: $0.minutes, now: now) }
            .sorted { $0.windowMinutes < $1.windowMinutes }
        guard let primary = windows.first else { return nil }

        return RateLimits(
            primary: primary,
            secondary: windows.dropFirst().first,
            planType: plan(in: text),
            observedAt: now,
            // The panel points at chatgpt.com for a plan's *money*; a workspace
            // metered in credits states its budget right here.
            spend: credits(in: text)
        )
    }

    /// `5h limit: [████] 100% left (resets 03:59 on 19 Sep)`, or the credit
    /// row's `97% left (resets 07:00 on 1 Oct) 1,181 of 40,000 credits used`.
    private static func window(
        after label: String, in text: String, minutes: Int, now: Date
    ) -> RateLimitWindow? {
        guard let section = PanelText.tail(after: label, in: text).map(row),
              let used = usedPercent(in: section)
        else { return nil }

        return RateLimitWindow(
            usedPercent: min(100, max(0, used)),
            windowMinutes: minutes,
            resetsAt: resetDate(in: section, now: now)
                ?? now.addingTimeInterval(TimeInterval(minutes * 60))
        )
    }

    /// One row's own span. The render is a single flat string and `tail` takes a
    /// fixed 220 characters, so a row ends where the next one's label begins —
    /// otherwise the credit row's second line, `1,181 of 40,000 credits used`,
    /// is read as the figure for whatever row was drawn above it.
    private static func row(_ section: String) -> String {
        guard let next = section.range(of: #"limit\s*:"#, options: .regularExpression)
        else { return section }
        return String(section[..<next.lowerBound])
    }

    /// What the row says is gone, from the two figures it can say it with.
    ///
    /// A credit row prints both sides of the ratio — `1,181 of 40,000 credits
    /// used` — and they divide to a fraction of a point. `97% left` beside it is
    /// the same fact rounded to a whole one, and rounding a 40,000-credit budget
    /// to whole percent is 400 credits of slack. So the ratio wins wherever it
    /// is printed, and the percentage is what every other row has.
    private static func usedPercent(in section: String) -> Double? {
        if let credits = credits(in: section), let percent = credits.percent { return percent }
        return PanelText.firstCapture(#"([0-9]+(?:\.[0-9]+)?)\s*%\s*left"#, in: section)
            .flatMap(Double.init)
            .map { 100 - $0 }
    }

    /// `1,181 of 40,000 credits used` — a workspace's monthly budget, metered in
    /// credits rather than money.
    ///
    /// Carried as `Spend` because that is the same fact in a different unit: an
    /// amount used, a budget it is drawn from, and how far through it that is.
    /// `Money`'s currency is a code the panel printed, and `credits` is what
    /// this one printed. The `Thread usage: 0 credits` row underneath is this
    /// session's share, not a budget, and does not match.
    static func credits(in text: String) -> Spend? {
        guard let pair = PanelText.captures(
            #"([0-9][0-9,]*)\s*of\s*([0-9][0-9,]*)\s*credits\s*used"#, in: text
        ),
            let used = count(pair[0]), let limit = count(pair[1]), limit.amountMinor > 0
        else { return nil }

        return Spend(
            used: used,
            limit: limit,
            percent: Double(used.amountMinor) / Double(limit.amountMinor) * 100,
            isEnabled: true
        )
    }

    /// A whole count of credits, grouped as the panel grouped it.
    private static func count(_ raw: String) -> Money? {
        Int(raw.replacing(",", with: ""))
            .map { Money(amountMinor: $0, currency: Money.credits, exponent: 0) }
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
