import Foundation

/// Consumption speed, and how long the window lasts at that speed.
struct BurnRate: Equatable, Sendable {
    /// Weighted tokens per hour over the trailing sample.
    let weightedPerHour: Double
    /// Percent of the window consumed per hour, or nil while the ceiling is unknown.
    let percentPerHour: Double?
    /// Minutes of headroom left at this rate, or nil when idle or unmeasurable.
    let headroomMinutes: Int?

    static let idle = BurnRate(weightedPerHour: 0, percentPerHour: nil, headroomMinutes: nil)
}

enum BurnRateCalculator {
    static let sample: TimeInterval = 30 * 60

    static func rate(
        events: [UsageEvent],
        window: SessionWindow?,
        ceiling: Ceiling,
        at now: Date,
        weights: TokenWeights = .default,
        sample: TimeInterval = sample
    ) -> BurnRate {
        let cutoff = now.addingTimeInterval(-sample)
        let recent = events.filter { $0.timestamp > cutoff && $0.timestamp <= now }
        guard !recent.isEmpty else { return .idle }

        let weighted = recent.reduce(0.0) { $0 + $1.counts.weighted(weights) }
        // Measure over the elapsed part of the sample, so a burst two minutes
        // after launch doesn't read as a whole quiet half hour.
        let elapsed = max(60, min(sample, now.timeIntervalSince(recent[0].timestamp)))
        let perHour = weighted / elapsed * 3600

        guard let ceilingTokens = ceiling.weightedTokens, ceilingTokens > 0, perHour > 0 else {
            return BurnRate(weightedPerHour: perHour, percentPerHour: nil, headroomMinutes: nil)
        }

        let used = window?.weighted ?? 0
        let remaining = max(0, ceilingTokens - used)
        return BurnRate(
            weightedPerHour: perHour,
            percentPerHour: perHour / ceilingTokens * 100,
            headroomMinutes: Int((remaining / perHour * 60).rounded())
        )
    }
}
