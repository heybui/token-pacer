import Foundation

/// How much a window can hold before it's spent.
///
/// Claude publishes no limit, so the ceiling is inferred from the largest
/// *completed* window ever observed — the same trick ccusage uses. Until one
/// full window has gone by there is no honest percentage to show, and the UI
/// falls back to raw tokens.
struct Ceiling: Equatable, Sendable, Codable {
    var weightedTokens: Double?
    var observedWindows: Int

    static let unknown = Ceiling(weightedTokens: nil, observedWindows: 0)

    var isConfident: Bool { weightedTokens != nil && observedWindows > 0 }

    /// Percentage of the ceiling consumed, or nil while the ceiling is unknown.
    func percent(of weighted: Double) -> Double? {
        guard let ceiling = weightedTokens, ceiling > 0 else { return nil }
        return min(100, weighted / ceiling * 100)
    }
}

enum CeilingEstimator {
    /// Only completed windows count: the live one is still filling and would
    /// drag the ceiling up on every tick.
    static func estimate(
        windows: [SessionWindow],
        at now: Date,
        previous: Ceiling = .unknown
    ) -> Ceiling {
        let completed = windows.filter { !$0.isActive(at: now) }
        let peak = completed.map(\.weighted).max()

        let candidates = [peak, previous.weightedTokens].compactMap(\.self)
        return Ceiling(
            weightedTokens: candidates.max(),
            observedWindows: max(previous.observedWindows, completed.count)
        )
    }
}
