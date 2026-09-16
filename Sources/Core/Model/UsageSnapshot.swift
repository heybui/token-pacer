import Foundation

/// Everything the UI binds to, for one source.
struct UsageSnapshot: Equatable, Sendable {
    /// Where the headline percentage came from. The UI is honest about this:
    /// an inferred number is an estimate and says so.
    enum Origin: Equatable, Sendable {
        /// The CLI published its own limits (Codex).
        case authoritative
        /// Computed against a ceiling learned from observed windows (Claude).
        case inferred
        /// Not enough history to infer a ceiling — show raw tokens, not a percentage.
        case unknown
    }

    var source: SourceID
    var origin: Origin = .unknown
    /// Nil while `origin == .unknown`.
    var sessionPercent: Double?
    var sessionTokens: Int = 0
    var resetsAt: Date?
    var weeklyPercent: Double?
    var weeklyResetsAt: Date?
    var burn: BurnRate = .idle
    var isActive: Bool = false
    var lastActivity: Date?
    var planType: String?

    static func empty(_ source: SourceID) -> UsageSnapshot { UsageSnapshot(source: source) }
}

enum SnapshotBuilder {
    /// Authoritative limits win when present and fresh; otherwise infer.
    static func build(
        source: SourceID,
        limits: RateLimits?,
        events: [UsageEvent],
        ceiling: Ceiling,
        at now: Date,
        weights: TokenWeights = .default
    ) -> UsageSnapshot {
        let windows = WindowCalculator.windows(from: events, weights: weights)
        let current = WindowCalculator.current(in: windows, at: now)
        let burn = BurnRateCalculator.rate(
            events: events, window: current, ceiling: ceiling, at: now, weights: weights
        )

        var snapshot = UsageSnapshot(source: source)
        snapshot.sessionTokens = current?.counts.total ?? 0
        snapshot.isActive = current != nil
        snapshot.lastActivity = windows.last?.lastActivity
        snapshot.burn = burn
        snapshot.planType = limits?.planType

        // A reading whose own window has already reset describes a window that no
        // longer exists; it is not "0% used", it is out of date.
        let primary = limits?.primary.flatMap { $0.resetsAt > now ? $0 : nil }
        if let primary {
            snapshot.origin = .authoritative
            snapshot.sessionPercent = primary.usedPercent
            snapshot.resetsAt = primary.resetsAt
        } else if let percent = current.flatMap({ ceiling.percent(of: $0.weighted) }) {
            snapshot.origin = .inferred
            snapshot.sessionPercent = percent
            snapshot.resetsAt = current?.end
        } else {
            snapshot.origin = .unknown
            snapshot.resetsAt = current?.end
        }

        if let secondary = limits?.secondary.flatMap({ $0.resetsAt > now ? $0 : nil }) {
            snapshot.weeklyPercent = secondary.usedPercent
            snapshot.weeklyResetsAt = secondary.resetsAt
        }
        return snapshot
    }
}
