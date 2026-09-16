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

/// Rate limits a CLI states outright. Codex publishes these; Claude does not,
/// which is why `CeilingEstimator` exists.
struct RateLimitWindow: Equatable, Sendable {
    let usedPercent: Double
    let windowMinutes: Int
    let resetsAt: Date

    /// Advance a window whose reset has already passed to the next one, carrying a
    /// freshly measured figure.
    ///
    /// Without this a reading goes stale the instant the window rolls over, and
    /// the app falls back to inference even though it knows the window just
    /// emptied. Skips whole periods, so being away for a day lands on the right one.
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
struct Money: Equatable, Sendable {
    var amountMinor: Int
    var currency: String
    var exponent: Int

    var amount: Decimal { Decimal(amountMinor) / pow(10, exponent) }
}

/// Pay-as-you-go spend past the plan's limits. Absent for accounts that never
/// enabled extra usage, which is most of them.
struct Spend: Equatable, Sendable {
    var used: Money
    var limit: Money?
    /// The endpoint's own figure; it disagrees with used/limit by a rounding step.
    var percent: Double?
    var isEnabled: Bool
}

struct RateLimits: Equatable, Sendable {
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
}
