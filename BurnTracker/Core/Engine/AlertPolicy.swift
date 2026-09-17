import Foundation

/// Decides when a threshold crossing is worth interrupting someone over.
///
/// Pure and injectable, because the rule is all edge cases: a percentage that
/// hovers either side of 75 must alert once, not eleven times, and the same
/// window must never alert twice — but the next window has to alert again.
struct AlertPolicy: Sendable {
    /// The window each threshold last fired in, identified by its reset time.
    private var firedAt: [Double: Date] = [:]
    /// The last figure seen, so a crossing can be told from a standing figure.
    private var lastPercent: Double?
    /// Which window that figure belonged to.
    private var lastResetsAt: Date?

    /// The highest threshold crossed since the last call, or nil for silence.
    ///
    /// Only upward movement counts, and only once per window per threshold.
    mutating func crossing(
        percent: Double?, resetsAt: Date?, thresholds: [Double]
    ) -> Double? {
        guard let percent, let resetsAt else { return nil }

        // A window that has rolled over clears its history: the new one is
        // allowed to alert again at the same marks. The previous figure goes with
        // it — 85% of a window that no longer exists must not suppress 80% of
        // this one.
        if lastResetsAt != resetsAt {
            firedAt.removeAll()
            lastPercent = nil
            lastResetsAt = resetsAt
        }
        defer { lastPercent = percent }

        // Highest first: crossing 90 in one jump should say "wrap up", not "warm".
        for threshold in thresholds.sorted(by: >) {
            guard percent >= threshold, firedAt[threshold] == nil else { continue }
            // A first reading that is already past the mark counts — the app may
            // have launched mid-window — but a figure that has not moved does not.
            guard lastPercent.map({ $0 < threshold }) ?? true else { continue }
            firedAt[threshold] = resetsAt
            return threshold
        }
        return nil
    }
}
