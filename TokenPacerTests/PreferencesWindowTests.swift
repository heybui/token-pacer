import AppKit
import Testing
@testable import TokenPacer

/// Closing the settings window has to end the view tree inside it, not hide it.
///
/// A SwiftUI view in a closed-but-retained window is never told it disappeared,
/// and the Appearance pane's preview lap went on stepping twelve marks ten times
/// a second for the rest of the run — 8% of a core, invisibly.
@MainActor @Test func closingPreferencesLetsGoOfWhatWasInIt() {
    let preferences = Preferences(store: UserDefaults(suiteName: #function) ?? .standard)
    let window = PreferencesWindow()

    window.show(preferences: preferences)
    #expect(window.isOpen)

    window.closeForTesting()
    #expect(!window.isOpen)

    // And it opens again afterwards rather than staying shut.
    window.show(preferences: preferences)
    #expect(window.isOpen)
}
