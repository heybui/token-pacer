import Foundation
import Observation

/// Everything the user can change, in `UserDefaults` rather than the archive:
/// these are settings, not state, and a corrupt archive must never take them out.
@MainActor
@Observable
final class Preferences {
    /// Where amber and red begin, per provider.
    ///
    /// One pair for the whole app was the wrong shape: the providers do not
    /// share a plan, a window or a price. Half of a Claude week is a different
    /// kind of news from half of a month of Copilot credits, and the marks are
    /// where that judgement is kept.
    private(set) var zones: [SourceID: ToneScale]

    /// The two marks a provider is read by, clamped so the lower one is always
    /// the warning however a plist was edited.
    func zone(for source: SourceID) -> ToneScale {
        let stored = zones[source] ?? ToneScale()
        return ToneScale(
            warnAt: min(stored.warnAt, stored.critAt),
            critAt: max(stored.warnAt, stored.critAt)
        )
    }

    func setZone(_ scale: ToneScale, for source: SourceID) {
        zones[source] = scale
        store.set(scale.warnAt, forKey: Key.warnAt(source))
        store.set(scale.critAt, forKey: Key.criticalAt(source))
    }

    /// The marks a crossing is raised at, for one provider.
    ///
    /// Both of them. The watch mark is the one there is still time to act on —
    /// by the time a card says "over", the decision it was meant to inform has
    /// already been made. `AlertPolicy` fires the highest one crossed and each
    /// one once per window, so a jump from 60 to 95 says "over" and not both.
    func alertThresholds(for source: SourceID) -> [Double] {
        let zone = zone(for: source)
        return [zone.warnAt, zone.critAt]
    }

    /// The banner itself. Off, going over is carried by the pill alone — which is
    /// the whole product, so this is a switch and not a feature gate: the figure
    /// never stops being on screen.
    var notifiesOnZone: Bool {
        didSet { store.set(notifiesOnZone, forKey: Key.notifiesWhenOver) }
    }

    /// A threshold crossing makes a sound. Only ever heard with the banner, which
    /// only appears when a full-screen app hides the notch.
    /// The marks a banner is raised at, in the user's own numbers.
    ///
    /// Both of them. The watch mark is the one there is still time to act on —
    /// by the time a banner says "over", the decision it was meant to inform has
    /// already been made. `AlertPolicy` fires the highest one crossed and each
    /// one once per window, so a jump from 60 to 95 says "over" and not both.
    var soundOnThreshold: Bool {
        didSet { store.set(soundOnThreshold, forKey: Key.soundOnThreshold) }
    }

    /// How much quiet it takes before the pill is gone entirely and the notch
    /// reads as stock hardware. Quiet means every tracked provider, not Claude
    /// alone: Codex answering is as much activity as Claude answering. Zero
    /// never hides it — the pill stays on screen through any amount of silence.
    var hidesAfterQuietMinutes: Int {
        didSet { store.set(hidesAfterQuietMinutes, forKey: Key.hidesAfterQuietMinutes) }
    }

    /// Which mark the pill leads with. No UI yet — the Appearance pane is the
    /// next phase — but stored rather than hard-coded, so the choice the pane
    /// will make is already the one the app reads.
    var mark: Mark {
        didSet { store.set(mark.rawValue, forKey: Key.mark) }
    }

    /// Which light runs the shell's outline while a model is answering.
    var border: BorderEffect {
        didSet { store.set(border.rawValue, forKey: Key.border) }
    }

    /// One switch for the whole group. Off is a shell with a plain hairline —
    /// still the app's outline, just nothing moving above your eyeline.
    var bordersOn: Bool {
        didSet { store.set(bordersOn, forKey: Key.bordersOn) }
    }

    /// Whether the menu bar carries the figure as well as the mark.
    ///
    /// Off leaves the mark alone out there — which is the whole reading for
    /// anyone who wants a glance rather than a number, and 30pt of menu bar back.
    /// The card still spells every figure out; this is the strip, where less is
    /// the product.
    var showsPercentage: Bool {
        didSet { store.set(showsPercentage, forKey: Key.showsPercentage) }
    }

    /// Whether the count of working sessions rides in the trailing wing.
    ///
    /// It is the one figure out there that moves on its own — jobs start and
    /// finish while you are reading something else — and a badge appearing and
    /// disappearing beside the countdown is motion in the corner of the eye. Off
    /// silences the count, not the slot: a source that cannot be read still
    /// raises its badge there.
    var showsJobCount: Bool {
        didSet { store.set(showsJobCount, forKey: Key.showsJobCount) }
    }

    /// Which provider the pill itself carries.
    ///
    /// The strip has room for one mark and one figure, so the card compares
    /// providers and the menu bar reports one — pinned, never guessed at. It is
    /// always one of the tracked ones: untracking the pinned provider moves the
    /// pin rather than leaving the pill reading a source nothing polls.
    var pillSource: SourceID {
        didSet { store.set(pillSource.rawValue, forKey: Key.pillSource) }
    }

    /// The display the pill lives on, by UUID. Nil is automatic: the notch
    /// when the Mac has one, the main screen otherwise.
    var display: String? {
        didSet { store.set(display, forKey: Key.display) }
    }

    /// The chosen display's name, kept so the picker can still say which one
    /// it is while that monitor is unplugged.
    var displayName: String? {
        didSet { store.set(displayName, forKey: Key.displayName) }
    }

    /// Which language the app draws itself in. English unless somebody picks
    /// another one — never "whatever the Mac is set to".
    ///
    /// Following the system was an option and is not one any more: a Mac set to
    /// a language this build does not carry fell back to English regardless, so
    /// the row claimed to be following something it was not. A language the app
    /// actually has is the only answer worth offering.
    ///
    /// Applied by writing `AppleLanguages` into the app's own domain — the same
    /// switch System Settings flips — which is read once at launch, so the row
    /// says it takes a restart. Kept under our own key as well because an unset
    /// `AppleLanguages` reads back as the *system's* list, and that cannot be
    /// told apart from a deliberate choice of the same language.
    var language: String {
        didSet {
            store.set(language, forKey: Key.language)
            store.set([language], forKey: Self.appleLanguages)
        }
    }

    /// What the build that offered "System" stored for it. Kept only to be
    /// recognised and replaced, since it names no language.
    private static let legacySystem = "system"

    /// Foundation's own key, not ours. Written rather than read: see above.
    private static let appleLanguages = "AppleLanguages"

    /// Which providers are tracked: every one whose CLI is on this Mac.
    ///
    /// Detected, never chosen. A switch for a provider that is not installed
    /// promises a reading the app cannot take; a switch for one that is only
    /// asks for the disk to be repeated back. The stored list went with the
    /// switches, and so did the `knownSources` bookkeeping that existed to tell
    /// a provider added by an update from one somebody had turned off.
    private(set) var trackedSources: Set<SourceID>

    func tracks(_ source: SourceID) -> Bool { trackedSources.contains(source) }

    /// Which providers get a row on the hover card.
    ///
    /// Not the same question as tracking. Tracking is the disk's answer — the
    /// CLI is here or it is not — and this is the user's: three rows is a
    /// comparison, one row is a readout, and somebody watching a single provider
    /// should not have to read past two they never use.
    private(set) var hiddenFromCard: Set<SourceID>

    func showsOnCard(_ source: SourceID) -> Bool { !hiddenFromCard.contains(source) }

    func setShowsOnCard(_ shows: Bool, for source: SourceID) {
        if shows { hiddenFromCard.remove(source) } else { hiddenFromCard.insert(source) }
        store.set(hiddenFromCard.map(\.rawValue).sorted(), forKey: Key.hiddenFromCard)
        // The pill cannot report a provider the card cannot pin: hiding the one
        // it is carrying moves the pin to the first row still on screen.
        if !shows, pillSource == source,
           let next = SourceID.allCases.first(where: { tracks($0) && showsOnCard($0) }) {
            pillSource = next
        }
    }

    /// Read the disk again.
    ///
    /// A handful of `isExecutableFile` calls, which is the whole reason this can
    /// be asked repeatedly rather than at launch alone: a CLI installed while
    /// the app is running turns its row on without a relaunch, and one that is
    /// removed takes its row with it.
    func refreshTracked() {
        let found = Self.defaultSources(installed)
        guard found != trackedSources else { return }
        trackedSources = found
        // The pill cannot report a provider nothing is asking about.
        if !found.contains(pillSource) { pillSource = Self.firstTracked(of: found) }
    }

    /// In the enum's own order, so "the next one" is the same answer every time
    /// rather than whatever a `Set` happens to hand back first.
    private static func firstTracked(of sources: Set<SourceID>) -> SourceID {
        SourceID.allCases.first(where: sources.contains) ?? .claude
    }

    private let store: UserDefaults
    /// How the defaults decide which providers to start on.
    private let installed: (SourceID) -> Bool

    /// Injected so a test is not at the mercy of what is installed on the
    /// machine running it.
    init(
        store: UserDefaults = .standard,
        installed: @escaping (SourceID) -> Bool = { $0.cliIsInstalled }
    ) {
        self.store = store
        self.installed = installed
        // `object(forKey:)` rather than `double(forKey:)`: an unset key reads as
        // zero, which would silently make every pill red.
        // The pair this app kept before it kept one per provider. Read as the
        // starting point for all three, so nobody's marks are lost to the change.
        let shared = ToneScale(
            warnAt: store.object(forKey: Key.sharedWarnAt) as? Double ?? Default.zone.warnAt,
            critAt: store.object(forKey: Key.sharedCriticalAt) as? Double ?? Default.zone.critAt
        )
        zones = Dictionary(uniqueKeysWithValues: SourceID.allCases.map { source in
            (source, ToneScale(
                warnAt: store.object(forKey: Key.warnAt(source)) as? Double ?? shared.warnAt,
                critAt: store.object(forKey: Key.criticalAt(source)) as? Double ?? shared.critAt
            ))
        })
        notifiesOnZone = store.object(forKey: Key.notifiesWhenOver) as? Bool
            ?? Default.notifiesOnZone
        soundOnThreshold = store.object(forKey: Key.soundOnThreshold) as? Bool
            ?? Default.soundOnThreshold
        hidesAfterQuietMinutes = store.object(forKey: Key.hidesAfterQuietMinutes) as? Int
            ?? Default.hidesAfterQuietMinutes
        mark = (store.string(forKey: Key.mark).flatMap(Mark.init(rawValue:))) ?? Default.mark
        showsPercentage = store.object(forKey: Key.showsPercentage) as? Bool
            ?? Default.showsPercentage
        showsJobCount = store.object(forKey: Key.showsJobCount) as? Bool
            ?? Default.showsJobCount
        border = (store.string(forKey: Key.border).flatMap(BorderEffect.init(rawValue:)))
            ?? Default.border
        bordersOn = store.object(forKey: Key.bordersOn) as? Bool ?? Default.bordersOn
        display = store.string(forKey: Key.display)
        displayName = store.string(forKey: Key.displayName)
        // A first launch has nothing stored and lands on English. A local first:
        // reading the property back counts as using `self`, and the rest of the
        // stored properties are not set yet.
        // An install from a build that offered "System" stored a word for it;
        // there is no such choice any more, so it reads as the default.
        // Not checked against the bundle: a `swift test` or `swift run` build has
        // no resources at all, and rejecting a stored language there would throw
        // away a real choice rather than a stale one.
        let stored = store.string(forKey: Key.language)
        let chosen = stored.flatMap { $0 == Self.legacySystem ? nil : $0 } ?? Default.language
        language = chosen
        // Written here as well, because `didSet` does not run in an initialiser
        // and the bundle reads `AppleLanguages` before anything else gets a say.
        if stored != chosen {
            store.set(chosen, forKey: Key.language)
            store.set([chosen], forKey: Self.appleLanguages)
        }
        // A local first: reading a stored property back counts as using `self`,
        // and `pillSource` below is not set yet.
        let tracked = Self.defaultSources(installed)
        trackedSources = tracked
        hiddenFromCard = Set(
            (store.stringArray(forKey: Key.hiddenFromCard) ?? []).compactMap(SourceID.init(rawValue:))
        )
        // A pin on a provider that is no longer tracked is not a preference any
        // more: it falls back rather than leaving the pill on a dead source.
        pillSource = store.string(forKey: Key.pillSource)
            .flatMap(SourceID.init(rawValue:))
            .flatMap { tracked.contains($0) ? $0 : nil }
            ?? Self.firstTracked(of: tracked)
    }

    /// Back to the board's own marks, and to the two alert switches beside them.
    ///
    /// Nothing else. It used to put every switch in both panes back, which made
    /// it a button you could not press to undo an experiment with a threshold
    /// without also losing the mark, the border and the language you had chosen.
    /// Those are not things anybody wants reset by a row called Reset in the
    /// section they were fixing a number in.
    func resetZonesAndAlerts() {
        for source in SourceID.allCases { setZone(Default.zone, for: source) }
        notifiesOnZone = Default.notifiesOnZone
        soundOnThreshold = Default.soundOnThreshold
    }

    /// Nothing left to reset, so the row's button greys out rather than promising
    /// a change it would not make. Only what the button actually touches.
    var hasDefaults: Bool {
        SourceID.allCases.allSatisfy { zone(for: $0) == Default.zone }
            && notifiesOnZone == Default.notifiesOnZone
            && soundOnThreshold == Default.soundOnThreshold
    }

    /// The same answer on a first launch and on a reset: every provider whose
    /// CLI is installed. None of them installed is not a reason to track
    /// nothing — the app would have no reason to be on screen and no row to
    /// complain from — so that falls back to all three.
    private static func defaultSources(_ installed: (SourceID) -> Bool) -> Set<SourceID> {
        let found = Set(SourceID.allCases.filter(installed))
        return found.isEmpty ? Default.everySource : found
    }

    /// One place, so `init` and `reset` cannot disagree about what default means.
    private enum Default {
        static let zone = ToneScale(warnAt: 75, critAt: 90)
        static let notifiesOnZone = true
        static let soundOnThreshold = true
        /// The language the app is written in, and the one every string in the
        /// catalog is a translation *of*.
        static let language = "en"
        static let hidesAfterQuietMinutes = 5
        static let mark = Mark.capsuleBar
        static let showsPercentage = true
        static let showsJobCount = true
        static let border = BorderEffect.comet
        static let bordersOn = true
        /// Not a default setting any more — the floor under detection, for a Mac
        /// with no CLI on it at all.
        static let everySource = Set(SourceID.allCases)
    }

    /// Clamped on the way out, so a hand-edited plist cannot invert the scale.


    private enum Key {
        /// Per provider now. The two below are what the shared pair was stored
        /// under, kept to be read once and carried forward.
        static func warnAt(_ source: SourceID) -> String { "pref.warnAt.\(source.rawValue)" }
        static func criticalAt(_ source: SourceID) -> String { "pref.criticalAt.\(source.rawValue)" }
        static let hiddenFromCard = "pref.hiddenFromCard"
        static let display = "pref.display"
        static let displayName = "pref.displayName"
        static let sharedWarnAt = "pref.warnAt"
        static let sharedCriticalAt = "pref.criticalAt"
        /// Named for what it used to do — it fires at the watch mark as well
        /// now. The key is what somebody's choice is stored under, and renaming
        /// it would quietly turn the banner back on for everyone who had it off.
        static let notifiesWhenOver = "pref.notifiesWhenOver"
        static let soundOnThreshold = "pref.soundOnThreshold"
        static let hidesAfterQuietMinutes = "pref.hidesAfterQuietMinutes"
        static let mark = "pref.mark"
        static let showsPercentage = "pref.showsPercentage"
        static let showsJobCount = "pref.showsJobCount"
        static let border = "pref.border"
        static let bordersOn = "pref.bordersOn"
        static let language = "pref.language"
        static let pillSource = "pref.pillSource"
    }
}
