import Foundation
import Observation

/// Polls every source on a timer and publishes a snapshot per source.
@MainActor
@Observable
final class UsageStore {
    private(set) var snapshots: [SourceID: UsageSnapshot] = [:]
    private(set) var lastError: String?
    var activeSource: SourceID = .claude

    var snapshot: UsageSnapshot? { snapshots[activeSource] }

    func eventCount(_ id: SourceID) -> Int { events[id]?.count ?? 0 }

    /// 5s poll on a timer rather than a file watcher: a 5-hour window does not
    /// need sub-second freshness, and watching ~/.claude/projects fires constantly.
    private let interval: TimeInterval
    private let sources: [any UsageSource]
    private let weights: TokenWeights
    private var events: [SourceID: [UsageEvent]] = [:]
    /// Exposed: an unconfident ceiling is why the pill shows raw tokens instead
    /// of a percentage.
    private(set) var ceilings: [SourceID: Ceiling] = [:]
    private var pump: Task<Void, Never>?

    /// Raw events are kept only long enough to serve the 30-day history.
    private static let retention: TimeInterval = 30 * 24 * 3600

    init(
        sources: [any UsageSource] = [ClaudeCodeSource(), CodexSource()],
        weights: TokenWeights = .default,
        interval: TimeInterval = 5
    ) {
        self.sources = sources
        self.weights = weights
        self.interval = interval
    }

    func start() {
        guard pump == nil else { return }
        pump = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                guard let interval = self?.interval else { return }
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    func stop() {
        pump?.cancel()
        pump = nil
    }

    func refresh(now: Date = Date()) async {
        for source in sources {
            do {
                let fresh = try await source.poll()
                var merged = events[source.id] ?? []
                merged.append(contentsOf: fresh.events)
                merged.removeAll { $0.timestamp < now.addingTimeInterval(-Self.retention) }
                merged.sort { $0.timestamp < $1.timestamp }
                events[source.id] = merged

                let windows = WindowCalculator.windows(from: merged, weights: weights)
                let ceiling = CeilingEstimator.estimate(
                    windows: windows, at: now, previous: ceilings[source.id] ?? .unknown
                )
                ceilings[source.id] = ceiling

                snapshots[source.id] = SnapshotBuilder.build(
                    source: source.id,
                    limits: fresh.limits,
                    events: merged,
                    ceiling: ceiling,
                    at: now,
                    weights: weights
                )
                lastError = nil
            } catch {
                // A missing log directory just means that CLI isn't installed.
                lastError = "\(source.id.rawValue): \(error.localizedDescription)"
            }
        }
    }
}
