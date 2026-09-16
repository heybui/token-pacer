import Foundation
import Testing
@testable import BurnTracker

private let t0 = Date(timeIntervalSince1970: 1_789_000_000)
private func at(_ minutes: Double) -> Date { t0.addingTimeInterval(minutes * 60) }

// MARK: - calibration

@Test func twoAnchorsMeasureTokensPerPercent() {
    var calibration = LimitsCalibration()
    calibration.observe(
        from: LimitsAnchor(utilization: 11, observedAt: at(0), resetsAt: at(300)),
        to: LimitsAnchor(utilization: 15, observedAt: at(10), resetsAt: at(300)),
        weightedBetween: 400_000
    )
    // 400k weighted tokens moved it 4 points.
    #expect(calibration.weightedPerPercent == 100_000)
    #expect(calibration.isCalibrated)
}

/// A pair spanning a reset measures nothing: the number fell without tokens being
/// returned. Learning from it would corrupt the conversion.
@Test func aPairSpanningAResetIsIgnored() {
    var calibration = LimitsCalibration()
    calibration.observe(
        from: LimitsAnchor(utilization: 88, observedAt: at(0), resetsAt: at(5)),
        to: LimitsAnchor(utilization: 3, observedAt: at(10), resetsAt: at(305)),
        weightedBetween: 250_000
    )
    #expect(calibration.isCalibrated == false)
    #expect(calibration.samples == 0)
}

@Test func anchorsWithNoLocalUsageAreIgnored() {
    var calibration = LimitsCalibration()
    // Usage from another machine or claude.ai moved the number; local logs saw
    // nothing, so this pair cannot calibrate anything.
    calibration.observe(
        from: LimitsAnchor(utilization: 10, observedAt: at(0), resetsAt: nil),
        to: LimitsAnchor(utilization: 14, observedAt: at(10), resetsAt: nil),
        weightedBetween: 0
    )
    #expect(calibration.isCalibrated == false)
}

@Test func laterSamplesPullTheEstimateWithoutDiscardingHistory() {
    var calibration = LimitsCalibration()
    let a = LimitsAnchor(utilization: 10, observedAt: at(0), resetsAt: nil)
    let b = LimitsAnchor(utilization: 20, observedAt: at(10), resetsAt: nil)
    calibration.observe(from: a, to: b, weightedBetween: 1_000_000)   // 100k/point
    calibration.observe(from: a, to: b, weightedBetween: 2_000_000)   // 200k/point

    let value = try! #require(calibration.weightedPerPercent)
    #expect(value > 100_000 && value < 200_000)
    #expect(calibration.samples == 2)
}

@Test func extrapolationWaitsForCalibration() {
    let calibration = LimitsCalibration()
    let anchor = LimitsAnchor(utilization: 11, observedAt: at(0), resetsAt: at(300))
    #expect(calibration.extrapolate(from: anchor, weightedSince: 500_000, at: at(5)) == nil)
}

@Test func extrapolationAddsLocalUsageToTheAnchor() {
    var calibration = LimitsCalibration()
    calibration.observe(
        from: LimitsAnchor(utilization: 10, observedAt: at(0), resetsAt: nil),
        to: LimitsAnchor(utilization: 20, observedAt: at(10), resetsAt: nil),
        weightedBetween: 1_000_000
    )
    let anchor = LimitsAnchor(utilization: 20, observedAt: at(10), resetsAt: at(300))
    // Half a million weighted tokens at 100k/point is five points on top of 20.
    #expect(calibration.extrapolate(from: anchor, weightedSince: 500_000, at: at(15)) == 25)
}

@Test func extrapolationRestartsFromZeroPastTheReset() {
    var calibration = LimitsCalibration()
    calibration.observe(
        from: LimitsAnchor(utilization: 10, observedAt: at(0), resetsAt: nil),
        to: LimitsAnchor(utilization: 20, observedAt: at(10), resetsAt: nil),
        weightedBetween: 1_000_000
    )
    let anchor = LimitsAnchor(utilization: 90, observedAt: at(10), resetsAt: at(20))
    let after = calibration.extrapolate(from: anchor, weightedSince: 200_000, at: at(25))
    #expect(after == 2)      // not 92
}

@Test func extrapolationIsClampedToOneHundred() {
    var calibration = LimitsCalibration()
    calibration.observe(
        from: LimitsAnchor(utilization: 10, observedAt: at(0), resetsAt: nil),
        to: LimitsAnchor(utilization: 20, observedAt: at(10), resetsAt: nil),
        weightedBetween: 1_000_000
    )
    let anchor = LimitsAnchor(utilization: 95, observedAt: at(10), resetsAt: at(300))
    #expect(calibration.extrapolate(from: anchor, weightedSince: 99_000_000, at: at(15)) == 100)
}

// MARK: - refresh policy

private func state(
    lastCall: Date?, activity: Bool = true, estimate: Double? = nil,
    confirmed: Double? = nil, resetsAt: Date? = nil,
    launched: Bool = true, woke: Bool = false
) -> LimitsRefreshPolicy.State {
    .init(
        lastCallAt: lastCall, lastConfirmedUtilization: confirmed, hasNewActivity: activity,
        estimate: estimate, anchorResetsAt: resetsAt, didLaunchFetch: launched, didWake: woke
    )
}

@Test func theFirstCallHappensAtLaunch() {
    let policy = LimitsRefreshPolicy()
    #expect(policy.reason(at: at(0), state: state(lastCall: nil, launched: false)) == .launch)
}

/// Utilization cannot move without local token events, so an idle machine is silent.
@Test func noLocalActivityMeansNoRequest() {
    let policy = LimitsRefreshPolicy()
    #expect(policy.reason(at: at(60), state: state(lastCall: at(0), activity: false)) == nil)
}

@Test func routineAnchorsAreTenMinutesApart() {
    let policy = LimitsRefreshPolicy()
    #expect(policy.reason(at: at(9), state: state(lastCall: at(0))) == nil)
    #expect(policy.reason(at: at(10), state: state(lastCall: at(0))) == .scheduled)
}

/// A false 90% warning is the worst failure mode, so an estimate reaching a
/// threshold buys one early confirmation.
@Test func crossingAThresholdJumpsTheQueue() {
    let policy = LimitsRefreshPolicy()
    let reason = policy.reason(
        at: at(3), state: state(lastCall: at(0), estimate: 91, confirmed: 60)
    )
    #expect(reason == .confirmThreshold(90))
}

@Test func anAlreadyConfirmedThresholdIsNotRechecked() {
    let policy = LimitsRefreshPolicy()
    let reason = policy.reason(
        at: at(3), state: state(lastCall: at(0), estimate: 91, confirmed: 90)
    )
    #expect(reason == nil)
}

@Test func thresholdConfirmationStillRespectsItsOwnFloor() {
    let policy = LimitsRefreshPolicy()
    let reason = policy.reason(
        at: at(1), state: state(lastCall: at(0), estimate: 91, confirmed: 10)
    )
    #expect(reason == nil)
}

/// The window rolling over changes the number with no tokens spent, so this is the
/// one case that re-anchors without local activity.
@Test func aResetReanchorsEvenWithoutActivity() {
    let policy = LimitsRefreshPolicy()
    let reason = policy.reason(
        at: at(10), state: state(lastCall: at(0), activity: false, resetsAt: at(5))
    )
    #expect(reason == .afterReset)
}

@Test func aHeavyEightHourDayStaysUnderFiftyCalls() {
    let policy = LimitsRefreshPolicy()
    var calls = 0
    var last: Date?
    // One tick a minute, always busy, never near a threshold.
    for minute in 0..<(8 * 60) {
        let now = at(Double(minute))
        if policy.reason(at: now, state: state(lastCall: last, estimate: 40, confirmed: 40)) != nil {
            calls += 1
            last = now
        }
    }
    #expect(calls <= 48)
}
