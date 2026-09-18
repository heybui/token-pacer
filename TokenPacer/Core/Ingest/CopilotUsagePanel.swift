import Foundation

/// Reads Copilot's plan usage out of the CLI's own `/usage` panel.
///
/// This is what §0.5 of the plan said would reopen it: the desktop app's daemon
/// holds the allowance and will not hand it over, but `copilot` ships a TUI that
/// prints it — `Plan ████ 39% used 7,074 / 18,000 AIC`. The numerator was always
/// readable; the denominator is what the CLI added.
///
/// **One window, not two.** Copilot has no five-hour limit and no weekly one:
/// there is a plan budget, spent down over a billing month. So `primary` carries
/// the plan and `secondary` is nil — the app's "session window" is a shape this
/// provider does not have, and pretending otherwise would put a figure under a
/// heading that means something else.
struct CopilotUsagePanel: UsagePanel {
    var read: PanelReader

    func fetch(now: Date = Date()) async throws -> RateLimits {
        let text = try await read()
        guard let limits = Self.parse(text, now: now) else {
            throw PanelText.looksLikeSignIn(text) ? PanelError.notSignedIn : PanelError.unreadable
        }
        return limits
    }

    // MARK: - Parsing

    /// A billing month. Nothing in the panel says which day the budget renews on
    /// — that is the account's billing anniversary, which only GitHub knows.
    ///
    /// ponytail: month boundary as the reset, 30 days as the window. Both are
    /// approximations of a date this app cannot see; swap them the day the panel
    /// prints one.
    static let planWindowMinutes = 43_200

    static func parse(_ raw: String, now: Date, calendar: Calendar = .current) -> RateLimits? {
        let text = PanelText.normalize(raw)
        // Anchored on `Plan`: the same screen carries a session figure
        // (`AI Credits 0`, or `Requests 0 Premium` on legacy billing) that is
        // spend for this conversation, not against the budget.
        guard let section = PanelText.tail(after: #"Plan\b"#, in: text),
              let percent = PanelText.firstCapture(#"([0-9]+(?:\.[0-9]+)?)\s*%\s*used"#, in: section)
                .flatMap(Double.init)
        else { return nil }

        return RateLimits(
            primary: RateLimitWindow(
                usedPercent: min(100, max(0, percent)),
                windowMinutes: planWindowMinutes,
                resetsAt: monthBoundary(after: now, in: calendar)
            ),
            secondary: nil,
            planType: nil,
            observedAt: now,
            spend: budget(in: section)
        )
    }

    /// `39% used7,074 / 18,000 AIC` — the panel puts a cursor jump where the
    /// space between the label and the figure should be, so the pair is matched
    /// on its digits and its slash, never on whitespace.
    ///
    /// The unit is carried through as it is printed: `AIC` today, `premium
    /// requests` on the legacy billing platform. Credits are not money, but they
    /// are a used-of-limit pair with a name, which is exactly what `Spend` holds.
    private static func budget(in section: String) -> Spend? {
        let figure = #"([0-9][0-9,]*(?:\.[0-9]+)?)"#
        guard let parts = PanelText.groups(
            figure + #"\s*/\s*"# + figure + #"\s*([A-Za-z][A-Za-z ]{0,19})?"#, in: section
        ), let used = credits(parts[0], unit: parts[2]) else { return nil }

        return Spend(
            used: used, limit: credits(parts[1], unit: parts[2]),
            percent: nil, isEnabled: true
        )
    }

    private static func credits(_ digits: String, unit: String) -> Money? {
        guard let value = Double(digits.replacing(",", with: "")) else { return nil }
        let name = unit.trimmingCharacters(in: .whitespaces).uppercased()
        return Money(
            amountMinor: Int(value.rounded()),
            currency: name.isEmpty ? "AIC" : String(name.prefix(12)),
            exponent: 0
        )
    }

    /// Midnight on the first of next month, local.
    static func monthBoundary(after now: Date, in calendar: Calendar) -> Date {
        var components = calendar.dateComponents([.year, .month], from: now)
        components.day = 1
        components.hour = 0
        components.minute = 0
        components.second = 0
        guard let start = calendar.date(from: components),
              let next = calendar.date(byAdding: .month, value: 1, to: start)
        else { return now.addingTimeInterval(TimeInterval(planWindowMinutes * 60)) }
        return next
    }
}
