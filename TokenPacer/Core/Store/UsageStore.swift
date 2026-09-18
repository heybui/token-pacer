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

    /// A `/usage` run is outstanding. The UI never waits on this — the next tick
    /// picks the result up — but `--probe` has to, or it exits before the CLI
    /// has finished booting and reports the inferred figure it was built to check.
    var isReadingLimits: Bool { !limitsInFlight.isEmpty }

    /// 5s poll on a timer rather than a file watcher: a 5-hour window does not
    /// need sub-second freshness, and watching ~/.claude/projects fires constantly.
    private let interval: TimeInterval
    private let sources: [any UsageSource]
    private let weights: TokenWeights
    private var events: [SourceID: [UsageEvent]] = [:]
    /// Poll state per source. Only Claude needs it; Codex states its own limits
    /// in its logs, so it never spawns anything.
    private var pollers: [SourceID: PanelPoller] = [:]
    private var liveLimits: [SourceID: RateLimits] = [:]
    /// When a reading last came back higher than the one before it.
    ///
    /// The only evidence this app gets of work done outside the CLI. Web and
    /// Claude Design write no log here, so without this the pill withdrew to its
    /// 3pt sliver ten minutes into a browser session and hid a climbing figure.
    private var panelMovedAt: [SourceID: Date] = [:]
    /// When each source's panel aggregation was last rebuilt.
    ///
    /// It is a 30-day grid, a sparkline and the splits, and only the pinned panel
    /// shows any of it. Rebuilding that on every 5s tick cost more than the rest
    /// of the app put together once a few weeks of history had built up.
    private var panelBuiltAt: [SourceID: Date] = [:]
    /// The coarsest thing the panel draws is a day, the finest a sparkline bucket.
    /// A minute is invisible in both and cuts the work by twelve.
    private static let panelInterval: TimeInterval = 60
    /// Last known state of each source's newest log line. A poll that reads no
    /// new lines says nothing about activity, so the previous answer stands.
    private var activities: [SourceID: LogActivity] = [:]
    /// Sources whose limits reading failed in a way retrying cannot fix.
    private var limitsDisabled: Set<SourceID> = []
    /// The last limits failure per source, held until a reading succeeds.
    ///
    /// It cannot live in `errors` alone: a healthy log poll rewrites that every
    /// 5s, while a reading happens every 5 minutes at most — and not at all while
    /// backed off or disabled, which is exactly when there is a message worth
    /// showing. Written once, re-applied every tick.
    private var limitsErrors: [SourceID: String] = [:]
    /// One reading per source at a time. The panel is read off the main actor, so
    /// without this a slow CLI would be respawned on the next tick.
    private var limitsInFlight: Set<SourceID> = []
    /// Which CLI the tokens went through, across every source. The per-source
    /// splits live on the snapshot; this one is the only figure that needs all
    /// of them at once.
    private(set) var bySource: [UsageSplit] = []

    /// Every Claude Code session registered on this machine, newest change first.
    ///
    /// Outside the poll on purpose. The registry is watched, and this is
    /// rewritten from the watcher's own callback — a session that stops to ask
    /// something reaches the notch a third of a second later, rather than on
    /// whichever tick comes next.
    private(set) var sessions: [AgentSession] = []

    /// How many sessions are stopped, waiting for an answer. The one figure the
    /// pill carries: the rest of the registry is only worth a panel.
    var waitingSessions: Int { sessions.count(where: \.isWaiting) }
    private var pump: Task<Void, Never>?

    /// Does appending these break the order of what is already held?
    ///
    /// Cheap: the fresh batch is a handful of lines, and the only other place
    /// order can break is where it joins the tail.
    static func isDisordered(_ fresh: [UsageEvent], after newest: Date?) -> Bool {
        guard let first = fresh.first else { return false }
        if let newest, newest > first.timestamp { return true }
        return zip(fresh, fresh.dropFirst()).contains { $0.timestamp > $1.timestamp }
    }

    /// Raw events are kept only long enough to serve the history grid.
    private static let retention = TimeInterval(Aggregator.historyDays) * 24 * 3600

    /// Called with every fresh snapshot of the active source. The alerting lives
    /// outside Core — this is just where the snapshots already are.
    @ObservationIgnored var onSnapshot: ((UsageSnapshot) -> Void)?

    /// Injected rather than defaulted: it is backed by a pseudo-terminal and a
    /// spawned process, neither of which belongs in Core.
    private let usagePanel: ClaudeUsagePanel?
    private let archive: Archive?

    /// Survives relaunch, so "tracking is off" stays off.
    private(set) var isPaused: Bool

    /// Which providers are being tracked at all.
    ///
    /// Untracked means *not polled*: the whole point of turning Claude off is
    /// that its CLI stops being asked anything, which is the one expensive thing
    /// this app does. Held here rather than filtered in the view for that reason.
    var tracked: Set<SourceID> = Set(SourceID.allCases) {
        didSet {
            guard !tracked.contains(activeSource) else { return }
            if let next = SourceID.allCases.first(where: tracked.contains) {
                activeSource = next
            }
        }
    }

    init(
        sources: [any UsageSource] = [ClaudeCodeSource(), CodexSource()],
        weights: TokenWeights = .default,
        interval: TimeInterval = 5,
        usagePanel: ClaudeUsagePanel? = nil,
        archive: Archive? = .default
    ) {
        self.sources = sources
        self.weights = weights
        self.interval = interval
        self.usagePanel = usagePanel
        self.archive = archive

        let restored = archive?.load()
        self.pollers = restored?.pollers ?? [:]
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

    /// Re-reads the registry whole — eleven small files, no cursor. Called from
    /// the watcher, so the cost is paid when a session actually changed state.
    func refreshSessions() {
        // Paused means nothing is read. A stale count would outlive the pause
        // and claim someone is waiting long after they stopped.
        sessions = isPaused ? [] : SessionRegistry.read()
    }

    func setPaused(_ paused: Bool) {
        guard paused != isPaused else { return }
        isPaused = paused
        refreshSessions()
        paused ? stop() : start()
        persist()
    }

    private func persist() {
        archive?.save(ArchivedState(pollers: pollers, limits: liveLimits, isPaused: isPaused))
    }

    func start() {
        guard pump == nil else { return }
        refreshSessions()   // the watcher only fires on a change; this is the first reading
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

    /// Debug hook: `TOKENPACER_SIMULATE_ERROR=1` forces the attention state so the
    /// degraded UI can be checked without waiting for a real failure.
    private static var simulatedError: String? {
        ProcessInfo.processInfo.environment["TOKENPACER_SIMULATE_ERROR"].map {
            $0 == "1" ? "usage request failed" : $0
        }
    }

    func refresh(now: Date = Date()) async {
        if let simulated = Self.simulatedError {
            for id in SourceID.allCases { errors[id] = simulated }
        }
        // Untracked sources are not polled at all — no log walk, no pty, no
        // `/usage`. Their last snapshot stays in the dictionary; nothing reads it.
        for source in sources where tracked.contains(source.id) {
            do {
                let fresh = try await source.poll()
                var merged = events[source.id] ?? []
                let newest = merged.last?.timestamp
                merged.append(contentsOf: fresh.events)

                // Sorted already, and fresh lines arrive in order, so the join is
                // the only place order can break — a resumed session replaying
                // history behind what is already held. Sorting every retained
                // event on each 5s tick to append a handful of new ones was the
                // most expensive thing in the poll, and it grew with the history.
                if Self.isDisordered(fresh.events, after: newest) {
                    merged.sort { $0.timestamp < $1.timestamp }
                }

                // Expiry is a prefix of a sorted array, so this walks only what it
                // drops — nothing, on almost every tick — rather than all of it.
                let cutoff = now.addingTimeInterval(-Self.retention)
                if let firstKept = merged.firstIndex(where: { $0.timestamp >= cutoff }) {
                    merged.removeFirst(firstKept)
                } else if merged.last.map({ $0.timestamp < cutoff }) == true {
                    merged.removeAll()
                }
                events[source.id] = merged
                if let activity = fresh.activity { activities[source.id] = activity }

                let windows = WindowCalculator.windows(from: merged, weights: weights)

                // The limits failure is re-applied rather than cleared: a healthy
                // log poll used to wipe the message on the very next tick, so
                // "Claude Code CLI not found" never stayed on screen.
                errors[source.id] = Self.simulatedError ?? limitsErrors[source.id]
                refreshLimits(for: source.id, events: fresh.events, now: now)

                let panelIsStale = now.timeIntervalSince(
                    panelBuiltAt[source.id] ?? .distantPast
                ) >= Self.panelInterval
                if panelIsStale { panelBuiltAt[source.id] = now }

                snapshots[source.id] = SnapshotBuilder.build(
                    source: source.id,
                    // A source that states its own limits wins; otherwise use the
                    // last panel reading, rolled forward if its window has reset.
                    limits: fresh.limits ?? currentLimits(for: source.id, at: now),
                    events: merged,
                    activity: fresh.activity ?? activities[source.id],
                    at: now,
                    weights: weights,
                    panelMovedAt: panelMovedAt[source.id],
                    panel: panelIsStale ? nil : snapshots[source.id]?.panel,
                    // Computed once above. Building them a second time inside the
                    // builder doubled the per-tick walk over every retained event
                    // for an identical answer.
                    windows: windows
                )
                if source.id == activeSource, let snapshot = snapshots[source.id] {
                    onSnapshot?(snapshot)
                }
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

    /// Reads the CLI's `/usage` panel, but only when the poller says it is worth
    /// spawning a process for.
    ///
    /// The read is launched, never awaited here. It costs about four seconds — an
    /// HTTP call cost milliseconds — and awaiting it inline held up the snapshot
    /// for *both* sources while a CLI booted, so the pill froze every five minutes
    /// and again at launch. The result lands on a later tick, which is at most 5s
    /// behind a figure that only moves every five minutes anyway.
    private func refreshLimits(for id: SourceID, events: [UsageEvent], now: Date) {
        guard id == .claude, !limitsDisabled.contains(id), !limitsInFlight.contains(id),
              let usagePanel
        else { return }

        var poller = pollers[id] ?? PanelPoller()
        // Only what the last reading has not already seen. A cold start replays
        // every retained event, and 90 days of history would look like activity
        // that happened since the last run.
        let since = poller.lastRunAt ?? .distantPast
        poller.record(
            weighted: events.lazy
                .filter { $0.timestamp > since }
                .reduce(0) { $0 + $1.counts.weighted(weights) }
        )
        pollers[id] = poller

        let waited = Int(now.timeIntervalSince(poller.lastRunAt ?? now))
        guard poller.shouldRun(at: now) else {
            Log.usage.debug("skip \(id.rawValue, privacy: .public) activity=\(poller.hasNewActivity, privacy: .public) waited=\(waited, privacy: .public)s")
            return
        }

        Log.usage.info("run \(id.rawValue, privacy: .public) waited=\(waited, privacy: .public)s weighted=\(Int(poller.pendingWeighted), privacy: .public)")
        limitsInFlight.insert(id)
        // Captured before the run clears it: a reading that moves without this
        // is the signature of usage from a surface that logs nothing here.
        let hadLocalActivity = poller.hasNewActivity

        Task { [weak self] in
            let started = Date()
            do {
                let limits = try await usagePanel.fetch(now: Date())
                self?.applyLimits(.success(limits), for: id, startedAt: started,
                                  hadLocalActivity: hadLocalActivity)
            } catch {
                self?.applyLimits(.failure(error), for: id, startedAt: started,
                                  hadLocalActivity: hadLocalActivity)
            }
        }
    }

    /// The tail of a reading, back on the main actor.
    private func applyLimits(
        _ result: Result<RateLimits, any Error>, for id: SourceID, startedAt: Date,
        hadLocalActivity: Bool = false
    ) {
        limitsInFlight.remove(id)
        var poller = pollers[id] ?? PanelPoller()
        let now = Date()
        let ms = Int(now.timeIntervalSince(startedAt) * 1000)

        switch result {
        case .success(let limits):
            poller.ran(at: now)
            // A rise is proof work happened, whatever surface produced it. Only a
            // rise: a reset drops the figure, and an empty window is not activity.
            var rose = false
            if let was = liveLimits[id]?.primary?.usedPercent,
               let is_ = limits.primary?.usedPercent { rose = is_ > was }
            if rose { panelMovedAt[id] = now }
            poller.offLogActivity = rose && !hadLocalActivity
            pollers[id] = poller
            liveLimits[id] = limits
            limitsErrors[id] = nil
            errors[id] = Self.simulatedError
            persist()

            Log.usage.info("ok \(id.rawValue, privacy: .public) in \(ms, privacy: .public)ms session=\(limits.primary?.usedPercent ?? -1, privacy: .public)% weekly=\(limits.secondary?.usedPercent ?? -1, privacy: .public)%")

        case .failure(let error):
            poller.failed(at: now)
            pollers[id] = poller
            persist()
            let failure = error as? PanelError
            if failure?.isFatal == true { limitsDisabled.insert(id) }
            limitsErrors[id] = failure?.message ?? error.localizedDescription
            errors[id] = Self.simulatedError ?? limitsErrors[id]

            Log.usage.error("failed \(id.rawValue, privacy: .public) in \(ms, privacy: .public)ms error=\(String(describing: failure), privacy: .public) fatal=\(failure?.isFatal == true, privacy: .public) failures=\(poller.failures, privacy: .public)")
        }
    }

    /// The last reading, with each window rolled forward past its own reset.
    ///
    /// Independently, because they expire independently: gating the weekly roll on
    /// the session having reset too meant that after a Monday 1am weekly rollover
    /// the weekly figure was simply dropped as stale — and at 1am there is no
    /// activity to earn the reading that would bring it back.
    ///
    /// Nothing is extrapolated in between: whole percentages cannot be advanced by
    /// a token count without inventing precision the panel never had. A reset is
    /// the one exception, and it needs no conversion — the window is simply empty,
    /// and the next run re-reads whatever has been spent since.
    private func currentLimits(for id: SourceID, at now: Date) -> RateLimits? {
        guard let reading = liveLimits[id] else { return nil }

        func rolled(_ window: RateLimitWindow?) -> RateLimitWindow? {
            guard let window, window.resetsAt <= now else { return window }
            return window.rolled(to: now, usedPercent: 0)
        }

        return RateLimits(
            primary: rolled(reading.primary),
            secondary: rolled(reading.secondary),
            planType: reading.planType,
            observedAt: reading.observedAt,
            spend: reading.spend
        )
    }
}
