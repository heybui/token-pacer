import Foundation

/// Holds the live-limits state for one source and answers the only two questions
/// that matter: what is the number right now, and is a request worth making.
///
/// Activity gating lives here. `weightedSinceAnchor` is the evidence: it only
/// grows when local logs record tokens, so an idle machine can never satisfy the
/// policy and never issues a request.
struct LiveLimitsTracker: Sendable, Codable {
    /// `weightedSinceAnchor` is deliberately not archived: on a cold start the
    /// sources replay every retained event, so the count is rebuilt from the logs
    /// that land after the anchor rather than carried over and counted twice.
    /// `policy` is configuration, not state.
    enum CodingKeys: String, CodingKey {
        case anchor, calibration, lastCallAt, lastConfirmed, consecutiveFailures
    }

    private(set) var anchor: LimitsAnchor?
    private(set) var calibration = LimitsCalibration()
    /// Weighted tokens logged since the anchor. Doubles as the activity signal and
    /// as the input to both calibration and extrapolation.
    private(set) var weightedSinceAnchor: Double = 0
    private(set) var lastCallAt: Date?
    private(set) var lastConfirmed: Double?
    private(set) var consecutiveFailures = 0

    var policy = LimitsRefreshPolicy()

    var hasNewActivity: Bool { weightedSinceAnchor > 0 }

    /// New local usage. The only thing that can make a request worthwhile.
    mutating func record(weighted: Double) {
        guard weighted > 0 else { return }
        weightedSinceAnchor += weighted
    }

    /// A successful reading. Calibrates against the previous anchor before
    /// replacing it, since the tokens in between are what measure the conversion.
    mutating func anchored(_ new: LimitsAnchor, at now: Date) {
        if let previous = anchor {
            calibration.observe(from: previous, to: new, weightedBetween: weightedSinceAnchor)
        }
        anchor = new
        weightedSinceAnchor = 0
        lastCallAt = now
        lastConfirmed = new.utilization
        consecutiveFailures = 0
    }

    /// A failed reading. The attempt still counts, so a broken endpoint is not
    /// retried every tick, and each failure pushes the next attempt further out.
    mutating func failed(at now: Date) {
        lastCallAt = now
        consecutiveFailures += 1
    }

    /// Nil when no request is warranted — including whenever the machine is idle.
    func refreshReason(at now: Date) -> RefreshReason? {
        var gated = policy
        gated.floor = backoffFloor
        gated.confirmFloor = max(policy.confirmFloor, backoffFloor == policy.floor ? policy.confirmFloor : backoffFloor)

        return gated.reason(at: now, state: .init(
            lastCallAt: lastCallAt,
            lastConfirmedUtilization: lastConfirmed,
            hasNewActivity: hasNewActivity,
            estimate: utilization(at: now),
            didLaunchFetch: lastCallAt != nil,
            didWake: false
        ))
    }

    /// Exponential backoff, capped, so a persistently failing endpoint is polled
    /// rarely rather than on every eligible tick.
    private var backoffFloor: TimeInterval {
        guard consecutiveFailures > 0 else { return policy.floor }
        let multiplier = pow(2.0, Double(min(consecutiveFailures, 5)))
        return min(policy.floor * multiplier, 3600)
    }

    /// The figure to display: extrapolated from the anchor when calibrated,
    /// the raw anchor otherwise, nil when nothing has ever been read.
    func utilization(at now: Date) -> Double? {
        guard let anchor else { return nil }
        if let extrapolated = calibration.extrapolate(
            from: anchor, weightedSince: weightedSinceAnchor, at: now
        ) { return extrapolated }

        // Past the reset the window is empty. That needs no calibration — and it
        // is a far better answer than falling back to a ceiling guessed from log
        // volume. Any work done since re-anchors on the next poll anyway.
        return calibration.hasReset(anchor, at: now) ? 0 : anchor.utilization
    }
}
