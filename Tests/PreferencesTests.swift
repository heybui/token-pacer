import Foundation
import Testing
@testable import BurnTracker

private let now = Date(timeIntervalSince1970: 1_789_000_000)

private func defaults() -> UserDefaults {
    let store = UserDefaults(suiteName: "burn-tracker-tests-\(UUID().uuidString)")!
    return store
}

/// An unset key reads as zero through `double(forKey:)`, which would make every
/// pill red on first launch.
@MainActor
@Test func unsetPreferencesFallBackToTheDesignsThresholds() {
    let preferences = Preferences(store: defaults())
    #expect(preferences.warnAt == 75)
    #expect(preferences.criticalAt == 90)
    #expect(preferences.soundOnThreshold)
    #expect(preferences.hideWhenDormant)
}

@MainActor
@Test func preferencesSurviveARelaunch() {
    let store = defaults()
    let first = Preferences(store: store)
    first.warnAt = 60
    first.hideWhenDormant = false

    let second = Preferences(store: store)
    #expect(second.warnAt == 60)
    #expect(second.hideWhenDormant == false)
}

/// A hand-edited plist must not be able to invert the scale.
@MainActor
@Test func invertedThresholdsAreClampedNotObeyed() {
    let preferences = Preferences(store: defaults())
    preferences.warnAt = 95
    preferences.criticalAt = 60

    #expect(preferences.thresholds.warnAt == 60)
    #expect(preferences.thresholds.critAt == 95)
}

@MainActor
@Test func theCriticalThresholdMovesWhereTheWarningFires() {
    let model = PillModel()
    let preferences = Preferences(store: defaults())
    preferences.criticalAt = 50
    model.preferences = preferences

    var snapshot = UsageSnapshot(source: .claude)
    snapshot.sessionPercent = 55
    snapshot.lastActivity = now

    model.update(snapshot: snapshot, at: now)
    #expect(model.state == .warning)   // 55% is past a critical mark of 50
}

/// "Hide pill when dormant" off keeps the collapsed pill on screen through a
/// quiet spell rather than withdrawing to the 3pt sliver.
@Test func dormancyCanBeTurnedOff() {
    var snapshot = UsageSnapshot(source: .claude)
    snapshot.sessionPercent = 20
    snapshot.lastActivity = now.addingTimeInterval(-40 * 60)

    #expect(PillStateResolver.resolve(PillInputs(snapshot: snapshot), at: now) == .dormant)
    #expect(PillStateResolver.resolve(
        PillInputs(snapshot: snapshot, hideWhenDormant: false), at: now
    ) == .collapsed)
}

@Test func theToneScaleAppliesTheUsersThresholds() {
    let scale = ToneScale(warnAt: 40, critAt: 60)
    #expect(scale(30) == Tokens.green)
    #expect(scale(50) == Tokens.amber)
    #expect(scale(70) == Tokens.red)
    // Nil is not zero-used; it is unknown, and the caller decides what to draw.
    #expect(scale(nil) == Tokens.green)
}

// MARK: - alerts

private func crossings(_ percentages: [Double], resetsAt: Date = now.addingTimeInterval(3600),
                       thresholds: [Double] = [75, 90]) -> [Double] {
    var policy = AlertPolicy()
    return percentages.compactMap {
        policy.crossing(percent: $0, resetsAt: resetsAt, thresholds: thresholds)
    }
}

/// A figure that hovers either side of the mark must alert once, not eleven times.
@Test func aThresholdAlertsOncePerWindow() {
    #expect(crossings([70, 76, 77, 74, 76]) == [75])
}

@Test func aJumpPastBothMarksSaysTheMoreUrgentThing() {
    // Crossing 90 in one poll should say "wrap up", not "running warm".
    #expect(crossings([20, 95]) == [90])
}

/// The next window is a fresh start: the same marks alert again.
@Test func theNextWindowAlertsAgain() {
    var policy = AlertPolicy()
    let first = now.addingTimeInterval(3600)
    let second = now.addingTimeInterval(3600 + 5 * 3600)

    #expect(policy.crossing(percent: 80, resetsAt: first, thresholds: [75, 90]) == 75)
    #expect(policy.crossing(percent: 85, resetsAt: first, thresholds: [75, 90]) == nil)
    #expect(policy.crossing(percent: 80, resetsAt: second, thresholds: [75, 90]) == 75)
}

/// Launching mid-window past the mark is worth one alert; nothing to compare
/// against is not a reason to stay quiet.
@Test func aFirstReadingAlreadyPastTheMarkAlertsOnce() {
    #expect(crossings([92]) == [90])
}

@Test func anUnknownPercentageNeverAlerts() {
    var policy = AlertPolicy()
    #expect(policy.crossing(percent: nil, resetsAt: now, thresholds: [75]) == nil)
    #expect(policy.crossing(percent: 99, resetsAt: nil, thresholds: [75]) == nil)
}
