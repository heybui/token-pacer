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

    private let store: UserDefaults

    init(store: UserDefaults = .standard) {
        self.store = store
        // `object(forKey:)` rather than `double(forKey:)`: an unset key reads as
        // zero, which would silently make every pill red.
        warnAt = store.object(forKey: Key.warnAt) as? Double ?? 75
        criticalAt = store.object(forKey: Key.criticalAt) as? Double ?? 90
        soundOnThreshold = store.object(forKey: Key.soundOnThreshold) as? Bool ?? true
        hideWhenDormant = store.object(forKey: Key.hideWhenDormant) as? Bool ?? true
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
    }
}
