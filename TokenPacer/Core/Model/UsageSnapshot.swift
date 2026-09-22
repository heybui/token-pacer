import Foundation

/// Everything the UI binds to, for one source.
struct UsageSnapshot: Equatable, Sendable {
    var source: SourceID
    /// The provider's own figure, or nil. There is no third state: a percentage
    /// this app worked out for itself is one the provider never agreed to.
    var sessionPercent: Double?
    var sessionTokens: Int = 0
    var resetsAt: Date?
    /// How long the window behind `sessionPercent` runs. Not always five hours:
    /// a workspace metered in credits reports a month and nothing shorter, and
    /// every caption that names the window reads this rather than assuming.
    var windowMinutes: Int?
    var weeklyPercent: Double?
    var weeklyResetsAt: Date?
    /// The same, for the longer window under the dot. Usually a week.
    var weeklyWindowMinutes: Int?
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
    /// How long a session may claim to be working without saying so again.
    ///
    /// A CLI killed mid-turn leaves its last word looking like work that never
    /// finished; a registry entry for a session that died leaves the same. Every
    /// provider's count is capped by this, so nothing pulses for the rest of the
    /// day on the strength of a file nobody is writing to any more.
    static let inFlightWindow: TimeInterval = 15 * 60

    /// The span the splits cover for a provider that has a five-hour window:
    /// its own when it states one, and the log's when it does not. A workspace
    /// on a credit budget has a month up in the headline, so all three columns
    /// read "no open window" for days at a time under a figure that was plainly
    /// moving — which is why the provider's own window is preferred.
    static let defaultSplitSpan: @Sendable (RateLimitWindow?, SessionWindow?) -> DateInterval? = {
        provider, logged in
        provider?.span ?? logged.map { DateInterval(start: $0.start, end: $0.end) }
    }

    /// The provider's own limits when they are present and fresh; otherwise the
    /// percentage is simply absent.
    static func build(
        source: SourceID,
        limits: RateLimits?,
        events: [UsageEvent],
        /// Sessions of this provider with a model answering right now. The dot,
        /// the running border and the badge are one fact told three ways, so
        /// they are one number.
        working: Int = 0,
        at now: Date,
        weights: TokenWeights = .default,
        panelMovedAt: Date? = nil,
        panel: PanelData? = nil,
        windows: [SessionWindow]? = nil,
        /// Which span the splits describe, given the provider's own window and
        /// the one the logs imply. Supplied by the provider, because the answer
        /// when there is no provider window is not the same for all of them.
        splitSpan: @Sendable (RateLimitWindow?, SessionWindow?) -> DateInterval? = Self.defaultSplitSpan
    ) -> UsageSnapshot {
        // Handed in when the caller already has them: walking every retained
        // event twice a tick for the same answer is the poll's largest avoidable
        // cost.
        let windows = windows ?? WindowCalculator.windows(from: events, weights: weights)
        let current = WindowCalculator.current(in: windows, at: now)

        var snapshot = UsageSnapshot(source: source)
        snapshot.sessionTokens = current?.counts.total ?? 0
        snapshot.isActive = current != nil
        // A job is running or it is not. This used to be inferred from how
        // recently a log line had landed, which pulsed at bookkeeping written
        // after a finished turn and went dark in the middle of a long one — the
        // dot blinked at a machine where nothing was running at all. Every
        // provider now says outright how many sessions are answering.
        let logged = windows.last?.lastActivity
        snapshot.isBurning = working > 0
        // Dormancy is asked of both. Web and Claude Design write nothing here, so
        // on the logs alone the pill withdrew mid-session and took a climbing
        // figure with it — the one moment it exists to be on screen for.
        snapshot.lastActivity = [logged, panelMovedAt].compactMap(\.self).max()
        snapshot.planType = limits?.planType
        snapshot.spend = limits?.spend.flatMap { $0.isEnabled ? $0 : nil }

        // A reading whose own window has already reset describes a window that no
        // longer exists; it is not "0% used", it is out of date.
        let primary = limits?.primary.flatMap { $0.resetsAt > now ? $0 : nil }
        if let primary {
            snapshot.sessionPercent = primary.usedPercent
            snapshot.resetsAt = primary.resetsAt
            snapshot.windowMinutes = primary.windowMinutes
            snapshot.confirmedAt = limits?.observedAt
        } else {
            // No reading, so no percentage — the window's own end is still worth
            // having, since it comes from the logs rather than from a limit.
            snapshot.resetsAt = current?.end
        }

        if let secondary = limits?.secondary.flatMap({ $0.resetsAt > now ? $0 : nil }) {
            snapshot.weeklyPercent = secondary.usedPercent
            snapshot.weeklyResetsAt = secondary.resetsAt
            snapshot.weeklyWindowMinutes = secondary.windowMinutes
        }

        let splitSpan = splitSpan(primary, current)

        // Handed in when the caller still has a recent one. Aggregating it walks
        // every retained event — thirty days of them — and it feeds the pinned
        // panel alone, which is shut almost always. On the 5s tick it was the
        // most expensive thing the app did, and it grew with the history.
        snapshot.panel = panel ?? Aggregator.panel(
            events: events, window: splitSpan, at: now, weights: weights
        )

        return snapshot
    }
}
