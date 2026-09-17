import Foundation

/// A reading straight from the usage endpoint.
struct LimitsAnchor: Equatable, Sendable, Codable {
    let utilization: Double     // 0–100, as published
    let observedAt: Date
    let resetsAt: Date?
}

/// Learns how many weighted tokens make up one percentage point, by comparing
/// consecutive anchors against what the local logs recorded in between.
///
/// This is the number `CeilingEstimator` tries to guess from log volume alone.
/// With anchors it stops being a guess: two readings and the tokens between them
/// measure it directly.
struct LimitsCalibration: Equatable, Sendable, Codable {
    /// `smoothing` is a constant of the algorithm, not state: it must come from
    /// the code that is running, never from a file an older build wrote.
    enum CodingKeys: String, CodingKey { case weightedPerPercent, samples }

    private(set) var weightedPerPercent: Double?
    private(set) var samples: Int = 0

    /// Newer samples matter more — plan changes and model mix move this.
    private let smoothing = 0.3

    var isCalibrated: Bool { weightedPerPercent != nil }

    /// Feed two consecutive anchors and the weighted tokens logged between them.
    mutating func observe(from previous: LimitsAnchor, to current: LimitsAnchor, weightedBetween: Double) {
        let delta = current.utilization - previous.utilization

        // A drop means the window reset in between; the pair measures nothing.
        // Flat or no local usage is equally uninformative.
        guard delta > 0, weightedBetween > 0 else { return }

        let sample = weightedBetween / delta
        weightedPerPercent = weightedPerPercent.map { $0 + smoothing * (sample - $0) } ?? sample
        samples += 1
    }

    /// Utilization now, extrapolated from the last anchor using local token flow.
    ///
    /// Returns nil until calibrated, so the UI shows the anchor itself rather than
    /// a number built on an unknown conversion.
    func extrapolate(from anchor: LimitsAnchor, weightedSince: Double, at now: Date) -> Double? {
        guard let perPercent = weightedPerPercent, perPercent > 0 else { return nil }

        // Past the reset the anchor describes a window that no longer exists, so
        // the count starts from zero rather than from the old reading.
        let base = hasReset(anchor, at: now) ? 0 : anchor.utilization
        return min(100, max(0, base + weightedSince / perPercent))
    }

    func hasReset(_ anchor: LimitsAnchor, at now: Date) -> Bool {
        guard let resetsAt = anchor.resetsAt else { return false }
        return now >= resetsAt
    }
}
