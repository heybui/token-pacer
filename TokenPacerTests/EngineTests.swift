import Foundation
import Testing
@testable import TokenPacer

private let t0 = Date(timeIntervalSince1970: 1_789_000_000)   // a fixed, flat clock
private let utc: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "UTC")!
    return c
}()

private func event(_ offsetHours: Double, output: Int = 1000, id: String = UUID().uuidString) -> UsageEvent {
    UsageEvent(
        id: id,
        source: .claude,
        timestamp: t0.addingTimeInterval(offsetHours * 3600),
        model: "claude-opus-5",
        project: "demo",
        sessionID: "s",
        counts: TokenCounts(input: 100, output: output)
    )
}

// MARK: - windows

@Test func eventsWithinFiveHoursShareOneWindow() {
    let windows = WindowCalculator.windows(
        from: [event(0), event(1), event(2)], calendar: utc
    )
    #expect(windows.count == 1)
    #expect(windows[0].counts.output == 3000)
}

@Test func aGapOfAFullWindowOpensANewOne() {
    let windows = WindowCalculator.windows(
        from: [event(0), event(6)], calendar: utc
    )
    #expect(windows.count == 2)
}

@Test func windowStartIsFlooredToTheHour() {
    let ragged = UsageEvent(
        id: "a", source: .claude,
        timestamp: t0.addingTimeInterval(37 * 60),   // 37 minutes past the hour
        model: nil, project: nil, sessionID: nil,
        counts: TokenCounts(output: 10)
    )
    let window = WindowCalculator.windows(from: [ragged], calendar: utc)[0]
    #expect(window.start == WindowCalculator.floorToHour(ragged.timestamp, calendar: utc))
    #expect(window.end.timeIntervalSince(window.start) == WindowCalculator.fiveHours)
    // Flooring means the window can end sooner than 5h after the first event.
    #expect(window.end.timeIntervalSince(ragged.timestamp) < WindowCalculator.fiveHours)
}

@Test func onlyTheLastWindowCanBeCurrent() {
    let windows = WindowCalculator.windows(from: [event(0), event(6)], calendar: utc)
    let now = t0.addingTimeInterval(6.5 * 3600)
    #expect(WindowCalculator.current(in: windows, at: now) == windows.last)
    // Long after everything, nothing is burning.
    #expect(WindowCalculator.current(in: windows, at: t0.addingTimeInterval(100 * 3600)) == nil)
}

@Test func unsortedInputStillGroupsCorrectly() {
    let windows = WindowCalculator.windows(from: [event(2), event(0), event(1)], calendar: utc)
    #expect(windows.count == 1)
}

// MARK: - snapshot

@Test func theProvidersOwnFigureIsTheHeadline() {
    let limits = RateLimits(
        primary: RateLimitWindow(usedPercent: 22, windowMinutes: 300, resetsAt: t0.addingTimeInterval(3600)),
        secondary: RateLimitWindow(usedPercent: 19, windowMinutes: 10080, resetsAt: t0.addingTimeInterval(86400)),
        planType: "plus", observedAt: t0
    )
    let snapshot = SnapshotBuilder.build(
        source: .codex, limits: limits, events: [event(0)], at: t0.addingTimeInterval(60)
    )
    #expect(snapshot.sessionPercent == 22)
    #expect(snapshot.weeklyPercent == 19)
    #expect(snapshot.planType == "plus")
}

/// The panel's spend cell is drawn only when there is spend, and an account that
/// never enabled extra usage still reports the block with `enabled: false`.
@Test func disabledSpendNeverReachesTheSnapshot() {
    func snapshot(_ spend: Spend?) -> UsageSnapshot {
        SnapshotBuilder.build(
            source: .claude,
            limits: RateLimits(primary: nil, secondary: nil, planType: nil,
                               observedAt: t0, spend: spend),
            events: [event(0)], at: t0.addingTimeInterval(60)
        )
    }
    let money = Money(amountMinor: 1199, currency: "SGD", exponent: 2)
    let spending = Spend(used: money, limit: nil, percent: 99, isEnabled: true)
    #expect(snapshot(spending).spend == spending)
    #expect(snapshot(Spend(used: money, limit: nil, percent: 0, isEnabled: false)).spend == nil)
    #expect(snapshot(nil).spend == nil)
}

/// A reading whose window already reset describes a window that no longer exists.
@Test func staleAuthoritativeLimitsAreDiscarded() {
    let stale = RateLimits(
        primary: RateLimitWindow(usedPercent: 99, windowMinutes: 300, resetsAt: t0.addingTimeInterval(-3600)),
        secondary: nil, planType: "plus", observedAt: t0.addingTimeInterval(-10000)
    )
    let snapshot = SnapshotBuilder.build(
        source: .codex, limits: stale, events: [event(0)], at: t0.addingTimeInterval(60)
    )
    #expect(snapshot.sessionPercent == nil)
}

/// No reading, no percentage. The tokens a window has taken are still counted —
/// they are a measurement — but nothing here turns them into a share of a limit.
@Test func noReadingMeansNoPercentage() {
    let snapshot = SnapshotBuilder.build(
        source: .claude, limits: nil, events: [event(0)], at: t0.addingTimeInterval(60)
    )
    #expect(snapshot.sessionPercent == nil)
    #expect(snapshot.sessionTokens > 0)
}

@Test func noEventsMeansNothingIsBurning() {
    let snapshot = SnapshotBuilder.build(source: .claude, limits: nil, events: [], at: t0)
    #expect(snapshot.isActive == false)
    #expect(snapshot.sessionTokens == 0)
}

// MARK: - token normalisation

@Test func reasoningTokensAreNeverWeightedTwice() {
    // reasoning is a subset of output in both CLIs.
    let counts = TokenCounts(input: 0, output: 1000, reasoning: 400)
    #expect(counts.weighted(.default) == TokenCounts(input: 0, output: 1000).weighted(.default))
}

@Test func cacheReadsCostFarLessThanFreshOutput() {
    let cached = TokenCounts(cacheRead: 1000).weighted(.default)
    let fresh = TokenCounts(output: 1000).weighted(.default)
    #expect(cached < fresh)
}

// MARK: - the activity dot

/// The dot, the running border and the badge are one fact: how many sessions of
/// this provider have a model answering. It used to be inferred from how recently
/// a log line had landed, which pulsed at the bookkeeping written *after* a turn
/// and went dark in the middle of a long one — a dot blinking at a machine where
/// nothing was running.
@Test func theDotFollowsTheCountOfSessionsAnswering() {
    let now = t0.addingTimeInterval(600)
    let quiet = SnapshotBuilder.build(
        source: .claude, limits: nil, events: [event(600.0 / 3600)], working: 0, at: now
    )
    #expect(quiet.isActive)              // the window is open
    #expect(quiet.isBurning == false)    // and nothing is answering in it

    let busy = SnapshotBuilder.build(
        source: .claude, limits: nil, events: [event(0)], working: 1, at: now
    )
    // Hours since the last token was logged, and still lit: a long turn writes
    // nothing at all while it runs.
    #expect(busy.isBurning)
}

@Test func nothingLoggedIsNotBurning() {
    let empty = SnapshotBuilder.build(source: .claude, limits: nil, events: [], at: t0)
    #expect(empty.isBurning == false)
    #expect(empty.lastActivity == nil)
}

// MARK: - usage that leaves no log here

/// Web and Claude Design spend the same session limit and write nothing to
/// ~/.claude. Dormancy runs off `lastActivity`, so on the logs alone the pill
/// withdrew to its 3pt sliver ten minutes into a browser session and hid a
/// figure that was still climbing.
@Test func aMovedPanelCountsAsActivityWhenTheLogsAreSilent() {
    let now = Date(timeIntervalSince1970: 1_789_000_000)
    let moved = now.addingTimeInterval(-60)

    let snapshot = SnapshotBuilder.build(
        source: .claude, limits: nil, events: [], at: now,
        panelMovedAt: moved
    )

    #expect(snapshot.lastActivity == moved)
    #expect(PillStateResolver.resolve(
        PillInputs(snapshot: snapshot), at: now) != .hidden)

    // ...but the ring still answers to the logs. A reading proves work happened
    // somewhere in the last half hour, not that tokens are flowing this second.
    #expect(snapshot.isBurning == false)
}

/// With logs to go on, the newer of the two wins — a panel read half an hour ago
/// must not make a session that stopped five minutes ago look older than it is.
@Test func loggedActivityStillWinsWhenItIsNewer() {
    let now = Date(timeIntervalSince1970: 1_789_000_000)
    let snapshot = SnapshotBuilder.build(
        source: .claude, limits: nil, events: [], at: now,
        panelMovedAt: now.addingTimeInterval(-1800)
    )
    #expect(snapshot.lastActivity == now.addingTimeInterval(-1800))
}

/// The panel is a 30-day grid nobody is looking at: it feeds the pinned sheet
/// alone. Rebuilt on every 5s tick it was the most expensive thing the app did,
/// and it grew with the history, so a handed-in one has to be used as given.
@Test func ahandedInPanelIsUsedInsteadOfAggregatingAgain() {
    let now = Date(timeIntervalSince1970: 1_789_000_000)
    let events = (1...200).map { event(Double(-$0) / 6) }
    let fresh = SnapshotBuilder.build(
        source: .claude, limits: nil, events: events, at: now
    )
    #expect(fresh.panel != PanelData())

    let reused = SnapshotBuilder.build(
        source: .claude, limits: nil, events: events, at: now,
        panel: PanelData()
    )
    #expect(reused.panel == PanelData())
    // Everything else still comes off the events, so a stale panel never staled
    // the figure beside it.
    #expect(reused.sessionTokens == fresh.sessionTokens)
    #expect(reused.lastActivity == fresh.lastActivity)
}

// MARK: - the poll's own cost

/// The retained array is kept sorted and re-sorting it on every 5s tick is what
/// the poll spent most of its time on, so the sort is now skipped when the fresh
/// batch appends cleanly. Get this wrong and events land out of order, which
/// silently mis-builds every window downstream — so it is checked at the join
/// and within the batch, not assumed.
@MainActor
@Test func onlyOutOfOrderArrivalsForceASort() {
    let ordered = [event(1), event(2), event(3)]

    // The ordinary case: newer lines appended to older history.
    #expect(UsageStore.isDisordered(ordered, after: t0) == false)
    #expect(UsageStore.isDisordered([], after: t0) == false)
    #expect(UsageStore.isDisordered(ordered, after: nil) == false)

    // A resumed session replays history behind what is already held.
    #expect(UsageStore.isDisordered(ordered, after: t0.addingTimeInterval(10 * 3600)))
    // ...and a batch can be ragged within itself.
    #expect(UsageStore.isDisordered([event(3), event(1)], after: t0))
}

/// The captions used to say "5-hour window" whatever the row was showing. A
/// workspace metered in credits has a month there and nothing shorter.
@Test func aCaptionNamesTheWindowItPointsAt() {
    #expect(Format.windowName(300) == "5-hour window")
    #expect(Format.windowName(10_080) == "week")
    #expect(Format.windowName(43_200) == "month")
    #expect(Format.windowName(nil) == "window")
    #expect(Format.windowTag(300) == "5-HOUR")
    #expect(Format.windowTag(43_200) == "MONTHLY")
}

/// And that the window's length reaches the caption at all: it is read off the
/// provider's own reading, never assumed.
@Test func theSnapshotCarriesHowLongItsWindowsRun() {
    let now = Date()
    let month = RateLimitWindow(
        usedPercent: 3, windowMinutes: 43_200, resetsAt: now.addingTimeInterval(864_000)
    )
    let snapshot = SnapshotBuilder.build(
        source: .codex,
        limits: RateLimits(primary: month, secondary: nil, planType: "Enterprise", observedAt: now),
        events: [], at: now
    )
    #expect(snapshot.windowMinutes == 43_200)
    #expect(snapshot.weeklyWindowMinutes == nil)
}

// MARK: - what the window went on

/// The third column used to be a cross-provider split sitting in a panel that
/// reads one provider at a time. This one is about the provider on screen: where
/// its weighted tokens went. Weighted is the point — a cached read is a tenth of
/// a fresh one, so the kind that is most of the raw traffic is a sliver here.
@Test func theMixIsWeightedAndNeverCountsReasoningTwice() {
    let event = UsageEvent(
        id: "a", source: .claude, timestamp: t0,
        model: nil, project: nil, sessionID: nil,
        counts: TokenCounts(input: 100, output: 100, cacheWrite: 0, cacheRead: 100, reasoning: 90)
    )
    let mix = Aggregator.mix([event])

    // Four kinds, one row each, minus the ones that cost nothing — and never a
    // reasoning row: those tokens are already inside output.
    #expect(mix.map(\.name) == ["Output", "Input", "Cache read"])
    #expect(mix.map(\.share).reduce(0, +) == 100)
    // Equal counts, unequal shares: that is the weighting showing its work.
    #expect(mix[0].share > mix[1].share)
    #expect(mix[1].share > mix[2].share)

    #expect(Aggregator.mix([]).isEmpty)
}

/// The splits described a five-hour window whatever the provider was metered by,
/// so a workspace on a monthly credit budget showed "no open window" in all three
/// columns for days on end — under a headline figure that was plainly moving.
/// They cover the window the headline is about now.
@Test func splitsCoverTheWindowTheHeadlineIsAbout() {
    let now = Date(timeIntervalSince1970: 1_789_000_000)
    func event(_ daysAgo: Double) -> UsageEvent {
        UsageEvent(
            id: "\(daysAgo)", source: .copilot,
            timestamp: now.addingTimeInterval(-daysAgo * 86_400),
            model: "gpt-6-astra", project: "thing", sessionID: nil,
            counts: TokenCounts(input: 100, output: 100)
        )
    }
    // A month that resets in ten days began twenty days ago.
    let month = RateLimitWindow(
        usedPercent: 42, windowMinutes: 43_200, resetsAt: now.addingTimeInterval(10 * 86_400)
    )
    let snapshot = SnapshotBuilder.build(
        source: .copilot,
        limits: RateLimits(primary: month, secondary: nil, planType: nil, observedAt: now),
        events: [event(10), event(25)], at: now
    )

    #expect(snapshot.panel.byModel.map(\.name) == ["gpt-6-astra"])
    #expect(snapshot.panel.byProject.map(\.name) == ["thing"])
    #expect(snapshot.panel.byKind.map(\.name) == ["Output", "Input"])
    // The one from before this billing period began is not in it: the columns
    // would otherwise add up to more than the percentage above them.
    #expect(snapshot.panel.byModel[0].share == 100)
    #expect(snapshot.sessionTokens == 0)   // and no five-hour window is open
}
