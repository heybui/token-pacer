import Foundation

/// Everything the UI binds to, for one source.
struct UsageSnapshot: Equatable, Sendable {
    var source: SourceID
    /// The provider's own figure, or nil. There is no third state: a percentage
    /// this app worked out for itself is one the provider never agreed to.
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
    /// Is anything happening *right now*?
    ///
    /// Token records are written when an exchange completes, so they answer
    /// "was anything happening a moment ago". While the model is thinking — the
    /// stretch where a still dot is most misleading — nothing is logged at all,
    /// and the answer has to come from the shape of the newest line instead.
    static func isBurning(activity: LogActivity?, lastEvent: Date?, at now: Date) -> Bool {
        if let activity, activity.isAwaitingResponse {
            return now.timeIntervalSince(activity.lastLineAt) < inFlightWindow
        }
        let newest = [activity?.lastLineAt, lastEvent].compactMap(\.self).max()
        return newest.map { now.timeIntervalSince($0) < burningWindow } ?? false
    }

    /// How recently the logs must have grown to count as still burning, once a
    /// turn has finished. Two polls plus slack, not one: a line written just
    /// before a tick is already older than a 5s window by the next one, so the
    /// dot blinked off between beats of work it should have sat through.
    static let burningWindow: TimeInterval = 12

    /// A turn in flight keeps the dot lit without any tokens being logged — the
    /// record only lands when the exchange completes. Capped, because a crashed
    /// CLI leaves its last line looking like a turn that never ended.
    static let inFlightWindow: TimeInterval = 15 * 60

    /// The provider's own limits when they are present and fresh; otherwise the
    /// percentage is simply absent.
    static func build(
        source: SourceID,
        limits: RateLimits?,
        events: [UsageEvent],
        activity: LogActivity? = nil,
        at now: Date,
        weights: TokenWeights = .default,
        panelMovedAt: Date? = nil,
        panel: PanelData? = nil,
        windows: [SessionWindow]? = nil
    ) -> UsageSnapshot {
        // Handed in when the caller already has them: walking every retained
        // event twice a tick for the same answer is the poll's largest avoidable
        // cost.
        let windows = windows ?? WindowCalculator.windows(from: events, weights: weights)
        let current = WindowCalculator.current(in: windows, at: now)

        var snapshot = UsageSnapshot(source: source)
        snapshot.sessionTokens = current?.counts.total ?? 0
        snapshot.isActive = current != nil
        // Burning is asked of the logs alone. A panel reading proves work happened
        // somewhere in the last half hour, not that tokens are flowing this second,
        // and the ring claims the second.
        let logged = windows.last?.lastActivity
        snapshot.isBurning = Self.isBurning(activity: activity, lastEvent: logged, at: now)
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
            snapshot.confirmedAt = limits?.observedAt
        } else {
            // No reading, so no percentage — the window's own end is still worth
            // having, since it comes from the logs rather than from a limit.
            snapshot.resetsAt = current?.end
        }

        if let secondary = limits?.secondary.flatMap({ $0.resetsAt > now ? $0 : nil }) {
            snapshot.weeklyPercent = secondary.usedPercent
            snapshot.weeklyResetsAt = secondary.resetsAt
        }

        // Handed in when the caller still has a recent one. Aggregating it walks
        // every retained event — thirty days of them — and it feeds the pinned
        // panel alone, which is shut almost always. On the 5s tick it was the
        // most expensive thing the app did, and it grew with the history.
        snapshot.panel = panel ?? Aggregator.panel(
            events: events, window: current, at: now, weights: weights
        )

        snapshot.burn = BurnRateCalculator.rate(events: events, at: now, weights: weights)
        return snapshot
    }
}
