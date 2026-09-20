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

/// A provider that has just crossed one of the two marks and has not been looked
/// at yet.
///
/// The app used to hand this to macOS as a banner, which meant asking for
/// notification permission for a number the notch was already showing — and on a
/// Mac where that permission had been declined, the whole feature was silent with
/// nothing to say so. The pill raises it itself now: it is the one surface that
/// is always there, and it needs nobody's permission to change shape.
struct ZoneAlert: Equatable, Sendable {
    let source: SourceID
    /// The mark that was crossed, in the user's own numbers.
    let threshold: Double
    let percent: Double
    let resetsAt: Date?
    /// Over rather than watch — the difference between "keep an eye on this" and
    /// "finish what you are doing".
    let isOver: Bool
}
