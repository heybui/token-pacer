import Foundation

/// One billed exchange, normalised across CLIs.
struct UsageEvent: Equatable, Sendable, Identifiable, Codable {
    /// Short keys: this is written 45,000 times over, and the field names would
    /// otherwise be most of the file.
    enum CodingKeys: String, CodingKey {
        case id = "i", source = "s", timestamp = "t", model = "m"
        case project = "p", sessionID = "n", counts = "c"
    }

    /// Dedupe key. Resumed sessions replay history into a new file, so the same
    /// exchange can appear in more than one log.
    let id: String
    let source: SourceID
    let timestamp: Date
    let model: String?
    /// Last path component of the working directory.
    let project: String?
    let sessionID: String?
    let counts: TokenCounts
}

/// Rate limits a provider states outright. Codex writes them into its rollout
/// logs; Claude states them only in its `/usage` panel. Nothing else is a source
/// of a percentage — an absent reading leaves the figure absent.
struct RateLimitWindow: Equatable, Sendable, Codable {
    let usedPercent: Double
    let windowMinutes: Int
    let resetsAt: Date

    /// Advance a window whose reset has already passed to the next one, carrying a
    /// freshly measured figure.
    ///
    /// Without this a reading goes stale the instant the window rolls over, and
    /// the app falls back to inference even though it knows the window just
    /// emptied. Skips whole periods, so being away for a day lands on the right one.
    /// The window itself, as the interval it covers.
    var span: DateInterval {
        DateInterval(
            start: resetsAt.addingTimeInterval(-Double(windowMinutes) * 60), end: resetsAt
        )
    }

    func rolled(to now: Date, usedPercent: Double) -> RateLimitWindow {
        guard resetsAt <= now, windowMinutes > 0 else {
            return RateLimitWindow(
                usedPercent: usedPercent, windowMinutes: windowMinutes, resetsAt: resetsAt
            )
        }
        let length = TimeInterval(windowMinutes * 60)
        let periods = (now.timeIntervalSince(resetsAt) / length).rounded(.down) + 1
        return RateLimitWindow(
            usedPercent: usedPercent,
            windowMinutes: windowMinutes,
            resetsAt: resetsAt.addingTimeInterval(periods * length)
        )
    }
}

/// An amount exactly as the endpoint states it: minor units plus the exponent to
/// shift by, in a named currency. `1199` with exponent 2 in SGD is S$11.99 —
/// reading the minor units as whole currency is a factor of 100 out, and the
/// currency is not always dollars.
struct Money: Equatable, Sendable, Codable {
    var amountMinor: Int
    var currency: String
    var exponent: Int

    var amount: Decimal { Decimal(amountMinor) / pow(10, exponent) }

    /// Not a currency, and named so nothing tries to convert it. A workspace on
    /// a credit budget is billed in credits and shown its budget in credits, so
    /// credits are the unit its figures already come in.
    static let credits = "credits"

    var isCredits: Bool { currency == Self.credits }
}

/// What the account is drawing down beyond its windows: pay-as-you-go spend past
/// the plan's limits, or — for a workspace metered in credits — the monthly
/// credit budget itself. Absent for accounts that have neither, which is most.
struct Spend: Equatable, Sendable, Codable {
    var used: Money
    var limit: Money?
    /// The endpoint's own figure; it disagrees with used/limit by a rounding step.
    var percent: Double?
    var isEnabled: Bool

    /// What the bar fills to: the stated figure when there is one, the pair's own
    /// division when there is not. A panel that prints `7,650 / 18,000` has said
    /// the share as plainly as a percentage would; the bar under it sat empty
    /// because only one of the three parsers happened to do the arithmetic.
    var share: Double? {
        if let percent { return percent }
        guard let limit, limit.amountMinor > 0, limit.exponent == used.exponent
        else { return nil }
        return Double(used.amountMinor) / Double(limit.amountMinor) * 100
    }
}

struct RateLimits: Equatable, Sendable, Codable {
    /// The short window — 300 minutes, the design's "5-hour".
    let primary: RateLimitWindow?
    /// The long window — 10080 minutes, the weekly cap.
    let secondary: RateLimitWindow?
    let planType: String?
    let observedAt: Date
    var spend: Spend?
}

struct SourceSnapshot: Sendable {
    let source: SourceID
    let events: [UsageEvent]
    /// Non-nil only for sources that publish their own limits.
    let limits: RateLimits?
    /// Sessions of this source with a turn in flight — the activity dot, the
    /// running border and the job badge, which are one fact.
    /// Zero from any source whose sessions are counted somewhere better: Claude
    /// Code registers its own, with a kind and a live pid, and a log cannot say
    /// either.
    var workingSessions: Int = 0
}
