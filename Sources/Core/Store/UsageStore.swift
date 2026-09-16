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

    /// Raw events are kept only long enough to serve the history grid.
    private static let retention = TimeInterval(Aggregator.historyDays) * 24 * 3600

    /// `usageAPI` is injected rather than defaulted: it is backed by the Keychain,
    /// which lives outside Core.
    private let usageAPI: ClaudeUsageAPI?
    private let archive: Archive?

    /// Survives relaunch, so "tracking is off" stays off.
    private(set) var isPaused: Bool

    init(
        sources: [any UsageSource] = [ClaudeCodeSource(), CodexSource()],
        weights: TokenWeights = .default,
        interval: TimeInterval = 5,
        usageAPI: ClaudeUsageAPI? = nil,
        archive: Archive? = .default
    ) {
        self.sources = sources
        self.weights = weights
        self.interval = interval
        self.usageAPI = usageAPI
        self.archive = archive

        let restored = archive?.load()
        self.trackers = restored?.trackers ?? [:]
        self.liveLimits = restored?.limits ?? [:]
        self.isPaused = restored?.isPaused ?? false
    }

    /// Hands every source its byte offsets back and repopulates the events the
    /// panel draws, so the first poll reads only what has been appended since the
    /// last run instead of the whole log corpus.
    private func restoreEvents() async {
        let started = Date()
        guard let archived = archive?.loadEvents() else { return }
        var count = 0

        for source in sources {
            guard let state = archived.sources[source.id] else { continue }
            events[source.id] = state.events
            count += state.events.count
            // `seen` catches history replayed into a *new* file on resume, so it
            // is rebuilt from the archived ids rather than stored a second time.
            await source.restore(
                cursors: state.cursors, seen: Set(state.events.map(\.id))
            )
        }

        let ms = Int(Date().timeIntervalSince(started) * 1000)
        Log.ingest.info("restored \(count, privacy: .public) events in \(ms, privacy: .public)ms")
    }

    /// Cheap to encode but megabytes to write, so it goes out on a slow cadence
    /// and on the way out of the process — never on the 5s tick.
    private static let eventSaveInterval: TimeInterval = 5 * 60
    private var lastEventSave: Date?
    private var reportedFirstSnapshot = false

    private func persistEvents(now: Date = Date(), force: Bool = false) async {
        guard let archive else { return }
        if !force, let last = lastEventSave, now.timeIntervalSince(last) < Self.eventSaveInterval {
            return
        }
        lastEventSave = now

        var archived = ArchivedEvents()
        for source in sources {
            archived.sources[source.id] = ArchivedEvents.PerSource(
                cursors: await source.cursors(), events: events[source.id] ?? []
            )
        }
        archive.saveEvents(archived)
    }

    /// Called on the way out: the last few minutes of events would otherwise be
    /// re-read from the logs on the next launch.
    func flush() async {
        persist()
        await persistEvents(force: true)
    }

    func setPaused(_ paused: Bool) {
        guard paused != isPaused else { return }
        isPaused = paused
        paused ? stop() : start()
        persist()
    }

    private func persist() {
        archive?.save(ArchivedState(trackers: trackers, limits: liveLimits, isPaused: isPaused))
    }

    func start() {
        guard pump == nil else { return }
        let launchedAt = Date()
        pump = Task { [weak self] in
            await self?.restoreEvents()
            while !Task.isCancelled {
                await self?.refresh()
                if let self, !reportedFirstSnapshot {
                    reportedFirstSnapshot = true
                    let ms = Int(Date().timeIntervalSince(launchedAt) * 1000)
                    let events = SourceID.allCases.reduce(0) { $0 + eventCount($1) }
                    Log.ingest.info("first snapshot in \(ms, privacy: .public)ms over \(events, privacy: .public) events")
                }
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

                await refreshLimits(for: source.id, events: fresh.events, now: now)

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

        await persistEvents(now: now)
    }

    /// Asks the usage endpoint only when the tracker says it is worth it.
    private func refreshLimits(for id: SourceID, events: [UsageEvent], now: Date) async {
        guard id == .claude, !limitsDisabled.contains(id), let usageAPI else { return }

        var tracker = trackers[id] ?? LiveLimitsTracker()
        // Only what the anchor has not already seen. A cold start replays every
        // retained event, and counting 90 days of history as usage since the last
        // reading would teach calibration a conversion out by orders of magnitude.
        let since = tracker.anchor?.observedAt ?? .distantPast
        tracker.record(
            weighted: events.lazy
                .filter { $0.timestamp > since }
                .reduce(0) { $0 + $1.counts.weighted(weights) }
        )
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
            trackers[id] = tracker
            persist()

            let windows = response.windows.keys.sorted().joined(separator: ",")
            let perPercent = Int(tracker.calibration.weightedPerPercent ?? 0)
            Log.usage.info("ok \(id.rawValue, privacy: .public) in \(ms, privacy: .public)ms session=\(anchor.utilization, privacy: .public)% weekly=\(response.weekly?.utilization ?? -1, privacy: .public)% windows=[\(windows, privacy: .public)] perPercent=\(perPercent, privacy: .public) samples=\(tracker.calibration.samples, privacy: .public)")
        } catch {
            tracker.failed(at: now)
            trackers[id] = tracker
            persist()
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
            spend: anchored.spend
        )
    }
}
