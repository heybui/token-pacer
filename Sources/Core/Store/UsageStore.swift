import Foundation
import Observation

/// Polls every source on a timer and publishes a snapshot per source.
@MainActor
@Observable
final class UsageStore {
    private(set) var snapshots: [SourceID: UsageSnapshot] = [:]
    /// Keyed by source: a healthy source must not erase a broken one's error.
    private(set) var errors: [SourceID: String] = [:]
    var activeSource: SourceID = .claude

    var snapshot: UsageSnapshot? { snapshots[activeSource] }

    func eventCount(_ id: SourceID) -> Int { events[id]?.count ?? 0 }

    /// 5s poll on a timer rather than a file watcher: a 5-hour window does not
    /// need sub-second freshness, and watching ~/.claude/projects fires constantly.
    private let interval: TimeInterval
    private let sources: [any UsageSource]
    private let weights: TokenWeights
    private var events: [SourceID: [UsageEvent]] = [:]
    /// Live limits state per source. Only Claude needs it; Codex states its own
    /// limits in its logs, so it never issues a request.
    private var trackers: [SourceID: LiveLimitsTracker] = [:]
    private var liveLimits: [SourceID: RateLimits] = [:]
    /// Sources whose limits endpoint returned something retrying cannot fix.
    private var limitsDisabled: Set<SourceID> = []
    /// Exposed: an unconfident ceiling is why the pill shows raw tokens instead
    /// of a percentage.
    private(set) var ceilings: [SourceID: Ceiling] = [:]
    private var pump: Task<Void, Never>?

    /// Raw events are kept only long enough to serve the 30-day history.
    private static let retention: TimeInterval = 30 * 24 * 3600

    /// `usageAPI` is injected rather than defaulted: it is backed by the Keychain,
    /// which lives outside Core.
    private let usageAPI: ClaudeUsageAPI?

    init(
        sources: [any UsageSource] = [ClaudeCodeSource(), CodexSource()],
        weights: TokenWeights = .default,
        interval: TimeInterval = 5,
        usageAPI: ClaudeUsageAPI? = nil
    ) {
        self.sources = sources
        self.weights = weights
        self.interval = interval
        self.usageAPI = usageAPI
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

    /// Debug hook: `BURNTRACKER_SIMULATE_ERROR=1` forces the attention state so the
    /// degraded UI can be checked without waiting for a real failure.
    private static var simulatedError: String? {
        ProcessInfo.processInfo.environment["BURNTRACKER_SIMULATE_ERROR"].map {
            $0 == "1" ? "usage request failed" : $0
        }
    }

    func refresh(now: Date = Date()) async {
        if let simulated = Self.simulatedError {
            for id in SourceID.allCases { errors[id] = simulated }
        }
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

                await refreshLimits(
                    for: source.id,
                    weightedDelta: fresh.events.reduce(0) { $0 + $1.counts.weighted(weights) },
                    now: now
                )

                snapshots[source.id] = SnapshotBuilder.build(
                    source: source.id,
                    // A source that states its own limits wins; otherwise use what
                    // the endpoint anchored, extrapolated to now.
                    limits: fresh.limits ?? currentLimits(for: source.id, at: now),
                    events: merged,
                    ceiling: ceiling,
                    at: now,
                    weights: weights
                )
                errors[source.id] = Self.simulatedError
            } catch {
                // A missing log directory just means that CLI isn't installed.
                errors[source.id] = error.localizedDescription
            }
        }
    }

    /// Asks the usage endpoint only when the tracker says it is worth it.
    private func refreshLimits(for id: SourceID, weightedDelta: Double, now: Date) async {
        guard id == .claude, !limitsDisabled.contains(id), let usageAPI else { return }

        var tracker = trackers[id] ?? LiveLimitsTracker()
        tracker.record(weighted: weightedDelta)
        defer { trackers[id] = tracker }

        guard tracker.refreshReason(at: now) != nil else { return }

        do {
            let response = try await usageAPI.fetch()
            guard let anchor = response.anchor(observedAt: now) else {
                // `{}` means this account has nothing to report — an API key, or a
                // token without `user:profile`. Stop asking; inference takes over.
                limitsDisabled.insert(id)
                return
            }
            tracker.anchored(anchor, at: now)
            liveLimits[id] = response.rateLimits(observedAt: now)
            errors[id] = Self.simulatedError
        } catch {
            tracker.failed(at: now)
            let failure = error as? UsageAPIError
            if failure?.isFatal == true { limitsDisabled.insert(id) }
            errors[id] = failure?.message ?? error.localizedDescription
        }
    }

    /// The anchored limits with the session figure extrapolated to now, so the
    /// pill keeps moving between requests.
    private func currentLimits(for id: SourceID, at now: Date) -> RateLimits? {
        guard let anchored = liveLimits[id] else { return nil }
        guard let tracker = trackers[id], let live = tracker.utilization(at: now),
              let primary = anchored.primary
        else { return anchored }

        return RateLimits(
            primary: RateLimitWindow(
                usedPercent: live,
                windowMinutes: primary.windowMinutes,
                resetsAt: primary.resetsAt
            ),
            secondary: anchored.secondary,
            planType: anchored.planType,
            observedAt: anchored.observedAt
        )
    }
}
