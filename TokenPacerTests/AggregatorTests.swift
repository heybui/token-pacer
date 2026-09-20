import Foundation
import Testing
@testable import TokenPacer

private let t0 = Date(timeIntervalSince1970: 1_789_000_000)
private let utc: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "UTC")!
    return c
}()

private func event(
    minutesAgo: Double, output: Int = 1000,
    model: String? = "claude-opus-5", project: String? = "demo",
    source: SourceID = .claude
) -> UsageEvent {
    UsageEvent(
        id: UUID().uuidString,
        source: source,
        timestamp: t0.addingTimeInterval(-minutesAgo * 60),
        model: model,
        project: project,
        sessionID: "s",
        counts: TokenCounts(input: 0, output: output)
    )
}

// MARK: - sparkline

@Test func sparklineBucketsByFiveMinutesOldestFirst() {
    // 2 minutes ago lands in the bucket in progress; 7 minutes ago the one before.
    let line = Aggregator.sparkline(
        events: [event(minutesAgo: 2, output: 1000), event(minutesAgo: 7, output: 500)],
        at: t0
    )
    #expect(line.count == Aggregator.bucketCount)
    #expect(line.last == 1.0)                    // the peak is the newest bucket
    #expect(line[Aggregator.bucketCount - 2] == 0.5)
    #expect(line.prefix(24).allSatisfy { $0 == 0 })
}

@Test func sparklineIgnoresEventsOlderThanTheStrip() {
    let line = Aggregator.sparkline(events: [event(minutesAgo: 131)], at: t0)
    #expect(line.allSatisfy { $0 == 0 })
}

@Test func anIdleStripIsZeroNotNaN() {
    let line = Aggregator.sparkline(events: [], at: t0)
    #expect(line == [Double](repeating: 0, count: Aggregator.bucketCount))
}

// MARK: - splits

@Test func sharesRankByWeightAndSumToTheSlice() {
    let rows = Aggregator.shares([
        event(minutesAgo: 1, output: 300, project: "api"),
        event(minutesAgo: 2, output: 100, project: "burner"),
    ]) { $0.project ?? "—" }

    #expect(rows.map(\.name) == ["api", "burner"])
    #expect(rows[0].share == 75)
    #expect(rows[1].share == 25)
}

@Test func sharesKeepOnlyTheTopRows() {
    let rows = Aggregator.shares(
        (1...5).map { event(minutesAgo: Double($0), output: $0 * 100, project: "p\($0)") }
    ) { $0.project ?? "—" }
    #expect(rows.count == Aggregator.splitRows)
    #expect(rows.map(\.name) == ["p5", "p4", "p3"])
}

@Test func splitsDescribeTheOpenWindowOnly() {
    let events = [event(minutesAgo: 400, project: "yesterday"), event(minutesAgo: 10, project: "now")]
    let window = SessionWindow(
        start: t0.addingTimeInterval(-3600), end: t0.addingTimeInterval(3600),
        counts: TokenCounts(input: 0, output: 1000), weighted: 5000,
        lastActivity: t0.addingTimeInterval(-600)
    )
    let panel = Aggregator.panel(
        events: events, window: DateInterval(start: window.start, end: window.end),
        at: t0, calendar: utc
    )
    #expect(panel.byProject.map(\.name) == ["now"])
}

@Test func withNoOpenWindowThereIsNothingToAttribute() {
    let panel = Aggregator.panel(events: [event(minutesAgo: 10)], window: nil, at: t0, calendar: utc)
    #expect(panel.byProject.isEmpty)
    #expect(panel.byModel.isEmpty)
    // The strip still has data: it describes the clock, not the window.
    #expect(panel.sparkline.contains { $0 > 0 })
}

// MARK: - history

@Test func historyRunsOldestToNewestAndIncludesQuietDays() {
    let rows = Aggregator.history(
        events: [event(minutesAgo: 0, output: 1000), event(minutesAgo: 60 * 48, output: 500)],
        at: t0, days: 3, calendar: utc
    )
    #expect(rows.count == 3)
    #expect(rows.map(\.percent) == [50, 0, 100])
    #expect(rows[0].day < rows[2].day)
}

@Test func anEmptyHistoryIsAllZeroDays() {
    let rows = Aggregator.history(events: [], at: t0, days: 7, calendar: utc)
    #expect(rows.count == 7)
    #expect(rows.allSatisfy { $0.percent == 0 })
}

// MARK: - names

@Test func modelNamesAreShortenedOnlyWhenTheyAreClaudes() {
    #expect(Aggregator.displayModel("claude-opus-5") == "Opus 5")
    #expect(Aggregator.displayModel("claude-haiku-4-5-20251001") == "Haiku 4 5 20251001")
    #expect(Aggregator.displayModel("gpt-5.6-terra") == "gpt-5.6-terra")
    #expect(Aggregator.displayModel(nil) == "unknown")
}
