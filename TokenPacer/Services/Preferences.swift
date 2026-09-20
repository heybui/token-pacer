import Foundation
import Observation

/// Everything the user can change, in `UserDefaults` rather than the archive:
/// these are settings, not state, and a corrupt archive must never take them out.
@MainActor
@Observable
final class Preferences {
    /// Amber from here. The design's slider range, and the floor is not zero —
    /// a pill that is always amber says nothing.
    var warnAt: Double {
        didSet { store.set(warnAt, forKey: Key.warnAt) }
    }

    /// Red from here, and where the warning card fires.
    var criticalAt: Double {
        didSet { store.set(criticalAt, forKey: Key.criticalAt) }
    }

    /// The banner itself. Off, going over is carried by the pill alone — which is
    /// the whole product, so this is a switch and not a feature gate: the figure
    /// never stops being on screen.
    var notifiesWhenOver: Bool {
        didSet { store.set(notifiesWhenOver, forKey: Key.notifiesWhenOver) }
    }

    /// A threshold crossing makes a sound. Only ever heard with the banner, which
    /// only appears when a full-screen app hides the notch.
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

    /// Which language the app draws itself in, or nil to follow the system.
    ///
    /// Applied by writing `AppleLanguages` into the app's own domain — the same
    /// switch System Settings flips — which is read once at launch, so the row
    /// says it takes a restart. Kept under our own key as well because an unset
    /// `AppleLanguages` reads back as the *system's* list, and that cannot be
    /// told apart from a deliberate choice of the same language.
    var language: String? {
        didSet {
            store.set(language, forKey: Key.language)
            if let language {
                store.set([language], forKey: Self.appleLanguages)
            } else {
                store.removeObject(forKey: Self.appleLanguages)
            }
        }
    }

    /// Foundation's own key, not ours. Written rather than read: see above.
    private static let appleLanguages = "AppleLanguages"

    /// Which providers are tracked. Never empty: an app tracking nothing is an
    /// app with no reason to be on screen, so the last one on cannot be turned
    /// off — `set(tracking:)` refuses rather than the UI having to.
    private(set) var trackedSources: Set<SourceID> {
        didSet {
            store.set(trackedSources.map(\.rawValue).sorted(), forKey: Key.trackedSources)
        }
    }

    func tracks(_ source: SourceID) -> Bool { trackedSources.contains(source) }

    func set(tracking: Bool, for source: SourceID) {
        var next = trackedSources
        if tracking { next.insert(source) } else { next.remove(source) }
        guard !next.isEmpty else { return }
        trackedSources = next
        // The pill cannot report a provider nothing is asking about.
        if !next.contains(pillSource) { pillSource = Self.firstTracked(of: next) }
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
        warnAt = store.object(forKey: Key.warnAt) as? Double ?? Default.warnAt
        criticalAt = store.object(forKey: Key.criticalAt) as? Double ?? Default.criticalAt
        notifiesWhenOver = store.object(forKey: Key.notifiesWhenOver) as? Bool
            ?? Default.notifiesWhenOver
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
        language = store.string(forKey: Key.language)
        let names = store.stringArray(forKey: Key.trackedSources) ?? []
        let restored = Set(names.compactMap(SourceID.init(rawValue:)))
        // A provider added by an update was never offered to this install, so its
        // absence from the stored set is not a decision — it is a gap. Tracking
        // what has been *offered* is what tells the two apart: Copilot arrived
        // after people already had a saved list, and without this it would have
        // been silently off for every one of them.
        // An install from before this key was kept has been offered exactly what
        // it stored, so a provider outside that list is one it has never seen.
        let offered = store.stringArray(forKey: Key.knownSources)
            .map { Set($0.compactMap(SourceID.init(rawValue:))) } ?? restored
        // Only the ones whose CLI is actually here. Tracking a provider that
        // is not installed spawns nothing, reads nothing and reports a missing
        // binary for ever — a switch that is on and cannot work.
        let arrived = Set(SourceID.allCases).subtracting(offered).filter(installed)
        // A local first: reading a stored property back counts as using `self`,
        // and `pillSource` below is not set yet.
        let tracked = restored.isEmpty
            ? Self.defaultSources(installed)
            : restored.union(arrived)
        trackedSources = tracked
        // A pin on a provider that is no longer tracked is not a preference any
        // more: it falls back rather than leaving the pill on a dead source.
        pillSource = store.string(forKey: Key.pillSource)
            .flatMap(SourceID.init(rawValue:))
            .flatMap { tracked.contains($0) ? $0 : nil }
            ?? Self.firstTracked(of: tracked)
        // Written here rather than left to `didSet`, which an initialiser does
        // not run: without it the union lives only in memory, `knownSources`
        // records the provider as offered, and the *next* launch reads the old
        // list back and turns it off again.
        store.set(trackedSources.map(\.rawValue).sorted(), forKey: Key.trackedSources)
        store.set(SourceID.allCases.map(\.rawValue).sorted(), forKey: Key.knownSources)
    }

    /// Back to the design board's own marks — every one of them.
    ///
    /// It used to be a Reset beside the scale and reset only the scale, because a
    /// button sitting under two handles must not silently flip the toggles two
    /// rows down. The board moved it into *App* and named it "Restore defaults",
    /// which is a different promise, so it keeps it: everything the two panes can
    /// change goes back, tracked providers included.
    func restoreDefaults() {
        warnAt = Default.warnAt
        criticalAt = Default.criticalAt
        notifiesWhenOver = Default.notifiesWhenOver
        soundOnThreshold = Default.soundOnThreshold
        hidesAfterQuietMinutes = Default.hidesAfterQuietMinutes
        mark = Default.mark
        border = Default.border
        bordersOn = Default.bordersOn
        showsPercentage = Default.showsPercentage
        showsJobCount = Default.showsJobCount
        trackedSources = Self.defaultSources(installed)
        pillSource = Self.firstTracked(of: trackedSources)
        // Language is deliberately not here, and so is not in `hasDefaults`
        // either. "Restore defaults" is about the board's marks and thresholds;
        // changing the language the window is written in while someone is
        // reading it is a different kind of change, and they did not ask for it.
    }

    /// Nothing left to restore, so the row's button greys out rather than
    /// promising a change it would not make.
    var hasDefaults: Bool {
        warnAt == Default.warnAt && criticalAt == Default.criticalAt
            && notifiesWhenOver == Default.notifiesWhenOver
            && soundOnThreshold == Default.soundOnThreshold
            && hidesAfterQuietMinutes == Default.hidesAfterQuietMinutes
            && mark == Default.mark && border == Default.border
            && bordersOn == Default.bordersOn
            && showsPercentage == Default.showsPercentage
            && showsJobCount == Default.showsJobCount
            && trackedSources == Default.trackedSources
            && pillSource == Self.firstTracked(of: trackedSources)
    }

    /// The same answer on a first launch and on a reset: every provider whose
    /// CLI is installed. None of them installed is not a reason to track
    /// nothing — the app would have no reason to be on screen and no row to
    /// complain from — so that falls back to all three.
    private static func defaultSources(_ installed: (SourceID) -> Bool) -> Set<SourceID> {
        let found = Set(SourceID.allCases.filter(installed))
        return found.isEmpty ? Default.trackedSources : found
    }

    /// One place, so `init` and `reset` cannot disagree about what default means.
    private enum Default {
        static let warnAt: Double = 75
        static let criticalAt: Double = 90
        static let notifiesWhenOver = true
        static let soundOnThreshold = true
        static let hidesAfterQuietMinutes = 5
        static let mark = Mark.capsuleBar
        static let showsPercentage = true
        static let showsJobCount = true
        static let border = BorderEffect.comet
        static let bordersOn = true
        static let trackedSources = Set(SourceID.allCases)
    }

    /// Clamped on the way out, so a hand-edited plist cannot invert the scale.
    var thresholds: ToneScale {
        ToneScale(warnAt: min(warnAt, criticalAt), critAt: max(warnAt, criticalAt))
    }

    private enum Key {
        static let warnAt = "pref.warnAt"
        static let criticalAt = "pref.criticalAt"
        static let notifiesWhenOver = "pref.notifiesWhenOver"
        static let soundOnThreshold = "pref.soundOnThreshold"
        static let hidesAfterQuietMinutes = "pref.hidesAfterQuietMinutes"
        static let mark = "pref.mark"
        static let showsPercentage = "pref.showsPercentage"
        static let showsJobCount = "pref.showsJobCount"
        static let border = "pref.border"
        static let bordersOn = "pref.bordersOn"
        static let language = "pref.language"
        static let trackedSources = "pref.trackedSources"
        static let pillSource = "pref.pillSource"
        /// Every provider this install has ever shown a switch for.
        static let knownSources = "pref.knownSources"
    }
}
