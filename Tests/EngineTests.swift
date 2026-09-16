import Foundation
import Testing
@testable import BurnTracker

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

// MARK: - ceiling

@Test func ceilingIgnoresTheWindowStillFilling() {
    let windows = WindowCalculator.windows(from: [event(0), event(6, output: 999_999)], calendar: utc)
    let now = t0.addingTimeInterval(6.5 * 3600)          // second window still live
    let ceiling = CeilingEstimator.estimate(windows: windows, at: now)
    #expect(ceiling.observedWindows == 1)
    #expect(ceiling.weightedTokens == windows[0].weighted)   // not the huge live one
}

@Test func ceilingNeverForgetsAnEarlierPeak() {
    let peak = Ceiling(weightedTokens: 10_000_000, observedWindows: 5)
    let windows = WindowCalculator.windows(from: [event(0)], calendar: utc)
    let later = CeilingEstimator.estimate(
        windows: windows, at: t0.addingTimeInterval(100 * 3600), previous: peak
    )
    #expect(later.weightedTokens == 10_000_000)
}

@Test func withoutACompletedWindowThereIsNoPercentage() {
    let ceiling = Ceiling.unknown
    #expect(ceiling.isConfident == false)
    #expect(ceiling.percent(of: 5000) == nil)
}

@Test func percentageIsClampedToOneHundred() {
    let ceiling = Ceiling(weightedTokens: 1000, observedWindows: 3)
    #expect(ceiling.percent(of: 5000) == 100)
}

// MARK: - snapshot

@Test func authoritativeLimitsWinOverInference() {
    let limits = RateLimits(
        primary: RateLimitWindow(usedPercent: 22, windowMinutes: 300, resetsAt: t0.addingTimeInterval(3600)),
        secondary: RateLimitWindow(usedPercent: 19, windowMinutes: 10080, resetsAt: t0.addingTimeInterval(86400)),
        planType: "plus", observedAt: t0
    )
    let snapshot = SnapshotBuilder.build(
        source: .codex, limits: limits, events: [event(0)],
        ceiling: Ceiling(weightedTokens: 1_000_000, observedWindows: 9), at: t0.addingTimeInterval(60)
    )
    #expect(snapshot.origin == .authoritative)
    #expect(snapshot.sessionPercent == 22)
    #expect(snapshot.weeklyPercent == 19)
    #expect(snapshot.planType == "plus")
}

/// The panel's spend cell is drawn only when there is spend, and an account that
/// has never enabled extra usage still reports the block with `is_enabled: false`.
@Test func disabledExtraUsageNeverReachesTheSnapshot() {
    func snapshot(_ extra: ExtraUsage?) -> UsageSnapshot {
        SnapshotBuilder.build(
            source: .claude,
            limits: RateLimits(primary: nil, secondary: nil, planType: nil,
                               observedAt: t0, extra: extra),
            events: [event(0)], ceiling: .unknown, at: t0.addingTimeInterval(60)
        )
    }
    let spending = ExtraUsage(isEnabled: true, monthlyLimit: 300, usedCredits: 176, utilization: 58)
    #expect(snapshot(spending).extraUsage == spending)
    #expect(snapshot(ExtraUsage(isEnabled: false, monthlyLimit: 300, usedCredits: 0,
                                utilization: 0)).extraUsage == nil)
    #expect(snapshot(nil).extraUsage == nil)
}

/// A reading whose window already reset describes a window that no longer exists.
@Test func staleAuthoritativeLimitsAreDiscarded() {
    let stale = RateLimits(
        primary: RateLimitWindow(usedPercent: 99, windowMinutes: 300, resetsAt: t0.addingTimeInterval(-3600)),
        secondary: nil, planType: "plus", observedAt: t0.addingTimeInterval(-10000)
    )
    let snapshot = SnapshotBuilder.build(
        source: .codex, limits: stale, events: [event(0)],
        ceiling: Ceiling(weightedTokens: 10_000, observedWindows: 4), at: t0.addingTimeInterval(60)
    )
    #expect(snapshot.origin == .inferred)
    #expect(snapshot.sessionPercent != 99)
}

@Test func unknownCeilingReportsTokensNotAPercentage() {
    let snapshot = SnapshotBuilder.build(
        source: .claude, limits: nil, events: [event(0)],
        ceiling: .unknown, at: t0.addingTimeInterval(60)
    )
    #expect(snapshot.origin == .unknown)
    #expect(snapshot.sessionPercent == nil)
    #expect(snapshot.sessionTokens > 0)
}

@Test func noEventsMeansNothingIsBurning() {
    let snapshot = SnapshotBuilder.build(
        source: .claude, limits: nil, events: [], ceiling: .unknown, at: t0
    )
    #expect(snapshot.isActive == false)
    #expect(snapshot.sessionTokens == 0)
    #expect(snapshot.burn == .idle)
}

// MARK: - burn rate

@Test func burnRateIgnoresEventsOlderThanTheSample() {
    let now = t0.addingTimeInterval(10 * 3600)
    let rate = BurnRateCalculator.rate(
        events: [event(0)], window: nil, ceiling: .unknown, at: now
    )
    #expect(rate == .idle)
}

@Test func headroomShrinksAsTheWindowFills() {
    let now = t0.addingTimeInterval(600)
    let events = [event(0.05), event(0.1)]
    let window = WindowCalculator.windows(from: events, calendar: utc)[0]
    let ceiling = Ceiling(weightedTokens: 100_000, observedWindows: 3)

    let fresh = BurnRateCalculator.rate(events: events, window: nil, ceiling: ceiling, at: now)
    let partlyUsed = BurnRateCalculator.rate(events: events, window: window, ceiling: ceiling, at: now)

    #expect(fresh.headroomMinutes != nil)
    #expect(partlyUsed.headroomMinutes! < fresh.headroomMinutes!)
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

// MARK: - headroom must agree with the window

/// Headroom longer than the window is nonsense: at the reset it refills, so you
/// never run out. Report no figure rather than one that outlasts the countdown.
@Test func headroomNeverOutlastsTheWindow() {
    let now = t0.addingTimeInterval(600)
    let events = [event(0.05, output: 10), event(0.1, output: 10)]   // a trickle
    let rate = BurnRateCalculator.rate(
        events: events, window: nil,
        ceiling: Ceiling(weightedTokens: 100_000_000, observedWindows: 3),
        at: now, currentPercent: 14,
        windowEndsAt: now.addingTimeInterval(157 * 60)
    )
    #expect(rate.headroomMinutes == nil)
    #expect(rate.percentPerHour != nil)      // the rate itself is still known
}

@Test func headroomIsReportedWhenItFitsInsideTheWindow() {
    let now = t0.addingTimeInterval(600)
    let events = [event(0.05, output: 200_000), event(0.15, output: 200_000)]
    let rate = BurnRateCalculator.rate(
        events: events, window: nil, ceiling: .unknown, at: now,
        currentPercent: 90, weightedPerPercent: 900_000,
        windowEndsAt: now.addingTimeInterval(300 * 60)
    )
    let headroom = try! #require(rate.headroomMinutes)
    #expect(headroom > 0 && headroom < 300)
}

/// The calibrated conversion is measured against the real limit; the ceiling is
/// only ever inferred. When both exist the calibration wins.
@Test func calibrationBeatsTheInferredCeiling() {
    let now = t0.addingTimeInterval(600)
    let events = [event(0.05, output: 100_000)]
    let calibrated = BurnRateCalculator.rate(
        events: events, window: nil,
        ceiling: Ceiling(weightedTokens: 50_000_000, observedWindows: 5),
        at: now, currentPercent: 10, weightedPerPercent: 10_000
    )
    let inferred = BurnRateCalculator.rate(
        events: events, window: nil,
        ceiling: Ceiling(weightedTokens: 50_000_000, observedWindows: 5),
        at: now, currentPercent: 10
    )
    #expect(calibrated.percentPerHour != inferred.percentPerHour)
}

/// Headroom is measured from the figure on screen, not from a second opinion.
@Test func headroomFollowsTheReportedPercentage() {
    let now = t0.addingTimeInterval(600)
    let events = [event(0.05, output: 100_000)]
    let nearlyFull = BurnRateCalculator.rate(
        events: events, window: nil, ceiling: .unknown, at: now,
        currentPercent: 95, weightedPerPercent: 10_000
    )
    let nearlyEmpty = BurnRateCalculator.rate(
        events: events, window: nil, ceiling: .unknown, at: now,
        currentPercent: 5, weightedPerPercent: 10_000
    )
    #expect(nearlyFull.headroomMinutes! < nearlyEmpty.headroomMinutes!)
}

// MARK: - the activity dot

/// The dot answers "is anything happening right now", which is not the same
/// question as "is a window open" — a window stays open for hours after you stop.
@Test func burningFollowsRecentLogGrowthNotTheOpenWindow() {
    let now = t0.addingTimeInterval(3 * 3600)      // three hours into the window
    let stale = SnapshotBuilder.build(
        source: .claude, limits: nil, events: [event(0)], ceiling: .unknown, at: now
    )
    #expect(stale.isActive)              // the 5-hour window is still open
    #expect(stale.isBurning == false)    // but nothing has been logged for hours
}

@Test func freshLogLinesLightTheDot() {
    let now = t0.addingTimeInterval(600)
    let justNow = SnapshotBuilder.build(
        source: .claude, limits: nil,
        events: [event(600.0 / 3600)],   // logged seconds ago
        ceiling: .unknown, at: now
    )
    #expect(justNow.isBurning)
}

@Test func theDotGoesOutAfterTheBurningWindow() {
    let now = t0.addingTimeInterval(600)
    let inside = SnapshotBuilder.build(
        source: .claude, limits: nil,
        events: [event((600 - SnapshotBuilder.burningWindow + 1) / 3600)],
        ceiling: .unknown, at: now
    )
    let outside = SnapshotBuilder.build(
        source: .claude, limits: nil,
        events: [event((600 - SnapshotBuilder.burningWindow - 1) / 3600)],
        ceiling: .unknown, at: now
    )
    #expect(inside.isBurning)
    #expect(outside.isBurning == false)
}

@Test func nothingLoggedIsNotBurning() {
    let empty = SnapshotBuilder.build(
        source: .claude, limits: nil, events: [], ceiling: .unknown, at: t0
    )
    #expect(empty.isBurning == false)
    #expect(empty.lastActivity == nil)
}
