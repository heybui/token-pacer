import Foundation

/// Reads Copilot's plan quota out of `account.getQuota`, the CLI's own JSON-RPC
/// face.
///
/// This replaces parsing the `/usage` TUI — `Plan ████ 39% used 7,074 / 18,000
/// AIC` read back off a pseudo-terminal. The screen was never the fact; it was a
/// picture of one, and 1.0.86 put a folder-trust dialog in front of it that ate
/// the typed command. `CopilotAppServer` asks the same binary the same question
/// in a second and gets numbers: used of entitlement, the percentage remaining,
/// whether the entitlement is unlimited at all.
///
/// **One window, not two.** Copilot has no five-hour limit and no weekly one:
/// there is a plan budget, spent down over a billing month. So `primary` carries
/// the plan and `secondary` is nil — the app's "session window" is a shape this
/// provider does not have, and pretending otherwise would put a figure under a
/// heading that means something else.
struct CopilotUsagePanel: UsagePanel {
    var read: PanelReader

    func fetch(now: Date = Date.now) async throws -> RateLimits {
        let text = try await read()
        guard let limits = Self.parse(text, now: now) else {
            throw PanelText.looksLikeSignIn(text) ? PanelError.notSignedIn : PanelError.unreadable
        }
        return limits
    }

    // MARK: - Parsing

    /// A billing month. The reply states no window length — a quota that refills
    /// monthly has nothing shorter to declare.
    static let planWindowMinutes = 43_200

    /// Nil when no quota in the reply has one: an error object where a result
    /// should be, a release that moved the field, or an account whose every
    /// quota is unmetered. The first two are failures; the third has no figure
    /// to show either way.
    static func parse(_ raw: String, now: Date, calendar: Calendar = .current) -> RateLimits? {
        guard let message = try? JSONDecoder().decode(Message.self, from: Data(raw.utf8)),
              let metered = message.result?.metered
        else { return nil }

        return RateLimits(
            primary: metered.window(now: now, calendar: calendar),
            secondary: nil,
            planType: nil,
            observedAt: now,
            spend: metered.spend
        )
    }

    /// Midnight on the first of next month, local.
    ///
    /// ponytail: month boundary as the reset. Nothing in the reply gives the
    /// account's billing anniversary — `resetDate` states the moment the quota
    /// was *read*, not the moment it refills, and was within a second of `now`
    /// on every reply this was written against. Swap this the day that field
    /// starts pointing forward; `window(now:calendar:)` already prefers it when
    /// it does.
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

    /// One `account.getQuota` reply, result envelope and all.
    private struct Message: Decodable {
        let result: Result?

        struct Result: Decodable {
            /// Keyed by quota type: `premium_interactions`, `chat`,
            /// `completions`.
            let quotaSnapshots: [String: Quota]

            /// The one quota that is actually metered.
            ///
            /// Which key that is depends on how the account is billed, and both
            /// shapes are live: an account on AI credits carries its allowance
            /// on `chat` (200 AIC), while a premium-request plan carries it on
            /// `premium_interactions`. Asking each in turn is what keeps one
            /// parser for both, and an unlimited entitlement is not a budget —
            /// it has nothing to fill a bar with.
            ///
            /// A granted entitlement is the test, not `hasQuota`. That flag does
            /// not mean "metered": a business seat comes back with 18,000
            /// premium requests granted, 7,686 of them spent, and
            /// `hasQuota: false` — while its `chat` and `completions` are
            /// unlimited. Believing the flag left that account with no quota to
            /// read at all and the panel reporting itself unreadable.
            var metered: Quota? {
                ["premium_interactions", "chat", "completions"]
                    .lazy
                    .compactMap { quotaSnapshots[$0] }
                    .first { $0.isUnlimitedEntitlement != true && ($0.entitlementRequests ?? 0) > 0 }
            }
        }

        /// One quota's snapshot. `overage` and `usageAllowedWithExhaustedQuota`
        /// are not decoded: the app has no row for what happens past the cap.
        struct Quota: Decodable {
            let entitlementRequests: Double?
            let usedRequests: Double?
            let remainingPercentage: Double?
            let isUnlimitedEntitlement: Bool?
            let hasQuota: Bool?
            /// True on an account metered in AI credits rather than in requests,
            /// which is the only thing that names the unit.
            let tokenBasedBilling: Bool?
            /// Documented as the reset; see `monthBoundary(after:in:)`.
            let resetDate: String?

            /// How far through the entitlement the account is.
            ///
            /// The wire's own `remainingPercentage` wins over the pair's
            /// division: it is the figure Copilot reports to itself, and being
            /// right about 89.6 against a source that says 90 is not worth
            /// showing a different tone for.
            private var usedPercent: Double? {
                if let remaining = remainingPercentage {
                    return 100 - min(100, max(0, remaining))
                }
                guard let entitlementRequests, entitlementRequests > 0, let usedRequests
                else { return nil }
                return min(100, max(0, usedRequests / entitlementRequests * 100))
            }

            func window(now: Date, calendar: Calendar) -> RateLimitWindow? {
                guard let usedPercent else { return nil }
                // Only a reset that is still ahead is a reset. Today's reading
                // states one a second in the past, and a window that closed
                // before it was read counts down from nothing.
                let stated = resetDate.flatMap(ISO8601.parse).flatMap { $0 > now ? $0 : nil }
                return RateLimitWindow(
                    usedPercent: usedPercent,
                    windowMinutes: planWindowMinutes,
                    resetsAt: stated ?? CopilotUsagePanel.monthBoundary(after: now, in: calendar)
                )
            }

            /// The entitlement as a budget drawn down: requests used out of
            /// requests granted. Credits are not money, but they are a
            /// used-of-limit pair with a name, which is exactly what `Spend`
            /// holds.
            var spend: Spend? {
                guard let usedRequests else { return nil }
                let unit = tokenBasedBilling == true ? "AIC" : "REQUESTS"
                return Spend(
                    used: Money(amountMinor: Int(usedRequests.rounded()), currency: unit, exponent: 0),
                    limit: entitlementRequests.map {
                        Money(amountMinor: Int($0.rounded()), currency: unit, exponent: 0)
                    },
                    percent: usedPercent,
                    isEnabled: true
                )
            }
        }
    }
}
