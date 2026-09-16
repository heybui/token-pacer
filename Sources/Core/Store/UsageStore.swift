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
    /// Which CLI the tokens went through, across every source. The per-source
    /// splits live on the snapshot; this one is the only figure that needs all
    /// of them at once.
    private(set) var bySource: [UsageSplit] = []
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
                    weights: weights,
                    weightedPerPercent: trackers[source.id]?.calibration.weightedPerPercent
                )
                errors[source.id] = Self.simulatedError
            } catch {
                // A missing log directory just means that CLI isn't installed.
                errors[source.id] = error.localizedDescription
            }
        }

        // One 5-hour slice across sources: their windows start independently, so
        // the clock is the only span both can be measured over.
        let recent = events.values.flatMap { $0 }
            .filter { $0.timestamp > now.addingTimeInterval(-5 * 3600) }
        bySource = Aggregator.shares(recent, weights: weights) { $0.source.displayName }
    }

    /// Asks the usage endpoint only when the tracker says it is worth it.
    private func refreshLimits(for id: SourceID, weightedDelta: Double, now: Date) async {
        guard id == .claude, !limitsDisabled.contains(id), let usageAPI else { return }

        var tracker = trackers[id] ?? LiveLimitsTracker()
        tracker.record(weighted: weightedDelta)
        defer { trackers[id] = tracker }

        let waited = Int(now.timeIntervalSince(tracker.lastCallAt ?? now))
        guard let reason = tracker.refreshReason(at: now) else {
            Log.usage.debug("skip \(id.rawValue, privacy: .public) activity=\(tracker.hasNewActivity, privacy: .public) waited=\(waited, privacy: .public)s")
            return
        }

        Log.usage.info("request \(id.rawValue, privacy: .public) reason=\(String(describing: reason), privacy: .public) waited=\(waited, privacy: .public)s weighted=\(Int(tracker.weightedSinceAnchor), privacy: .public)")
        let started = Date()

        do {
            let response = try await usageAPI.fetch()
            let ms = Int(Date().timeIntervalSince(started) * 1000)

            guard let anchor = response.anchor(observedAt: now) else {
                // `{}` means this account has nothing to report — an API key, or a
                // token without `user:profile`. Stop asking; inference takes over.
                Log.usage.notice("empty \(id.rawValue, privacy: .public) in \(ms, privacy: .public)ms, falling back to inference")
                limitsDisabled.insert(id)
                return
            }
            tracker.anchored(anchor, at: now)
            liveLimits[id] = response.rateLimits(observedAt: now)
            errors[id] = Self.simulatedError

            let windows = response.windows.keys.sorted().joined(separator: ",")
            let perPercent = Int(tracker.calibration.weightedPerPercent ?? 0)
            Log.usage.info("ok \(id.rawValue, privacy: .public) in \(ms, privacy: .public)ms session=\(anchor.utilization, privacy: .public)% weekly=\(response.weekly?.utilization ?? -1, privacy: .public)% windows=[\(windows, privacy: .public)] perPercent=\(perPercent, privacy: .public) samples=\(tracker.calibration.samples, privacy: .public)")
        } catch {
            tracker.failed(at: now)
            let failure = error as? UsageAPIError
            if failure?.isFatal == true { limitsDisabled.insert(id) }
            errors[id] = failure?.message ?? error.localizedDescription

            let ms = Int(Date().timeIntervalSince(started) * 1000)
            Log.usage.error("failed \(id.rawValue, privacy: .public) in \(ms, privacy: .public)ms error=\(String(describing: failure), privacy: .public) fatal=\(failure?.isFatal == true, privacy: .public) failures=\(tracker.consecutiveFailures, privacy: .public)")
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
            // Rolled forward when the window has already reset, so a figure the
            // tracker knows is current is not thrown away as stale.
            primary: primary.rolled(to: now, usedPercent: live),
            secondary: anchored.secondary,
            planType: anchored.planType,
            observedAt: anchored.observedAt,
            extra: anchored.extra
        )
    }
}
