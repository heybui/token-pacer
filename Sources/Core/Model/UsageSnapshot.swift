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
    /// A 5-hour window is open. True for hours at a time.
    var isActive: Bool = false
    /// Tokens are flowing *now* — the logs grew within `burningWindow`. This is
    /// what the activity dot follows; `isActive` stays true long after work stops.
    var isBurning: Bool = false
    /// When the authoritative figure was last confirmed. Between anchors the
    /// number on screen is that reading plus local token flow, not a fresh read.
    var confirmedAt: Date?
    var lastActivity: Date?
    var planType: String?
    /// Sparkline, splits and history. Only the pinned panel reads it.
    var panel: PanelData = .empty
    /// Nil unless the account buys usage past its plan.
    var spend: Spend?

    static func empty(_ source: SourceID) -> UsageSnapshot { UsageSnapshot(source: source) }
}

enum SnapshotBuilder {
    /// How recently the logs must have grown to count as still burning. Matched
    /// to the poll interval: the dot is lit by the tick that reads the line and
    /// goes out on the next quiet one.
    static let burningWindow: TimeInterval = 5

    /// Authoritative limits win when present and fresh; otherwise infer.
    static func build(
        source: SourceID,
        limits: RateLimits?,
        events: [UsageEvent],
        ceiling: Ceiling,
        at now: Date,
        weights: TokenWeights = .default,
        weightedPerPercent: Double? = nil
    ) -> UsageSnapshot {
        let windows = WindowCalculator.windows(from: events, weights: weights)
        let current = WindowCalculator.current(in: windows, at: now)

        var snapshot = UsageSnapshot(source: source)
        snapshot.sessionTokens = current?.counts.total ?? 0
        snapshot.isActive = current != nil
        snapshot.lastActivity = windows.last?.lastActivity
        snapshot.isBurning = snapshot.lastActivity
            .map { now.timeIntervalSince($0) < Self.burningWindow } ?? false
        snapshot.planType = limits?.planType
        snapshot.spend = limits?.spend.flatMap { $0.isEnabled ? $0 : nil }

        // A reading whose own window has already reset describes a window that no
        // longer exists; it is not "0% used", it is out of date.
        let primary = limits?.primary.flatMap { $0.resetsAt > now ? $0 : nil }
        if let primary {
            snapshot.origin = .authoritative
            snapshot.sessionPercent = primary.usedPercent
            snapshot.resetsAt = primary.resetsAt
            snapshot.confirmedAt = limits?.observedAt
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

        snapshot.panel = Aggregator.panel(
            events: events, window: current, at: now, weights: weights
        )

        // Burn is computed last so headroom agrees with the percentage on screen
        // and with the reset the user is reading next to it.
        snapshot.burn = BurnRateCalculator.rate(
            events: events, window: current, ceiling: ceiling, at: now, weights: weights,
            currentPercent: snapshot.sessionPercent,
            weightedPerPercent: weightedPerPercent,
            windowEndsAt: snapshot.resetsAt
        )
        return snapshot
    }
}
