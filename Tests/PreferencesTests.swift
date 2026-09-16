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
