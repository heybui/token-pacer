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
