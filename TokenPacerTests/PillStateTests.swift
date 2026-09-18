import Foundation
import SwiftUI
import Testing
@testable import TokenPacer

private let now = Date(timeIntervalSince1970: 1_789_000_000)

private func snapshot(
    percent: Double? = 40, lastActivity: Date? = now, weekly: Double? = nil
) -> UsageSnapshot {
    var s = UsageSnapshot(source: .claude)
    s.sessionPercent = percent
    s.weeklyPercent = weekly
    s.lastActivity = lastActivity
    s.sessionTokens = 1000
    return s
}

private func resolve(_ inputs: PillInputs) -> PillState {
    PillStateResolver.resolve(inputs, at: now)
}

@MainActor @Test func steadyUsageCollapses() {
    #expect(resolve(PillInputs(snapshot: snapshot())) == .collapsed)
}

@MainActor @Test func hoveringOpensTheCard() {
    #expect(resolve(PillInputs(snapshot: snapshot(), pointerInside: true)) == .hover)
}

/// "No Claude activity: the pill is gone entirely, notch reads as stock hardware."
@MainActor @Test func silenceWithdrawsThePill() {
    let quiet = snapshot(lastActivity: now.addingTimeInterval(-20 * 60))
    #expect(resolve(PillInputs(snapshot: quiet)) == .dormant)
}

@MainActor @Test func nothingReadYetIsAlsoDormant() {
    #expect(resolve(PillInputs(snapshot: nil)) == .dormant)
    #expect(resolve(PillInputs(snapshot: snapshot(lastActivity: nil))) == .dormant)
}

/// The ghost is the only way to reach the menu while dormant.
@MainActor @Test func hoveringDeadSpaceRevealsTheGhost() {
    let quiet = snapshot(lastActivity: now.addingTimeInterval(-20 * 60))
    #expect(resolve(PillInputs(snapshot: quiet, pointerInside: true)) == .ghost)
}

@MainActor @Test func aFullWindowGoesToExhausted() {
    #expect(resolve(PillInputs(snapshot: snapshot(percent: 100))) == .exhausted)
}

@MainActor @Test func theWarningFiresOnceThenStandsDown() {
    let hot = snapshot(percent: 93)
    #expect(resolve(PillInputs(snapshot: hot)) == .warning)
    #expect(resolve(PillInputs(snapshot: hot, warningAcknowledged: true)) == .collapsed)
}

@MainActor @Test func theWarningRespectsItsThreshold() {
    let inputs = PillInputs(snapshot: snapshot(percent: 80), criticalAt: 75)
    #expect(resolve(inputs) == .warning)
    #expect(resolve(PillInputs(snapshot: snapshot(percent: 80), criticalAt: 90)) == .collapsed)
}

/// Off is off: no figures and no alerts, and hovering does not reveal any.
@MainActor @Test func pauseBeatsEverything() {
    let inputs = PillInputs(
        snapshot: snapshot(percent: 100), pointerInside: true, isPinned: true, isPaused: true
    )
    #expect(resolve(inputs) == .paused)
}

@MainActor @Test func pinningHoldsThePanelOpen() {
    let inputs = PillInputs(snapshot: snapshot(), isPinned: true)
    #expect(resolve(inputs) == .pinned)
    // Even with nothing to show, a pinned panel stays pinned.
    #expect(resolve(PillInputs(snapshot: nil, isPinned: true)) == .pinned)
}

/// Hovering an exhausted pill must still open the card rather than sticking.
@MainActor @Test func hoverWinsOverExhausted() {
    let inputs = PillInputs(snapshot: snapshot(percent: 100), pointerInside: true)
    #expect(resolve(inputs) == .hover)
}

@MainActor @Test func everyStateHasDistinctGeometry() {
    // Guards against a new state silently inheriting another's shell.
    let sizes = Set(PillState.allCases.map { "\($0.size.width)x\($0.size.height)x\($0.cornerRadius)" })
    #expect(sizes.count >= 4)
    #expect(PillState.dormant.size.height == 3)
    #expect(PillState.pinned.size == CGSize(width: 752, height: 540))
}

// MARK: - model

@MainActor @Test func hoveringAcknowledgesTheWarning() {
    let model = PillModel()
    model.update(snapshot: snapshot(percent: 95), at: now)
    #expect(model.state == .warning)

    model.setPointerInside(true, at: now)
    #expect(model.state == .hover)

    model.setPointerInside(false, at: now)
    #expect(model.state == .collapsed)   // acknowledged, does not re-fire
}

/// A reset clears the acknowledgement so the next window warns again.
@MainActor @Test func theNextWindowWarnsAgain() {
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
@MainActor @Test func pinningAcknowledgesTheWarningLikeHoverDoes() {
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
@MainActor @Test func amountsAreShownAtTheirCurrencysPrecision() {
    #expect(Format.amount(Money(amountMinor: 1199, currency: "SGD", exponent: 2))
        .contains("11"))
    #expect(Format.amount(Money(amountMinor: 1199, currency: "JPY", exponent: 0))
        == "1.199" || Format.amount(Money(amountMinor: 1199, currency: "JPY", exponent: 0))
        == "1,199")
    #expect(Format.amount(nil) == "—")
}

@MainActor @Test func spendProjectionScalesTheMonthElapsed() {
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

@MainActor @Test func theMenuEnlargesTheClickableArea() {
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

@MainActor @Test func theMenuLeavesWithThePointer() {
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
@MainActor @Test func theMenuOpensOverThePinnedPanelToo() {
    let model = PillModel()
    model.menuHeight = PillState.menuHeight(items: 6)
    model.update(snapshot: snapshot(), at: now)
    model.setPinned(true, at: now)
    model.toggleMenu()

    #expect(model.isMenuOpen)
    #expect(model.liveSize.height <= PillState.hostSize.height)
}


// MARK: - the ghost's exit

/// "Fades out ~400ms after the pointer leaves the notch." Crossing the notch on
/// the way somewhere else should not snap the pill away mid-glance.
@MainActor @Test func theGhostOutstaysThePointer() {
    let quiet = snapshot(lastActivity: now.addingTimeInterval(-20 * 60))
    let leaving = PillInputs(
        snapshot: quiet, pointerInside: false,
        ghostHeldUntil: now.addingTimeInterval(PillStateResolver.ghostFade)
    )

    #expect(resolve(leaving) == .ghost)
    #expect(PillStateResolver.resolve(
        leaving, at: now.addingTimeInterval(PillStateResolver.ghostFade + 0.1)
    ) == .dormant)
}

@MainActor @Test func leavingTheGhostSchedulesItsWithdrawal() async {
    let model = PillModel()
    let quiet = snapshot(lastActivity: now.addingTimeInterval(-20 * 60))
    model.update(snapshot: quiet, at: now)
    model.setPointerInside(true, at: now)
    #expect(model.state == .ghost)

    // Still a ghost the instant the pointer leaves…
    model.setPointerInside(false, at: now)
    #expect(model.state == .ghost)

    // …and gone once the hold expires, without waiting for the 5s poll.
    try? await Task.sleep(for: .seconds(PillStateResolver.ghostFade + 0.2))
    #expect(model.state == .dormant)
}

private func trackPoints(_ track: ShellTrack, in rect: CGRect) -> ([CGPoint], Int) {
    var points: [CGPoint] = []
    var subpaths = 0
    track.path(in: rect).forEach { element in
        switch element {
        case .move(let p): subpaths += 1; points.append(p)
        case .line(let p): points.append(p)
        case .quadCurve(let p, let c): points.append(contentsOf: [c, p])
        case .curve(let p, let c1, let c2): points.append(contentsOf: [c1, c2, p])
        case .closeSubpath: Issue.record("the track is open, or the light laps the notch")
        }
    }
    return (points, subpaths)
}

/// The light runs left to right along an open track. The top edge is the one
/// stretch it must never touch: that edge sits against the notch, where half the
/// glow is behind the hardware and the rest reads as a seam.
@MainActor @Test func theTrackStartsAndEndsAtTheTopAndNeverCrossesIt() {
    let rect = CGRect(x: 0, y: 0, width: 404, height: 136)
    let (points, subpaths) = trackPoints(ShellTrack(cornerRadius: 26, inset: 0.75), in: rect)

    #expect(subpaths == 1)          // one straight sweep, never a climb round the notch
    #expect(points.first!.y == rect.minY)                    // enters top-left
    #expect(points.last!.y == rect.minY)                     // leaves top-right
    #expect(points.first!.x < points.last!.x)                // left to right
    // Everything in between is below the top edge, by a corner radius or more.
    #expect(points.dropFirst().dropLast().allSatisfy { $0.y >= 26 })
}


/// The shell is only ever shadowed when it floats. Every small state sits flush
/// in the menu bar row, continuous with the notch's own black, and a 31pt shadow
/// under one reads as a seam across the top of the screen.
@MainActor @Test func onlyTheFloatingStatesCastAShadow() {
    for state in PillState.allCases {
        #expect(state.castsShadow == !(state.fillsFlanks || state == .dormant))
    }
    #expect(PillState.collapsed.castsShadow == false)
    #expect(PillState.hover.castsShadow)
    #expect(PillState.pinned.castsShadow)

    // The host still has to clear the shadow of the states that do cast one.
    #expect(PillState.hostSize.height - PillState.pinned.size.height
            >= PillState.shadowReach + PillState.shadowOffsetY)
}

// MARK: - the wings measure what is in them

/// The flank is the wider wing, and both get it: the shell is centred on the
/// notch, so unequal sides would sit the hardware off-centre in its own shell.
@MainActor @Test func bothWingsTakeTheWiderSide() {
    let wide = PillState.Wings(mark: .capsuleBar, headline: "100%", tail: "12d 07h")
    let narrow = PillState.Wings(mark: .ringWings, headline: "4%", tail: "1h 02m")
    #expect(wide.flank > narrow.flank)

    let band = NotchBand(notchWidth: 200, height: 39)
    // Symmetric by construction: the drawn width is the notch plus two equal flanks.
    #expect(PillState.collapsed.size(around: band, wings: wide).width
        == band.notchWidth + 2 * wide.flank)
}

/// The ring is half the bar's width, and the band should show it.
@MainActor @Test func aNarrowerMarkNarrowsTheBand() {
    let band = NotchBand(notchWidth: 200, height: 39)
    let bar = PillState.Wings(mark: .capsuleBar)
    let ring = PillState.Wings(mark: .ringWings)
    #expect(PillState.collapsed.size(around: band, wings: ring).width
        < PillState.collapsed.size(around: band, wings: bar).width)
}

/// The window is resized by the controller and the shell by a spring inside it,
/// so the host reserves the widest the wings can ever be, not the widest they are.
@MainActor @Test func theHostReservesTheWidestWings() {
    let band = NotchBand(notchWidth: 200, height: 39)
    let host = PillState.hostSize(around: band).width
    for mark in Mark.allCases {
        let wings = PillState.Wings(mark: mark, headline: "1.25M", tail: "12d 07h", hasBadge: true)
        #expect(host >= band.notchWidth + 2 * wings.flank)
    }
}

/// The bug this pins: the flank was measured from the figures alone, leaving out
/// the row's own spacing either side of the notch, so a six-character countdown
/// drew through its gutter and a seven-character one would have run off the end.
@MainActor @Test func theFlankLeavesRoomForTheCountdownAndItsGutter() {
    for mark in Mark.allCases {
        let wings = PillState.Wings(mark: mark, headline: "1.25M", tail: "12d 07h", hasBadge: true)
        let tail = Typography.monoWidth("12d 07h", size: 11.5)
        #expect(wings.flank >= tail + PillState.trailingGutter + PillState.notchClearance)
    }
}

/// And that the figures are asked of the font rather than guessed at: a digit
/// takes the odometer's own cell, everything else takes what it actually draws.
@MainActor @Test func monoWidthMeasuresLettersRatherThanAssumingThem() {
    let digits = Typography.monoWidth("123456", size: 11.5)
    let letters = Typography.monoWidth("abcdef", size: 11.5)
    // Summed six times rather than multiplied once, so compare as the machine
    // stores it and not as the arithmetic reads.
    #expect(abs(digits - 6 * 11.5 * 0.6) < 0.001)
    #expect(letters > 0 && letters != digits)
}
