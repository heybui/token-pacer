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
    /// Poll state per source. Claude has nowhere else to learn the figure;
    /// Codex states it in its own logs and only needs a run once those have
    /// gone quiet — `refreshLimits` counts a log-stated reading as a run, and
    /// the same floors then do the rest.
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

    /// Every Claude Code session registered on this machine, newest change first.
    ///
    /// Outside the poll on purpose. The registry is watched, and this is
    /// rewritten from the watcher's own callback — a session that stops to ask
    /// something reaches the notch a third of a second later, rather than on
    /// whichever tick comes next.
    private(set) var sessions: [AgentSession] = []

    /// How many jobs the pinned provider has working — the one figure the pill
    /// carries beside its own.
    ///
    /// The provider the pill reports, and no other. A machine-wide count put a
    /// number next to a row it had nothing to do with: pinned to Codex, with
    /// Codex idle, the badge was reporting a Claude session and nothing on
    /// screen said so.
    ///
    /// Two books behind it, because the providers keep different ones. Claude
    /// Code registers each session in a file of its own, with a kind and a live
    /// pid to check; Codex registers nothing, so its logs are asked instead — a
    /// session whose turn is open.
    var workingSessions: Int {
        Self.working(sessions: sessions, logs: logWorking, for: activeSource, tracked: tracked)
    }

    /// The same count for a provider that is not the pinned one, which is what
    /// the card's rows carry: a comparison is only one if every row answers the
    /// same questions.
    func workingSessions(of source: SourceID) -> Int {
        Self.working(sessions: sessions, logs: logWorking, for: source, tracked: tracked)
    }

    /// Is anything at all running, on any provider being tracked?
    ///
    /// The border's own question, and a different one from the badge's. The
    /// badge is a figure about the provider the pill reports, beside that
    /// provider's other figures; the border is the pill itself saying the
    /// machine is busy — and a job running under a provider you are not looking
    /// at is exactly the one worth a light around the notch.
    var anyoneWorking: Bool {
        Self.anyoneWorking(sessions: sessions, logs: logWorking, tracked: tracked)
    }

    static func anyoneWorking(
        sessions: [AgentSession], logs: [SourceID: Int], tracked: Set<SourceID>
    ) -> Bool {
        SourceID.allCases.contains {
            working(sessions: sessions, logs: logs, for: $0, tracked: tracked) > 0
        }
    }

    static func working(
        sessions: [AgentSession], logs: [SourceID: Int],
        for source: SourceID, tracked: Set<SourceID>
    ) -> Int {
        // Untracked is not "shown smaller", it is not this app's business.
        guard tracked.contains(source) else { return 0 }
        return source == .claude ? sessions.count(where: \.isWorking) : logs[source] ?? 0
    }

    /// Working sessions each source read out of its own logs.
    private var logWorking: [SourceID: Int] = [:]

    /// The crossing the pill is still carrying, from whichever provider made it.
    ///
    /// Any tracked provider, not the pinned one: a window running out under a
    /// provider you are not looking at is precisely the one you want told about.
    /// It stays until somebody looks — `acknowledge()` — and each mark raises it
    /// once per window, which is `AlertPolicy`'s own rule.
    private(set) var alert: ZoneAlert?

    /// Raised when a new crossing lands, for the one thing the pill cannot do
    /// for itself: make a sound.
    @ObservationIgnored var onAlert: ((ZoneAlert) -> Void)?

    /// One per provider: two providers crossing the same mark are two crossings.
    private var alertPolicies: [SourceID: AlertPolicy] = [:]

    /// The marks a crossing is raised at, per provider. Held by the caller,
    /// which is where the user's own numbers live.
    @ObservationIgnored var alertThresholds: [SourceID: [Double]] = [:]

    /// Somebody looked. The pill goes back to whatever it was doing before.
    func acknowledge() { alert = nil }

    /// Looks for a crossing in a reading that has just landed.
    private func considerAlert(_ snapshot: UsageSnapshot, at now: Date) {
        let marks = alertThresholds[snapshot.source] ?? []
        guard !marks.isEmpty else { return }
        var policy = alertPolicies[snapshot.source] ?? AlertPolicy()
        let crossed = policy.crossing(
            percent: snapshot.sessionPercent,
            resetsAt: snapshot.resetsAt,
            thresholds: marks
        )
        alertPolicies[snapshot.source] = policy
        guard let crossed, let percent = snapshot.sessionPercent else { return }

        let raised = ZoneAlert(
            source: snapshot.source,
            threshold: crossed,
            percent: percent,
            resetsAt: snapshot.resetsAt,
            isOver: crossed >= (marks.max() ?? crossed)
        )
        // A second crossing replaces the first: the newer one is the worse one,
        // and two cards cannot both be on screen.
        alert = raised
        onAlert?(raised)
    }

    /// The newest activity across every tracked provider.
    ///
    /// The pill withdraws after a quiet spell, and quiet has always meant every
    /// provider rather than the pinned one — Codex answering is as much activity
    /// as Claude answering. It was read off the pinned source alone, so a pill
    /// pinned to an idle provider hid itself in the middle of a session on
    /// another one.
    var lastActivity: Date? {
        snapshots
            .filter { tracked.contains($0.key) }
            .values
            .compactMap(\.lastActivity)
            .max()
    }
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

    /// Injected rather than defaulted: they are backed by a pseudo-terminal and
    /// a spawned process, neither of which belongs in Core. One per source that
    /// has a panel worth reading; a source with none is never spawned.
    private let panels: [SourceID: any UsagePanel]
    private let archive: Archive?

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
        sources: [any UsageSource] = [ClaudeCodeSource(), CodexSource(), CopilotSource()],
        weights: TokenWeights = .default,
        interval: TimeInterval = 5,
        panels: [SourceID: any UsagePanel] = [:],
        archive: Archive? = .default
    ) {
        self.sources = sources
        self.weights = weights
        self.interval = interval
        self.panels = panels
        self.archive = archive

        let restored = archive?.load()
        self.pollers = restored?.pollers ?? [:]
        self.liveLimits = restored?.limits ?? [:]
    }

    /// Hands every source its byte offsets back and repopulates the events the
    /// panel draws, so the first poll reads only what has been appended since the
    /// last run instead of the whole log corpus.
    private func restoreEvents() async {
        let started = Date.now
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

        let ms = Int(Date.now.timeIntervalSince(started) * 1000)
        Log.ingest.info("restored \(count, privacy: .public) events in \(ms, privacy: .public)ms")
    }

    /// Cheap to encode but megabytes to write, so it goes out on a slow cadence
    /// and on the way out of the process — never on the 5s tick.
    private static let eventSaveInterval: TimeInterval = 5 * 60
    private var lastEventSave: Date?
    private var reportedFirstSnapshot = false

    private func persistEvents(now: Date = Date.now, force: Bool = false) async {
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
        let fresh = SessionRegistry.read()
        guard fresh != sessions else { return }
        sessions = fresh
        Log.ingest.debug("""
            registry: \(fresh.count, privacy: .public) sessions, \
            \(fresh.count(where: \.isWorking), privacy: .public) sessions working
            """)
    }

    /// Ask every provider again, from scratch.
    ///
    /// `cliNotFound` is fatal — the binary cannot appear while the process runs,
    /// so the poller stops asking — and that was true until the user went and
    /// installed it. Without this the message outlives the problem and only a
    /// relaunch clears it.
    func recheck() {
        limitsDisabled.removeAll()
        limitsErrors.removeAll()
        errors.removeAll()
        // The backoff goes with it: a provider that failed four times is due in
        // an hour, which is not what "check again" means.
        for id in SourceID.allCases { pollers[id] = PanelPoller() }
        persist()
    }

    private func persist() {
        archive?.save(ArchivedState(pollers: pollers, limits: liveLimits))
    }

    func start() {
        guard pump == nil else { return }
        refreshSessions()   // the watcher only fires on a change; this is the first reading
        let launchedAt = Date.now
        pump = Task { [weak self] in
            await self?.restoreEvents()
            while !Task.isCancelled {
                await self?.refreshSoon()
                if let self, !reportedFirstSnapshot {
                    reportedFirstSnapshot = true
                    let ms = Int(Date.now.timeIntervalSince(launchedAt) * 1000)
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

    /// A refresh asked for by a write rather than by the clock.
    ///
    /// The pump's five seconds is the floor under the reading, not its pace: a
    /// prompt writes its first line at once, and waiting for the next tick to
    /// notice was the whole of the delay before the dot lit. The watchers push
    /// here instead — coalesced twice, once by FSEvents and once here, so a
    /// burst of writes cannot queue a refresh per write, and a write that lands
    /// mid-refresh still gets one of its own rather than being swallowed.
    func refreshSoon() async {
        guard !isRefreshing else { refreshPending = true; return }
        isRefreshing = true
        repeat {
            refreshPending = false
            await refresh()
        } while refreshPending
        isRefreshing = false
    }

    private var isRefreshing = false
    private var refreshPending = false

    func refresh(now: Date = Date.now) async {
        // A session that dies without tidying its file leaves the registry
        // claiming it is still waiting, and nothing writes to that directory
        // afterwards to say otherwise. The watcher cannot see a process exit, so
        // the tick that is already running is the floor underneath it — six
        // kilobytes, and no timer of its own.
        refreshSessions()
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
                logWorking[source.id] = fresh.workingSessions

                let windows = WindowCalculator.windows(from: merged, weights: weights)

                // The limits failure is re-applied rather than cleared: a healthy
                // log poll used to wipe the message on the very next tick, so
                // "Claude Code CLI not found" never stayed on screen.
                errors[source.id] = Self.simulatedError ?? limitsErrors[source.id]
                refreshLimits(for: source.id, events: fresh.events,
                              stated: fresh.limits, now: now)

                let panelIsStale = now.timeIntervalSince(
                    panelBuiltAt[source.id] ?? .distantPast
                ) >= Self.panelInterval
                if panelIsStale { panelBuiltAt[source.id] = now }

                snapshots[source.id] = SnapshotBuilder.build(
                    source: source.id,
                    // Whichever reading is newer: a source that states its own
                    // limits has the better one while it is working, and the
                    // panel has it once those logs go quiet. The panel reading is
                    // rolled forward first if its window has reset.
                    limits: Self.newer(fresh.limits, currentLimits(for: source.id, at: now)),
                    events: merged,
                    working: Self.working(
                        sessions: sessions, logs: logWorking, for: source.id, tracked: tracked
                    ),
                    at: now,
                    weights: weights,
                    panelMovedAt: panelMovedAt[source.id],
                    panel: panelIsStale ? nil : snapshots[source.id]?.panel,
                    // Computed once above. Building them a second time inside the
                    // builder doubled the per-tick walk over every retained event
                    // for an identical answer.
                    windows: windows
                )
                if let snapshot = snapshots[source.id] {
                    considerAlert(snapshot, at: now)
                    if source.id == activeSource { onSnapshot?(snapshot) }
                }
            } catch {
                // A missing log directory just means that CLI isn't installed.
                errors[source.id] = error.localizedDescription
            }
        }

        refreshPanelOnlyProviders(now: now)

        await persistEvents(now: now)
    }

    /// A provider with a panel reading and no `UsageSource` behind it.
    ///
    /// Its snapshot is the reading plus nothing — no sparkline, no splits, no
    /// history — because there is no log to build them from. Every provider
    /// shipped today has a source, so this runs for none of them; it is what
    /// keeps the next one from needing a source before it can show a figure.
    private func refreshPanelOnlyProviders(now: Date) {
        for id in panels.keys.sorted(by: { $0.rawValue < $1.rawValue })
        where tracked.contains(id) && !sources.contains(where: { $0.id == id }) {
            refreshLimits(for: id, events: [], stated: nil, now: now)
            errors[id] = Self.simulatedError ?? limitsErrors[id]
            snapshots[id] = SnapshotBuilder.build(
                source: id,
                limits: currentLimits(for: id, at: now),
                events: [],
                at: now,
                weights: weights,
                panelMovedAt: panelMovedAt[id],
                windows: []
            )
            if let snapshot = snapshots[id] {
                considerAlert(snapshot, at: now)
                if id == activeSource { onSnapshot?(snapshot) }
            }
        }
    }

    /// Reads a CLI's own usage panel — Claude's `/usage`, Codex's `/status` —
    /// but only when the poller says it is worth spawning a process for.
    ///
    /// The read is launched, never awaited here. It costs about four seconds — an
    /// HTTP call cost milliseconds — and awaiting it inline held up the snapshot
    /// for *both* sources while a CLI booted, so the pill froze every five minutes
    /// and again at launch. The result lands on a later tick, which is at most 5s
    /// behind a figure that only moves every five minutes anyway.
    private func refreshLimits(
        for id: SourceID, events: [UsageEvent], stated: RateLimits?, now: Date
    ) {
        guard let panel = panels[id], !limitsDisabled.contains(id), !limitsInFlight.contains(id)
        else { return }

        var poller = pollers[id] ?? PanelPoller()
        // Codex writes the same figures into its rollout logs, and a line that
        // has just been read is worth exactly what a run would have cost four
        // seconds to fetch. Counting it as a run is what keeps the spawning to
        // the case it is for: work done where nothing is logged here.
        //
        // A stated reading with no window in it is not one of those lines: an
        // account metered in credits has no window to state, and its logs said
        // so on every poll — which replaced a good panel reading with an empty
        // one and put the row back to `--` seconds after it was read.
        if let stated, stated.primary != nil || stated.secondary != nil,
           stated.observedAt > (poller.lastRunAt ?? .distantPast) {
            liveLimits[id] = stated
            poller.ran(at: stated.observedAt)
        }
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
            let started = Date.now
            do {
                let limits = try await panel.fetch(now: Date.now)
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
        let now = Date.now
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
            limitsErrors[id] = failure?.message(for: id.displayName) ?? error.localizedDescription
            errors[id] = Self.simulatedError ?? limitsErrors[id]

            Log.usage.error("failed \(id.rawValue, privacy: .public) in \(ms, privacy: .public)ms error=\(String(describing: failure), privacy: .public) fatal=\(failure?.isFatal == true, privacy: .public) failures=\(poller.failures, privacy: .public)")
        }
    }

    /// Whichever of two readings was taken later.
    static func newer(_ one: RateLimits?, _ other: RateLimits?) -> RateLimits? {
        guard let one else { return other }
        guard let other else { return one }
        return one.observedAt >= other.observedAt ? one : other
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
