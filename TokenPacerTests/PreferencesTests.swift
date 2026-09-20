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
    #expect(preferences.zone(for: .claude).warnAt == 75)
    #expect(preferences.zone(for: .claude).critAt == 90)
    #expect(preferences.soundOnThreshold)
    #expect(preferences.hidesAfterQuietMinutes == 5)
}

@MainActor
@Test func preferencesSurviveARelaunch() {
    let store = defaults()
    let first = Preferences(store: store)
    first.setZone(ToneScale(warnAt: 60, critAt: first.zone(for: .claude).critAt), for: .claude)
    first.hidesAfterQuietMinutes = 0

    let second = Preferences(store: store)
    #expect(second.zone(for: .claude).warnAt == 60)
    #expect(second.hidesAfterQuietMinutes == 0)
}

/// A first launch tracks what is actually installed: a switch that is on for a
/// CLI this Mac does not have can only ever report a missing binary.
@MainActor
@Test func firstLaunchTracksOnlyTheInstalledProviders() {
    let preferences = Preferences(store: defaults(), installed: { $0 == .codex })
    #expect(preferences.trackedSources == [.codex])
}

/// None of them installed is not a reason to track nothing: the app would have
/// no reason to be on screen and no row to complain from.
@MainActor
@Test func noCLIAtAllStillOffersEveryProvider() {
    let preferences = Preferences(store: defaults(), installed: { _ in false })
    #expect(preferences.trackedSources == Set(SourceID.allCases))
}

/// The pill carries one provider, and it has to be one that is being polled: a
/// CLI that is uninstalled while the app runs moves the pin rather than leaving
/// the strip on a source nothing asks about.
@MainActor
@Test func aProviderThatLeavesTheMacMovesThePin() {
    var present = Set(SourceID.allCases)
    let preferences = Preferences(store: defaults(), installed: { present.contains($0) })
    #expect(preferences.pillSource == .claude)

    present.remove(.claude)
    preferences.refreshTracked()
    #expect(preferences.trackedSources == [.codex, .copilot])
    #expect(preferences.pillSource == .codex)
}

/// A pin survives a relaunch; one on a provider whose CLI has since gone does
/// not outlive it.
@MainActor
@Test func thePinSurvivesARelaunchUnlessItsCLIIsGone() {
    let store = defaults()
    let first = Preferences(store: store, installed: { _ in true })
    first.pillSource = .copilot
    #expect(Preferences(store: store, installed: { _ in true }).pillSource == .copilot)

    #expect(Preferences(store: store, installed: { $0 != .copilot }).pillSource == .claude)
}

/// Reset puts the marks and the two alert switches back, and touches nothing
/// else: pressing it to undo an experiment with a threshold must not also take
/// away the mark, the border or the pill's own pinned provider.
@MainActor
@Test func resetReturnsTheZonesAndTheAlertsAndNothingElse() {
    let store = defaults()
    let preferences = Preferences(store: store, installed: { _ in true })
    preferences.setZone(ToneScale(warnAt: 55, critAt: 65), for: .claude)
    preferences.setZone(ToneScale(warnAt: 20, critAt: 40), for: .codex)
    preferences.soundOnThreshold = false
    preferences.notifiesOnZone = false
    // Chosen, not stray: these have to survive the reset.
    preferences.hidesAfterQuietMinutes = 20
    preferences.mark = .thermometer
    preferences.bordersOn = false
    #expect(!preferences.hasDefaults)

    preferences.resetZonesAndAlerts()
    #expect(preferences.hasDefaults)
    #expect(SourceID.allCases.allSatisfy { preferences.zone(for: $0) == ToneScale(warnAt: 75, critAt: 90) })
    #expect(preferences.soundOnThreshold)
    #expect(preferences.notifiesOnZone)

    #expect(preferences.hidesAfterQuietMinutes == 20)
    #expect(preferences.mark == .thermometer)
    #expect(preferences.bordersOn == false)
    // And it is written, not just held: a relaunch stays reset.
    #expect(Preferences(store: store).hasDefaults)
}

/// The scale clamps as you drag, but the stored values are the last line of
/// defence — a hand-edited plist must not be able to invert the rule.
@MainActor
@Test func invertedThresholdsAreClampedNotObeyed() {
    let preferences = Preferences(store: defaults())
    // The pair the wrong way round, as a hand-edited plist would leave it.
    preferences.setZone(ToneScale(warnAt: 95, critAt: 60), for: .claude)

    #expect(preferences.zone(for: .claude).warnAt == 60)
    #expect(preferences.zone(for: .claude).critAt == 95)
    #expect(preferences.alertThresholds(for: .claude) == [60, 95])
}

/// The marks the store is handed are the user's own, moved or not.
@MainActor
@Test func theMarksTheStoreWatchesAreTheOnesTheUserSet() {
    let preferences = Preferences(store: defaults())
    preferences.setZone(ToneScale(warnAt: 50, critAt: preferences.zone(for: .claude).critAt), for: .claude)
    #expect(preferences.alertThresholds(for: .claude) == [50, 90])
}

/// Zero minutes keeps the collapsed pill on screen through a quiet spell
/// rather than withdrawing to the 3pt sliver.
@Test func dormancyCanBeTurnedOff() {
    var snapshot = UsageSnapshot(source: .claude)
    snapshot.sessionPercent = 20
    snapshot.lastActivity = now.addingTimeInterval(-40 * 60)

    #expect(PillStateResolver.resolve(PillInputs(snapshot: snapshot), at: now) == .hidden)
    #expect(PillStateResolver.resolve(
        PillInputs(snapshot: snapshot, hidesAfterQuietMinutes: 0), at: now
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

/// Tracking follows the disk on every reading, not only the first: a CLI
/// installed while the app is running turns its row on without a relaunch.
@MainActor @Test func aNewlyInstalledCLIStartsBeingTracked() {
    var present: Set<SourceID> = [.claude]
    let preferences = Preferences(store: UserDefaults(suiteName: #function) ?? .standard,
                                  installed: { present.contains($0) })
    #expect(preferences.trackedSources == [.claude])

    present.insert(.codex)
    preferences.refreshTracked()
    #expect(preferences.trackedSources == [.claude, .codex])
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

/// The grid draws all twelve and no others — the order differs from the stored
/// one on purpose, so this pins the set rather than the sequence.
@Test func theBorderGridHoldsEveryEffectOnce() {
    #expect(Set(BorderEffect.grid) == Set(BorderEffect.allCases))
    #expect(BorderEffect.grid.count == BorderEffect.allCases.count)
    // The glow paints outside its own panel, so it never sits at the end of a
    // row: four across, and it is not in the first or the last column.
    let column = (BorderEffect.grid.firstIndex(of: .breatheGlow) ?? 0) % 4
    #expect(column != 0 && column != 3)
}

/// Upgrading over a build that kept a switched-off provider in its defaults:
/// the list is not read any more, so a CLI that is installed is tracked whatever
/// the old plist said. Nothing migrates it — there is nothing to migrate to.
@MainActor @Test func anOldStoredListNoLongerDecidesAnything() {
    let store = UserDefaults(suiteName: "tokenpacer.tests.newprovider")!
    store.removePersistentDomain(forName: "tokenpacer.tests.newprovider")

    store.set(["claude"], forKey: "pref.trackedSources")
    let preferences = Preferences(store: store, installed: { _ in true })
    #expect(preferences.trackedSources == Set(SourceID.allCases))

    store.removePersistentDomain(forName: "tokenpacer.tests.newprovider")
}

// MARK: - language

/// Only what this app itself has written. `stringArray(forKey: "AppleLanguages")`
/// falls through to the global domain and hands back the *system's* list, which
/// is the whole reason `Preferences` keeps a key of its own rather than reading
/// Foundation's back.
private func override(in suite: String) -> [String]? {
    UserDefaults().persistentDomain(forName: suite)?["AppleLanguages"] as? [String]
}

/// The picker writes two keys: ours, which is unambiguous, and Foundation's,
/// which is what actually changes the language at the next launch.
@MainActor
@Test func choosingALanguageSetsTheOneFoundationReads() {
    let suite = "token-pacer-tests-\(UUID().uuidString)"
    let store = UserDefaults(suiteName: suite)!
    defer { store.removePersistentDomain(forName: suite) }

    // English on a first launch, written both places at once: the bundle reads
    // Foundation's key before anything in the app gets a say.
    let preferences = Preferences(store: store)
    #expect(preferences.language == "en")
    #expect(override(in: suite) == ["en"])

    preferences.language = "vi"
    #expect(override(in: suite) == ["vi"])
    #expect(Preferences(store: store).language == "vi")
}

/// An install from the build that offered "System" has a word stored that is not
/// a language. There is no such choice any more, so it reads as the default
/// rather than pinning the app to a locale called `system`.
@MainActor
@Test func aStoredSystemChoiceFallsBackToEnglish() {
    let suite = "token-pacer-tests-\(UUID().uuidString)"
    let store = UserDefaults(suiteName: suite)!
    defer { store.removePersistentDomain(forName: suite) }
    store.set("system", forKey: "pref.language")

    let preferences = Preferences(store: store)
    #expect(preferences.language == "en")
    #expect(override(in: suite) == ["en"])
}

/// "Restore defaults" is about the board's marks and thresholds. Rewriting the
/// window in a language the reader did not ask for is a different promise.
@MainActor
@Test func resettingLeavesTheLanguageAlone() {
    let preferences = Preferences(store: defaults())
    preferences.language = "vi"
    preferences.setZone(ToneScale(warnAt: 60, critAt: preferences.zone(for: .claude).critAt), for: .claude)

    preferences.resetZonesAndAlerts()
    #expect(preferences.zone(for: .claude).warnAt == 75)
    #expect(preferences.language == "vi")
    #expect(preferences.hasDefaults)
}

/// A `swift test` build has no bundle and no compiled `.lproj`, so there is one
/// language and the row that offers a choice never appears.
@Test func oneLanguageIsNotAChoice() {
    #expect(!Language.isOffered)
}

/// The banner used to be raised at the far mark alone, which is the one there is
/// nothing left to do about. Both marks are asked for now, on by default, and the
/// policy still fires each of them once per window and the higher one first.
@MainActor @Test func aBannerIsRaisedAtTheWatchMarkAsWellAsTheOver() {
    let preferences = Preferences(store: defaults(), installed: { _ in true })
    #expect(preferences.notifiesOnZone)                      // on unless turned off
    #expect(preferences.alertThresholds(for: .claude) == [75, 90])

    var policy = AlertPolicy()
    let window = Date().addingTimeInterval(3600)
    let fired = [60.0, 80, 85, 95, 99].compactMap {
        policy.crossing(
            percent: $0, resetsAt: window,
            thresholds: preferences.alertThresholds(for: .claude)
        )
    }
    #expect(fired == [75, 90])

    // Thresholds the user moved are the ones asked for, not the board's.
    preferences.setZone(ToneScale(warnAt: 50, critAt: preferences.zone(for: .claude).critAt), for: .claude)
    #expect(preferences.alertThresholds(for: .claude) == [50, 90])
}

/// The two marks the wrong way round colour the pill by the clamped pair, so the
/// card has to read the same pair — otherwise a figure is amber on the pill and
/// "wrap up soon" on the card at the same moment.
@MainActor @Test func invertedMarksAreClampedForTheCardToo() {
    let preferences = Preferences(store: defaults())
    preferences.setZone(ToneScale(warnAt: 50, critAt: preferences.zone(for: .claude).critAt), for: .claude)
    preferences.setZone(ToneScale(warnAt: preferences.zone(for: .claude).warnAt, critAt: 30), for: .claude)
    #expect(preferences.alertThresholds(for: .claude) == [30, 50])
    #expect(preferences.zone(for: .claude).warnAt == 30)
    #expect(preferences.zone(for: .claude).critAt == 50)
}

/// Each provider keeps its own pair, and the pair a build used to share is read
/// once as the starting point for all three — nobody's marks are lost to the
/// change.
@MainActor @Test func eachProviderKeepsItsOwnMarks() {
    let store = defaults()
    store.set(60.0, forKey: "pref.warnAt")        // what the shared pair was stored under
    store.set(80.0, forKey: "pref.criticalAt")

    let preferences = Preferences(store: store, installed: { _ in true })
    for source in SourceID.allCases {
        #expect(preferences.zone(for: source) == ToneScale(warnAt: 60, critAt: 80))
    }

    preferences.setZone(ToneScale(warnAt: 30, critAt: 50), for: .copilot)
    #expect(preferences.zone(for: .copilot) == ToneScale(warnAt: 30, critAt: 50))
    #expect(preferences.zone(for: .claude) == ToneScale(warnAt: 60, critAt: 80))
    // And it survives the launch, per provider.
    #expect(Preferences(store: store).zone(for: .copilot) == ToneScale(warnAt: 30, critAt: 50))
}

/// "Use for all" is the common case — one rule for the machine — without giving
/// up the three pairs that make it a choice.
@MainActor @Test func oneProvidersMarksCanBeGivenToTheRest() {
    let preferences = Preferences(store: defaults(), installed: { _ in true })
    preferences.setZone(ToneScale(warnAt: 40, critAt: 70), for: .codex)
    #expect(preferences.zone(for: .claude) != preferences.zone(for: .codex))

    for source in SourceID.allCases where source != .codex {
        preferences.setZone(preferences.zone(for: .codex), for: source)
    }
    #expect(SourceID.allCases.allSatisfy {
        preferences.zone(for: $0) == ToneScale(warnAt: 40, critAt: 70)
    })
}

/// Three rows is a comparison; one row is a readout. Hiding a provider takes it
/// off the card without untracking it — and cannot leave the pill reporting a
/// provider whose row is no longer there to pin.
@MainActor @Test func aProviderCanBeHiddenFromTheCardWithoutBeingUntracked() {
    let store = defaults()
    let preferences = Preferences(store: store, installed: { _ in true })
    #expect(preferences.showsOnCard(.claude))
    #expect(preferences.pillSource == .claude)

    preferences.setShowsOnCard(false, for: .claude)
    #expect(preferences.showsOnCard(.claude) == false)
    #expect(preferences.tracks(.claude))          // still read, still counted
    #expect(preferences.pillSource == .codex)     // the pin moved off it

    // And it survives the launch.
    #expect(Preferences(store: store).showsOnCard(.claude) == false)
}
