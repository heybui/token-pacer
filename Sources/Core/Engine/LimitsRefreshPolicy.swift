import Foundation

/// Why a network call is worth making right now.
enum RefreshReason: Equatable, Sendable {
    case launch
    case wake
    /// The routine re-anchor, no sooner than `floor`.
    case scheduled
    /// The window just rolled over; one call re-anchors at the new baseline.
    case afterReset
    /// The extrapolation is about to cross a threshold the user gets alerted on.
    /// Worth confirming before firing: a false 90% warning is the worst failure.
    case confirmThreshold(Double)
}

/// Decides when to spend a request on an undocumented endpoint.
///
/// The 5s tick stays local. Utilization cannot move without local token events, so
/// an idle machine makes no calls at all; a heavy 8-hour day costs roughly
/// 8 × 60/10 ≈ 48 scheduled calls plus a handful of confirmations.
struct LimitsRefreshPolicy: Sendable {
    var floor: TimeInterval = 600          // 10 minutes between routine anchors
    var confirmFloor: TimeInterval = 120   // threshold checks may jump the queue
    var alertThresholds: [Double] = [75, 90]

    struct State: Sendable {
        var lastCallAt: Date?
        var lastConfirmedUtilization: Double?
        var hasNewActivity: Bool
        var estimate: Double?
        var anchorResetsAt: Date?
        var didLaunchFetch: Bool
        var didWake: Bool
    }

    func reason(at now: Date, state: State) -> RefreshReason? {
        if !state.didLaunchFetch { return .launch }
        if state.didWake { return .wake }

        let since = state.lastCallAt.map { now.timeIntervalSince($0) } ?? .infinity

        // A reset is a known, free event: the number changed without any tokens
        // being spent, so re-anchor even though nothing was logged.
        if let resetsAt = state.anchorResetsAt, now >= resetsAt, since >= confirmFloor {
            return .afterReset
        }

        // Everything below needs local evidence that the number could have moved.
        guard state.hasNewActivity else { return nil }

        if let crossed = crossedThreshold(state), since >= confirmFloor {
            return .confirmThreshold(crossed)
        }
        if since >= floor { return .scheduled }
        return nil
    }

    /// A threshold the extrapolation has reached but no anchor has confirmed.
    private func crossedThreshold(_ state: State) -> Double? {
        guard let estimate = state.estimate else { return nil }
        let confirmed = state.lastConfirmedUtilization ?? 0
        return alertThresholds
            .filter { estimate >= $0 && confirmed < $0 }
            .max()
    }
}
