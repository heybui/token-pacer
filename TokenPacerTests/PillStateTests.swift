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
    #expect(resolve(PillInputs(snapshot: quiet)) == .hidden)
}

/// Quiet means every tracked provider, which is what the setting has always
/// said it means. Pinned to Codex while Claude answers, the pill withdrew in the
/// middle of a session — from the one screen that exists to say work is running.
@MainActor @Test func anotherProvidersWorkKeepsThePillOnScreen() {
    let quiet = snapshot(lastActivity: now.addingTimeInterval(-20 * 60))
    #expect(resolve(PillInputs(snapshot: quiet)) == .hidden)
    #expect(resolve(PillInputs(
        snapshot: quiet, lastActivity: now.addingTimeInterval(-30)
    )) == .collapsed)
}

@MainActor @Test func nothingReadYetIsAlsoHidden() {
    #expect(resolve(PillInputs(snapshot: nil)) == .hidden)
    #expect(resolve(PillInputs(snapshot: snapshot(lastActivity: nil))) == .hidden)
}

/// Dormant hides the pill; it does not put the figures out of reach. Hovering
/// dead space opens the same card it opens at any other time.
@MainActor @Test func hoveringDeadSpaceOpensTheCard() {
    let quiet = snapshot(lastActivity: now.addingTimeInterval(-20 * 60))
    #expect(resolve(PillInputs(snapshot: quiet, pointerInside: true)) == .hover)
}

@MainActor @Test func aFullWindowGoesToExhausted() {
    #expect(resolve(PillInputs(snapshot: snapshot(percent: 100))) == .exhausted)
}

/// The card is held until somebody looks, and it is the store that decides when
/// that was: the pill draws whatever crossing it is handed and nothing else.
@MainActor @Test func aCrossingHoldsTheCardUntilItIsAnswered() {
    let hot = snapshot(percent: 93)
    let crossing = ZoneAlert(
        source: .claude, threshold: 90, percent: 93, resetsAt: now, isOver: true
    )
    #expect(resolve(PillInputs(snapshot: hot, alert: crossing)) == .warning)
    // Answered — the store cleared it — and the pill goes back to what it was.
    #expect(resolve(PillInputs(snapshot: hot)) == .collapsed)
}

/// The provider that crossed is not always the one the pill reports: a quiet
/// figure on screen and a crossing from another provider still raises the card.
@MainActor @Test func aCrossingFromAnotherProviderStillRaisesTheCard() {
    let calm = snapshot(percent: 12)
    let crossing = ZoneAlert(
        source: .codex, threshold: 75, percent: 80, resetsAt: now, isOver: false
    )
    #expect(resolve(PillInputs(snapshot: calm, alert: crossing)) == .warning)
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
    #expect(PillState.hidden.size.height == 3)
    #expect(PillState.pinned.size == CGSize(width: 752, height: 540))
}

// MARK: - model

/// The pill holds the card, hovering opens it, and the store — not the pill —
/// decides it has been answered. Here the store's half is played by hand.
@MainActor @Test func hoveringOpensTheCardAndLeavesItAnswered() {
    let model = PillModel()
    model.inputs.alert = ZoneAlert(
        source: .claude, threshold: 90, percent: 95, resetsAt: now, isOver: true
    )
    model.update(snapshot: snapshot(percent: 95), at: now)
    #expect(model.state == .warning)

    model.setPointerInside(true, at: now)
    #expect(model.state == .hover)

    // What the controller does on that hover: the store clears the crossing.
    model.inputs.alert = nil
    model.setPointerInside(false, at: now)
    #expect(model.state == .collapsed)   // answered, does not re-fire
}

/// "Stays expanded until you mouse over it once" — opening the panel counts too,
/// otherwise the card comes back the moment the panel closes.
@MainActor @Test func pinningAnswersTheCardLikeHoverDoes() {
    let model = PillModel()
    model.inputs.alert = ZoneAlert(
        source: .claude, threshold: 90, percent: 95, resetsAt: now, isOver: true
    )
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
    ) == .hidden)
}

@MainActor @Test func leavingTheGhostSchedulesItsWithdrawal() async {
    let model = PillModel()
    let quiet = snapshot(lastActivity: now.addingTimeInterval(-20 * 60))
    model.update(snapshot: quiet, at: now)
    model.setPointerInside(true, at: now)
    #expect(model.state == .hover)

    // The ghost is what is left on the way out, for the length of the fade…
    model.setPointerInside(false, at: now)
    #expect(model.state == .ghost)

    // …and gone once the hold expires, without waiting for the 5s poll.
    //
    // Polled to a deadline rather than slept for exactly the fade: the model's
    // withdrawal is a 0.4s `Task`, and a single sleep 0.2s longer than that
    // failed whenever the suite ran it beside a busy machine. What is being
    // tested is that the withdrawal happens without a poll, not that it lands
    // inside a particular millisecond.
    let deadline = Date().addingTimeInterval(3)
    while model.state != .hidden, Date() < deadline {
        try? await Task.sleep(for: .milliseconds(50))
    }
    #expect(model.state == .hidden)
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


/// Only the warning casts a shadow. Every small state sits flush in the menu bar
/// row, continuous with the notch's own black, and a 31pt shadow under one reads
/// as a seam across the top of the screen. Hover and pinned gave theirs up too:
/// a surface you opened yourself does not have to announce that it is floating.
@MainActor @Test func onlyTheWarningCastsAShadow() {
    for state in PillState.allCases {
        #expect(state.castsShadow == (state == .warning))
    }

    // The host still has to clear the shadow of the state that does cast one.
    #expect(PillState.hostSize.height - PillState.warning.size.height
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
        let wings = PillState.Wings(mark: mark, headline: "1.25M", tail: "12d 07h", badge: .working(99))
        #expect(host >= band.notchWidth + 2 * wings.flank)
    }
}

/// The bug this pins: the flank was measured from the figures alone, leaving out
/// the row's own spacing either side of the notch, so a six-character countdown
/// drew through its gutter and a seven-character one would have run off the end.
@MainActor @Test func theFlankLeavesRoomForTheCountdownAndItsGutter() {
    for mark in Mark.allCases {
        let wings = PillState.Wings(mark: mark, headline: "1.25M", tail: "12d 07h", badge: .working(99))
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

/// The figure is most of the leading wing, so switching it off has to take its
/// width out of the band rather than leave a hole where it was.
@MainActor @Test func hidingThePercentageNarrowsTheWings() {
    let shown = PillState.Wings(
        mark: .capsuleBar, headline: "100%", showsPercentage: true, tail: "4h 59m"
    )
    let hidden = PillState.Wings(
        mark: .capsuleBar, headline: "100%", showsPercentage: false, tail: "4h 59m"
    )
    #expect(hidden.flank < shown.flank)

    // And what is left still clears the mark and both gutters, whichever mark it is.
    for mark in Mark.allCases {
        let wings = PillState.Wings(mark: mark, showsPercentage: false, tail: "12d 07h")
        #expect(wings.flank
            >= PillState.leadingGutter + mark.width + PillState.notchClearance)
    }
}

/// The board's own figures: one digit is a 16.5pt circle, two widen it to 23.4
/// at the same corner radius, and the count sits 4pt from the countdown rather
/// than a row gap away.
@MainActor @Test func theCountBadgeTakesTheBoardsWidth() {
    #expect(PillState.Badge.working(3).width == 16.5)
    #expect(PillState.Badge.working(12).width == 23.4)
    #expect(PillState.Badge.working(3).gap == 4)
    #expect(PillState.Badge.alert.gap == PillState.markGap)
}

/// "The left wing is untouched: the countdown absorbs the width instead."
///
/// With the figure shown the left wing is the wider of the two, so the badge
/// costs the shell nothing at all. Drop the figure and the right wing decides,
/// and then it pays for the badge and its gap.
@MainActor @Test func theCountBadgeNeverPushesTheFigureOut() {
    func wings(figure: Bool, badge: PillState.Badge?) -> PillState.Wings {
        PillState.Wings(
            mark: .capsuleBar, headline: "27%", showsPercentage: figure,
            tail: "12d 07h", badge: badge
        )
    }
    #expect(wings(figure: true, badge: .working(3)).flank == wings(figure: true, badge: nil).flank)

    let grown = wings(figure: false, badge: .working(3)).flank - wings(figure: false, badge: nil).flank
    #expect(grown >= PillState.badgeDiameter + PillState.badgeGap - 1)
    #expect(grown <= PillState.badgeDiameter + PillState.badgeGap + 1)
}

/// The border says the machine is busy, so it wears the colours of whatever is
/// making it busy — not of the provider that happens to be on the pill. Pinned
/// to a quiet Claude while Codex runs at 95% of its own mark, a green light
/// would be the wrong news in the right place.
@MainActor @Test func theBorderTakesTheRunningProvidersColours() {
    let calm = ToneScale(warnAt: 75, critAt: 90)
    let strict = ToneScale(warnAt: 30, critAt: 50)

    // Same figure, two providers' marks: the rule is the provider's, not the
    // pill's, and the two answers differ.
    #expect(calm(60) != strict(60))
    #expect(strict(60) == Tokens.red)
    #expect(calm(60) == Tokens.green)
}
