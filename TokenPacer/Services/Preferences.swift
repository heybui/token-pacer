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

    /// A threshold crossing makes a sound. Only ever heard with the banner, which
    /// only appears when a full-screen app hides the notch.
    var soundOnThreshold: Bool {
        didSet { store.set(soundOnThreshold, forKey: Key.soundOnThreshold) }
    }

    /// "No Claude activity: the pill is gone entirely, notch reads as stock
    /// hardware." Off keeps the collapsed pill on screen instead.
    var hideWhenDormant: Bool {
        didSet { store.set(hideWhenDormant, forKey: Key.hideWhenDormant) }
    }

    /// Which mark the pill leads with. No UI yet — the Appearance pane is the
    /// next phase — but stored rather than hard-coded, so the choice the pane
    /// will make is already the one the app reads.
    var mark: Mark {
        didSet { store.set(mark.rawValue, forKey: Key.mark) }
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
    }

    private let store: UserDefaults

    init(store: UserDefaults = .standard) {
        self.store = store
        // `object(forKey:)` rather than `double(forKey:)`: an unset key reads as
        // zero, which would silently make every pill red.
        warnAt = store.object(forKey: Key.warnAt) as? Double ?? Default.warnAt
        criticalAt = store.object(forKey: Key.criticalAt) as? Double ?? Default.criticalAt
        soundOnThreshold = store.object(forKey: Key.soundOnThreshold) as? Bool
            ?? Default.soundOnThreshold
        hideWhenDormant = store.object(forKey: Key.hideWhenDormant) as? Bool
            ?? Default.hideWhenDormant
        mark = (store.string(forKey: Key.mark).flatMap(Mark.init(rawValue:))) ?? Default.mark
        showsPercentage = store.object(forKey: Key.showsPercentage) as? Bool
            ?? Default.showsPercentage
        let names = store.stringArray(forKey: Key.trackedSources) ?? []
        let restored = Set(names.compactMap(SourceID.init(rawValue:)))
        trackedSources = restored.isEmpty ? Default.trackedSources : restored
    }

    /// Back to the design board's own marks. Scoped to the scale it sits beside:
    /// a button that also silently flipped the toggles two rows down would be
    /// doing more than it says.
    func resetThresholds() {
        warnAt = Default.warnAt
        criticalAt = Default.criticalAt
    }

    var hasDefaultThresholds: Bool {
        warnAt == Default.warnAt && criticalAt == Default.criticalAt
    }

    /// One place, so `init` and `reset` cannot disagree about what default means.
    private enum Default {
        static let warnAt: Double = 75
        static let criticalAt: Double = 90
        static let soundOnThreshold = true
        static let hideWhenDormant = true
        static let mark = Mark.capsuleBar
        static let showsPercentage = true
        static let trackedSources = Set(SourceID.allCases)
    }

    /// Clamped on the way out, so a hand-edited plist cannot invert the scale.
    var thresholds: ToneScale {
        ToneScale(warnAt: min(warnAt, criticalAt), critAt: max(warnAt, criticalAt))
    }

    private enum Key {
        static let warnAt = "pref.warnAt"
        static let criticalAt = "pref.criticalAt"
        static let soundOnThreshold = "pref.soundOnThreshold"
        static let hideWhenDormant = "pref.hideWhenDormant"
        static let mark = "pref.mark"
        static let showsPercentage = "pref.showsPercentage"
        static let trackedSources = "pref.trackedSources"
    }
}
