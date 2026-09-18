import Foundation
import Testing
@testable import TokenPacer

private let now = Date(timeIntervalSince1970: 1_789_000_000)

private func defaults() -> UserDefaults {
    let store = UserDefaults(suiteName: "token-pacer-tests-\(UUID().uuidString)")!
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

/// Reset sits beside the scale, so it touches the scale and nothing else.
@MainActor
@Test func resetReturnsTheMarksAndLeavesTheRestAlone() {
    let store = defaults()
    let preferences = Preferences(store: store)
    preferences.warnAt = 55
    preferences.criticalAt = 65
    preferences.soundOnThreshold = false
    preferences.hideWhenDormant = false
    #expect(!preferences.hasDefaultThresholds)

    preferences.resetThresholds()
    #expect(preferences.hasDefaultThresholds)
    #expect(preferences.warnAt == 75)
    #expect(preferences.criticalAt == 90)
    // The toggles two rows down are not the scale's business.
    #expect(preferences.soundOnThreshold == false)
    #expect(preferences.hideWhenDormant == false)
    // And it is written, not just held: a relaunch stays reset.
    #expect(Preferences(store: store).hasDefaultThresholds)
}

/// The scale clamps as you drag, but the stored values are the last line of
/// defence — a hand-edited plist must not be able to invert the rule.
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

/// The chosen mark is stored by its raw value, so renaming a case would quietly
/// hand every user back the default. Twelve names, pinned.
@Test func everyMarkKeepsTheNameItIsStoredUnder() {
    #expect(Mark.allCases.map(\.rawValue) == [
        "capsuleBar", "ringWings", "notchTank", "pips", "halfGauge", "eclipse",
        "tokenStack", "hourglass", "dottedArc", "dotMatrix", "signalStrength",
        "thermometer",
    ])
}

/// A mark nobody can name is a tile nobody can pick, and the axis is the board's
/// own argument for having twelve of them.
@MainActor @Test func everyMarkSaysWhatItIsAndWhatItEncodes() {
    for mark in Mark.allCases {
        #expect(!mark.displayName.isEmpty)
        #expect(!mark.axis.isEmpty)
        #expect(mark.width > 0)
    }
}

// MARK: - which providers are tracked

/// Turning a provider off is what stops its CLI being asked anything, so the
/// setting has to reach the store rather than filter its answers.
@MainActor @Test func anUntrackedSourceIsNeverPolled() async {
    let claude = TallyingSource(id: .claude)
    let codex = TallyingSource(id: .codex)
    let store = UsageStore(sources: [claude, codex], interval: 3600, archive: nil)

    await store.refresh()
    #expect(await claude.polls == 1)
    #expect(await codex.polls == 1)

    store.tracked = [.codex]
    await store.refresh()
    #expect(await claude.polls == 1)   // left alone
    #expect(await codex.polls == 2)
    // And the band follows: the source it was showing is no longer being read.
    #expect(store.activeSource == .codex)
}

/// An app tracking nothing has no reason to be on screen, so the last one on
/// cannot be turned off.
@MainActor @Test func theLastTrackedProviderStaysOn() {
    let preferences = Preferences(store: UserDefaults(suiteName: #function) ?? .standard)
    preferences.set(tracking: false, for: .codex)
    #expect(preferences.trackedSources == [.claude])

    preferences.set(tracking: false, for: .claude)
    #expect(preferences.trackedSources == [.claude])
}

private actor TallyingSource: UsageSource {
    nonisolated let id: SourceID
    private(set) var polls = 0

    init(id: SourceID) { self.id = id }

    func poll() throws -> SourceSnapshot {
        polls += 1
        return SourceSnapshot(source: id, events: [], limits: nil)
    }
    func restore(cursors: [String: JSONLReader.Cursor], seen: Set<String>) {}
    func cursors() -> [String: JSONLReader.Cursor] { [:] }
}

// MARK: - the running border

/// Stored by raw value, like the mark: a rename would hand every user back the
/// comet without saying so.
@Test func everyBorderKeepsTheNameItIsStoredUnder() {
    #expect(BorderEffect.allCases.map(\.rawValue) == [
        "comet", "dualComet", "zoneSweep", "marchingDashes", "pulseWave",
        "quarterTrace", "counterPair", "breathe", "breatheGlow", "edgeRunners",
        "sideDrip", "bottomSweep",
    ])
}

/// An effect that describes no light is a tile that draws nothing, and the only
/// way to find out is to look at all twelve.
@Test func everyBorderIsMadeOfSomething() {
    for effect in BorderEffect.allCases {
        #expect(!effect.displayName.isEmpty)
        #expect(!effect.axis.isEmpty)

        switch effect.paint {
        case .angular(let ramps):
            #expect(!ramps.isEmpty)
            for ramp in ramps {
                #expect(ramp.duration > 0)
                // A ramp needs somewhere to start and somewhere to end, and its
                // stops have to run round the whole turn in order.
                #expect(ramp.stops.count >= 2)
                #expect(ramp.stops.first?.angle == 0)
                #expect(ramp.stops.last?.angle == 360)
                #expect(zip(ramp.stops, ramp.stops.dropFirst()).allSatisfy { $0.angle <= $1.angle })
                // And something in it has to be lit.
                #expect(ramp.stops.contains { $0.alpha > 0 })
            }
        case .bands(let bands):
            #expect(!bands.isEmpty)
            for band in bands {
                #expect(band.duration > 0)
                #expect(band.begin >= 0)
                #expect(band.lengthFraction > 0 && band.lengthFraction < 1)
            }
        case .solid(let solid):
            #expect(solid.duration > 0)
            #expect(solid.alpha > 0)
            #expect(solid.pulse != nil || solid.glow)
        }
    }
}

/// The dash train is snapped to a whole number of dashes. At the board's own
/// 15.12° there are 23.8 in a lap, and the seam rotates past once a lap.
@Test func theDashTrainClosesOnItself() {
    guard case .angular(let ramps) = BorderEffect.marchingDashes.paint,
          let stops = ramps.first?.stops
    else { return #expect(Bool(false), "the dash train is an angular ramp") }

    let lit = stops.filter { $0.alpha > 0 }
    #expect(lit.count == 48)               // two stops per dash
    #expect(stops.last?.angle == 360)
}
