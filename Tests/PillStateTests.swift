import Foundation
import Testing
@testable import BurnTracker

private let now = Date(timeIntervalSince1970: 1_789_000_000)

private func snapshot(
    percent: Double? = 40, lastActivity: Date? = now, weekly: Double? = nil
) -> UsageSnapshot {
    var s = UsageSnapshot(source: .claude)
    s.origin = percent == nil ? .unknown : .authoritative
    s.sessionPercent = percent
    s.weeklyPercent = weekly
    s.lastActivity = lastActivity
    s.sessionTokens = 1000
    return s
}

private func resolve(_ inputs: PillInputs) -> PillState {
    PillStateResolver.resolve(inputs, at: now)
}

@Test func steadyUsageCollapses() {
    #expect(resolve(PillInputs(snapshot: snapshot())) == .collapsed)
}

@Test func hoveringOpensTheCard() {
    #expect(resolve(PillInputs(snapshot: snapshot(), pointerInside: true)) == .hover)
}

/// "No Claude activity: the pill is gone entirely, notch reads as stock hardware."
@Test func silenceWithdrawsThePill() {
    let quiet = snapshot(lastActivity: now.addingTimeInterval(-20 * 60))
    #expect(resolve(PillInputs(snapshot: quiet)) == .dormant)
}

@Test func nothingReadYetIsAlsoDormant() {
    #expect(resolve(PillInputs(snapshot: nil)) == .dormant)
    #expect(resolve(PillInputs(snapshot: snapshot(lastActivity: nil))) == .dormant)
}

/// The ghost is the only way to reach the menu while dormant.
@Test func hoveringDeadSpaceRevealsTheGhost() {
    let quiet = snapshot(lastActivity: now.addingTimeInterval(-20 * 60))
    #expect(resolve(PillInputs(snapshot: quiet, pointerInside: true)) == .ghost)
}

@Test func aFullWindowGoesToExhausted() {
    #expect(resolve(PillInputs(snapshot: snapshot(percent: 100))) == .exhausted)
}

@Test func theWarningFiresOnceThenStandsDown() {
    let hot = snapshot(percent: 93)
    #expect(resolve(PillInputs(snapshot: hot)) == .warning)
    #expect(resolve(PillInputs(snapshot: hot, warningAcknowledged: true)) == .collapsed)
}

@Test func theWarningRespectsItsThreshold() {
    let inputs = PillInputs(snapshot: snapshot(percent: 80), criticalAt: 75)
    #expect(resolve(inputs) == .warning)
    #expect(resolve(PillInputs(snapshot: snapshot(percent: 80), criticalAt: 90)) == .collapsed)
}

/// Off is off: no figures and no alerts, and hovering does not reveal any.
@Test func pauseBeatsEverything() {
    let inputs = PillInputs(
        snapshot: snapshot(percent: 100), pointerInside: true, isPinned: true, isPaused: true
    )
    #expect(resolve(inputs) == .paused)
}

@Test func pinningHoldsThePanelOpen() {
    let inputs = PillInputs(snapshot: snapshot(), isPinned: true)
    #expect(resolve(inputs) == .pinned)
    // Even with nothing to show, a pinned panel stays pinned.
    #expect(resolve(PillInputs(snapshot: nil, isPinned: true)) == .pinned)
}

/// Hovering an exhausted pill must still open the card rather than sticking.
@Test func hoverWinsOverExhausted() {
    let inputs = PillInputs(snapshot: snapshot(percent: 100), pointerInside: true)
    #expect(resolve(inputs) == .hover)
}

@Test func everyStateHasDistinctGeometry() {
    // Guards against a new state silently inheriting another's shell.
    let sizes = Set(PillState.allCases.map { "\($0.size.width)x\($0.size.height)x\($0.cornerRadius)" })
    #expect(sizes.count >= 4)
    #expect(PillState.dormant.size.height == 3)
    #expect(PillState.pinned.size == CGSize(width: 752, height: 540))
}

// MARK: - model

@MainActor
@Test func hoveringAcknowledgesTheWarning() {
    let model = PillModel()
    model.update(snapshot: snapshot(percent: 95), at: now)
    #expect(model.state == .warning)

    model.setPointerInside(true, at: now)
    #expect(model.state == .hover)

    model.setPointerInside(false, at: now)
    #expect(model.state == .collapsed)   // acknowledged, does not re-fire
}

/// A reset clears the acknowledgement so the next window warns again.
@MainActor
@Test func theNextWindowWarnsAgain() {
    let model = PillModel()
    model.update(snapshot: snapshot(percent: 95), at: now)
    model.setPointerInside(true, at: now)
    model.setPointerInside(false, at: now)
    #expect(model.state == .collapsed)

    model.update(snapshot: snapshot(percent: 5), at: now)     // window reset
    model.update(snapshot: snapshot(percent: 95), at: now)    // and filled again
    #expect(model.state == .warning)
}

/// "Stays expanded until you mouse over it once" — opening the panel counts too,
/// otherwise the warning re-fires the moment the panel closes.
@MainActor
@Test func pinningAcknowledgesTheWarningLikeHoverDoes() {
    let model = PillModel()
    model.update(snapshot: snapshot(percent: 95), at: now)
    #expect(model.state == .warning)

    model.setPinned(true, at: now)
    #expect(model.state == .pinned)

    model.setPinned(false, at: now)
    #expect(model.state == .collapsed)
}

// MARK: - panel formatting

@Test func historyBlocksFillProportionally() {
    #expect(Format.blocks(0) == "░░░░░░░░░░")
    #expect(Format.blocks(100) == "██████████")
    #expect(Format.blocks(64) == "██████░░░░")
    // Never overruns, whatever the input.
    #expect(Format.blocks(140).count == 10)
    #expect(Format.blocks(-5) == "░░░░░░░░░░")
}

@Test func historyLabelsNameTheDayThenCountBack() {
    var utc = Calendar(identifier: .gregorian)
    utc.timeZone = TimeZone(identifier: "UTC")!
    let yesterday = now.addingTimeInterval(-24 * 3600)

    #expect(Format.historyLabel(now, compact: false, from: now, calendar: utc) == "today")
    #expect(Format.historyLabel(yesterday, compact: false, from: now, calendar: utc) == "D-01")
    #expect(Format.historyLabel(yesterday, compact: true, from: now, calendar: utc).count == 3)
}

@Test func spendProjectionScalesTheMonthElapsed() {
    var utc = Calendar(identifier: .gregorian)
    utc.timeZone = TimeZone(identifier: "UTC")!
    // 15 January, $150 spent: half the month gone, $310 for a 31-day month.
    let midJanuary = utc.date(from: DateComponents(year: 2026, month: 1, day: 15))!
    #expect(Format.projection(used: 150, now: midJanuary, calendar: utc)
        == "projected $310 by month end")
    #expect(Format.projection(used: 0, now: midJanuary, calendar: utc)
        == "no spend yet this month")
}
