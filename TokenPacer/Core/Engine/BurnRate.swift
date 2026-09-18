import Foundation

/// Consumption speed, and nothing projected from it.
///
/// How long the window lasts at this speed was the other half of this type. It
/// is gone with the inferred ceiling: turning tokens an hour into points an hour
/// needed a conversion that no provider publishes and this app no longer invents.
/// What is left is a measurement of what the logs actually recorded.
struct BurnRate: Equatable, Sendable {
    /// Weighted tokens per hour over the trailing sample.
    let weightedPerHour: Double

    static let idle = BurnRate(weightedPerHour: 0)
}

enum BurnRateCalculator {
    static let sample: TimeInterval = 30 * 60

    static func rate(
        events: [UsageEvent],
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
        return BurnRate(weightedPerHour: weighted / elapsed * 3600)
    }
}
