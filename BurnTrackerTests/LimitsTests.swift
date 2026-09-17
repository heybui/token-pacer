import Foundation
import Testing
@testable import BurnTracker

private let t0 = Date(timeIntervalSince1970: 1_789_000_000)
private func at(_ minutes: Double) -> Date { t0.addingTimeInterval(minutes * 60) }

// MARK: - when a run is worth spawning a process for

@Test func theFirstRunHappensAtLaunch() {
    #expect(PanelPoller().shouldRun(at: at(0)))
}

@Test func anIdleMachineNeverRuns() {
    var poller = PanelPoller()
    poller.ran(at: at(0))
    #expect(poller.shouldRun(at: at(600)) == false)     // ten hours, no tokens
}

@Test func activityInsideTheFloorStillWaits() {
    var poller = PanelPoller()
    poller.ran(at: at(0))
    poller.record(weighted: 50_000)
    #expect(poller.shouldRun(at: at(4)) == false)
    #expect(poller.shouldRun(at: at(5)))
}

@Test func aRunClearsTheActivitySignal() {
    var poller = PanelPoller()
    poller.ran(at: at(0))
    poller.record(weighted: 50_000)
    poller.ran(at: at(5))
    #expect(poller.hasNewActivity == false)
    #expect(poller.shouldRun(at: at(30)) == false)
}

/// A CLI that is broken or mid-upgrade must not be respawned all day.
@Test func failuresBackOffInsteadOfRetryingEveryFloor() {
    var poller = PanelPoller()
    poller.ran(at: at(0))
    poller.record(weighted: 50_000)
    poller.failed(at: at(5))

    #expect(poller.shouldRun(at: at(14)) == false)       // 2 × 5 minutes
    #expect(poller.shouldRun(at: at(15)))

    poller.failed(at: at(15))
    #expect(poller.shouldRun(at: at(30)) == false)       // 4 × 5 minutes
    #expect(poller.shouldRun(at: at(35)))
}

@Test func aSuccessfulRunClearsTheBackoff() {
    var poller = PanelPoller()
    poller.ran(at: at(0))
    poller.record(weighted: 50_000)
    poller.failed(at: at(5))
    poller.record(weighted: 50_000)
    poller.ran(at: at(20))

    poller.record(weighted: 50_000)
    #expect(poller.shouldRun(at: at(25)))
}

/// Eight hours of continuous work: one process every five minutes, not one per tick.
@Test func continuousWorkIsThrottledToOneRunPerFloor() {
    var poller = PanelPoller()
    var runs = 0
    for tick in stride(from: 0.0, to: 480, by: 5.0 / 60) {   // a 5s tick, 8 hours
        poller.record(weighted: 200)
        if poller.shouldRun(at: at(tick)) {
            poller.ran(at: at(tick))
            runs += 1
        }
    }
    #expect(runs == 96)                                       // launch, then 0:05 … 7:55
}

// MARK: - surviving a window reset

@Test func aRolledWindowLandsOnTheNextReset() {
    let window = RateLimitWindow(usedPercent: 88, windowMinutes: 300, resetsAt: at(0))
    let rolled = window.rolled(to: at(10), usedPercent: 0)
    #expect(rolled.resetsAt == at(300))
    #expect(rolled.usedPercent == 0)
}

/// Away for a day, the window has rolled many times. Land on the current one,
/// not the one that followed the last reading.
@Test func rollingSkipsWholePeriods() {
    let window = RateLimitWindow(usedPercent: 88, windowMinutes: 300, resetsAt: at(0))
    let rolled = window.rolled(to: at(1_000), usedPercent: 0)
    #expect(rolled.resetsAt > at(1_000))
    #expect(rolled.resetsAt == at(1_200))     // 0 + 4 × 300
}

@Test func aWindowThatHasNotResetIsLeftAlone() {
    let window = RateLimitWindow(usedPercent: 40, windowMinutes: 300, resetsAt: at(300))
    let rolled = window.rolled(to: at(10), usedPercent: 42)
    #expect(rolled.resetsAt == at(300))
    #expect(rolled.usedPercent == 42)         // the fresher figure still lands
}

/// The whole point: a reset must not drop the source back to inference just
/// because the next run is minutes away. The window emptying needs no reading.
@Test func theReportedFigureSurvivesAReset() {
    let anchored = RateLimitWindow(usedPercent: 88, windowMinutes: 300, resetsAt: at(300))
    let now = at(310)
    let snapshot = SnapshotBuilder.build(
        source: .claude,
        limits: RateLimits(
            primary: anchored.rolled(to: now, usedPercent: 0),
            secondary: nil, planType: nil, observedAt: at(0)
        ),
        events: [], ceiling: Ceiling(weightedTokens: 1_000_000, observedWindows: 9), at: now
    )
    #expect(snapshot.origin == .authoritative)
    #expect(snapshot.sessionPercent == 0)
    #expect(snapshot.resetsAt == at(600))
}

@Test func theSnapshotCarriesWhenTheFigureWasConfirmed() {
    let limits = RateLimits(
        primary: RateLimitWindow(usedPercent: 22, windowMinutes: 300, resetsAt: at(300)),
        secondary: nil, planType: nil, observedAt: at(0)
    )
    let snapshot = SnapshotBuilder.build(
        source: .claude, limits: limits, events: [], ceiling: .unknown, at: at(6)
    )
    #expect(snapshot.confirmedAt == at(0))
}

// MARK: - what the store does between readings

/// A source with no logs at all, so the store's only input is the panel.
private actor SilentSource: UsageSource {
    nonisolated let id: SourceID = .claude
    func poll() throws -> SourceSnapshot { SourceSnapshot(source: id, events: [], limits: nil) }
    func restore(cursors: [String: JSONLReader.Cursor], seen: Set<String>) {}
    func cursors() -> [String: JSONLReader.Cursor] { [:] }
}

@MainActor
private func store(reading: @escaping ClaudeUsagePanel.Reader) async -> UsageStore {
    let store = UsageStore(
        sources: [SilentSource()], interval: 3600,
        usagePanel: ClaudeUsagePanel(read: reading), archive: nil
    )
    await store.refresh()
    // The reading is launched, not awaited: give it the tick it lands on.
    for _ in 0..<50 where store.isReadingLimits {
        try? await Task.sleep(for: .milliseconds(20))
    }
    return store
}

/// The two windows expire independently. Gating the weekly roll on the session
/// having reset too dropped the weekly figure every Monday at 1am — and at 1am
/// there is no activity to earn the reading that would bring it back.
///
/// Anchored on the wall clock, not on `t0`: the panel prints no year, so the
/// parser resolves a stamp against the real date, and a fixture dated 2026 would
/// land in the past and roll forward a year.
@MainActor
@Test func theWeeklyWindowRollsOnItsOwnReset() async {
    let base = Date()
    let panel = """
    Current session 40% used Resets \(clock(base.addingTimeInterval(10 * 3600))) (UTC) \
    Current week (all models) 80% used Resets \(clock(base.addingTimeInterval(5 * 60))) (UTC)
    """
    let store = await store(reading: { panel })

    // Ten minutes on: the weekly window has reset, the session window has not.
    await store.refresh(now: base.addingTimeInterval(600))
    #expect(store.snapshot?.sessionPercent == 40)      // untouched
    #expect(store.snapshot?.weeklyPercent == 0)        // rolled, not dropped
    #expect(store.snapshot?.weeklyResetsAt != nil)
}

/// A healthy log poll runs every 5s; a reading happens every 5 minutes at most,
/// and not at all while backed off. The message has to survive the ticks in
/// between or it flashes once and is gone.
@MainActor
@Test func aLimitsFailureStaysOnScreenBetweenReadings() async {
    let store = await store(reading: { throw PanelError.cliNotFound })
    #expect(store.errors[.claude] == PanelError.cliNotFound.message)

    // Several ticks with no reading — cliNotFound is fatal, so there is no retry.
    for tick in 1...3 { await store.refresh(now: Date().addingTimeInterval(Double(tick) * 5)) }
    #expect(store.errors[.claude] == PanelError.cliNotFound.message)
}

/// `h:mma (UTC)`, the shape the panel prints.
private func clock(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "UTC")
    formatter.dateFormat = "MMM d h:mma"
    return formatter.string(from: date)
}
