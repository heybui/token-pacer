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

/// The exponent is the currency's, not two by convention: 1199 yen is 1199 yen.
@Test func amountsAreShownAtTheirCurrencysPrecision() {
    #expect(Format.amount(Money(amountMinor: 1199, currency: "SGD", exponent: 2))
        .contains("11"))
    #expect(Format.amount(Money(amountMinor: 1199, currency: "JPY", exponent: 0))
        == "1.199" || Format.amount(Money(amountMinor: 1199, currency: "JPY", exponent: 0))
        == "1,199")
    #expect(Format.amount(nil) == "—")
}

@Test func spendProjectionScalesTheMonthElapsed() {
    var utc = Calendar(identifier: .gregorian)
    utc.timeZone = TimeZone(identifier: "UTC")!
    // 15 January, S$11.99 spent: half the month gone, S$24.78 for a 31-day month.
    let midJanuary = utc.date(from: DateComponents(year: 2026, month: 1, day: 15))!
    let spent = Money(amountMinor: 1199, currency: "SGD", exponent: 2)

    let projected = Format.projection(used: spent, now: midJanuary, calendar: utc)
    // 1199 / 15 × 31 = 2478 minor units, shown at the currency's precision.
    #expect(projected.contains("24"))
    #expect(projected.hasPrefix("projected"))
    #expect(Format.projection(used: nil, now: midJanuary, calendar: utc)
        == "no spend yet this month")
}

// MARK: - context menu

@MainActor
@Test func theMenuEnlargesTheClickableArea() {
    let model = PillModel()
    model.menuHeight = PillState.menuHeight(items: 6)
    model.update(snapshot: snapshot(), at: now)
    #expect(model.liveSize == PillState.collapsed.size)

    model.toggleMenu()
    // Otherwise the host passes clicks on the menu straight through to whatever
    // is behind the notch. The collapsed pill is the wider of the two, so only
    // the height grows here.
    #expect(model.liveSize.width == PillState.collapsed.size.width)
    #expect(model.liveSize.height
        == PillState.collapsed.size.height + PillState.menuGap + model.menuHeight)
}

@MainActor
@Test func theMenuLeavesWithThePointer() {
    let model = PillModel()
    model.update(snapshot: snapshot(), at: now)
    model.setPointerInside(true, at: now)
    model.toggleMenu()
    #expect(model.isMenuOpen)

    model.setPointerInside(false, at: now)
    #expect(!model.isMenuOpen)
}

/// Pausing or quitting from the panel should not cost you the panel, so the menu
/// opens over it too — and the host reserves the drop for it.
@MainActor
@Test func theMenuOpensOverThePinnedPanelToo() {
    let model = PillModel()
    model.menuHeight = PillState.menuHeight(items: 6)
    model.update(snapshot: snapshot(), at: now)
    model.setPinned(true, at: now)
    model.toggleMenu()

    #expect(model.isMenuOpen)
    #expect(model.liveSize.height <= PillState.hostSize.height)
}

@Test func theCopiedSummaryReadsAsASentence() {
    var s = snapshot(percent: 62, weekly: 41)
    s.resetsAt = now.addingTimeInterval(2 * 3600 + 4 * 60)
    s.burn = BurnRate(weightedPerHour: 1000, percentPerHour: 18, headroomMinutes: 45)

    #expect(Format.usageSummary(s, at: now) == """
        Claude Code · 62% of the 5-hour window, resets in 2h 04m
        Week 41% · 18%/hr · ~45 min headroom
        """)
    #expect(Format.usageSummary(nil).hasPrefix("Burn Tracker is still"))
}
