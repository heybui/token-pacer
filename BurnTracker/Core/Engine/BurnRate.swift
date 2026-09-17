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

    /// How far a rate measured over `sample` may be projected.
    ///
    /// Four times the sample. Past that the figure is arithmetic rather than
    /// information: at 0.3% used it reported 269 minutes — a half-hour burst
    /// extrapolated across nearly the whole window, which no session sustains.
    /// Headroom is for the stretch where it changes what you do next.
    static let horizon: TimeInterval = 4 * sample

    /// - Parameters:
    ///   - currentPercent: the figure actually on screen, authoritative when the
    ///     panel supplied it. Headroom must agree with what the user is reading.
    ///   - windowEndsAt: headroom can never outlast the window; at reset it refills.
    static func rate(
        events: [UsageEvent],
        window: SessionWindow?,
        ceiling: Ceiling,
        at now: Date,
        weights: TokenWeights = .default,
        sample: TimeInterval = sample,
        currentPercent: Double? = nil,
        windowEndsAt: Date? = nil
    ) -> BurnRate {
        let cutoff = now.addingTimeInterval(-sample)
        let recent = events.filter { $0.timestamp > cutoff && $0.timestamp <= now }
        guard !recent.isEmpty else { return .idle }

        let weighted = recent.reduce(0.0) { $0 + $1.counts.weighted(weights) }
        // Measure over the elapsed part of the sample, so a burst two minutes
        // after launch doesn't read as a whole quiet half hour.
        let elapsed = max(60, min(sample, now.timeIntervalSince(recent[0].timestamp)))
        let perHour = weighted / elapsed * 3600

        // Inferred from log volume, and that is the only conversion there is: the
        // panel states percentages as whole numbers, never how many tokens made one.
        guard let perPercent = ceiling.weightedTokens.map({ $0 / 100 }),
              perPercent > 0, perHour > 0
        else {
            return BurnRate(weightedPerHour: perHour, percentPerHour: nil, headroomMinutes: nil)
        }

        let percentPerHour = perHour / perPercent
        let used = currentPercent ?? ceiling.percent(of: window?.weighted ?? 0) ?? 0
        let remainingPercent = max(0, 100 - used)
        let minutesToEmpty = remainingPercent / percentPerHour * 60

        // Past the reset the window refills, so "you run out in N minutes" is only
        // true while N fits inside the window. Otherwise there is no headroom
        // figure to give — you simply do not run out this time.
        let ceilingOnAnswer = min(horizon / 60, windowEndsAt.map { $0.timeIntervalSince(now) / 60 } ?? .infinity)
        guard minutesToEmpty < ceilingOnAnswer else {
            return BurnRate(
                weightedPerHour: perHour, percentPerHour: percentPerHour, headroomMinutes: nil
            )
        }

        return BurnRate(
            weightedPerHour: perHour,
            percentPerHour: percentPerHour,
            headroomMinutes: Int(minutesToEmpty.rounded())
        )
    }
}
