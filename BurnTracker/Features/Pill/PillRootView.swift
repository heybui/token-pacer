import AppKit
import SwiftUI

struct PillRootView: View {
    let model: PillModel
    let store: UsageStore
    var preferences = Preferences()
    /// Nil in tests and in a `swift run` build: constructing one starts
    /// Sparkle's scheduler, and a menu row is not worth a network call.
    var updater: Updater?
    var onOpenPreferences: () -> Void = {}

    /// Where "Send feedback" goes. One constant, so the day the page moves it
    /// moves once.
    private static let landingPage = URL(string: "https://github.com/heybui/burn-tracker")!

    var menuItems: [NotchMenuItem] {
        [
            NotchMenuItem(title: "Preferences", key: "⌘,", action: onOpenPreferences),
            NotchMenuItem(title: model.inputs.isPaused ? "Resume tracking" : "Pause tracking") {
                setPaused(!model.inputs.isPaused)
            },
            NotchMenuItem(title: "Check for updates", isEnabled: updater?.canCheck ?? false) {
                updater?.checkForUpdates()
            },
            NotchMenuItem(title: "Send feedback") {
                NSWorkspace.shared.open(Self.landingPage)
            },
            NotchMenuItem(title: "Quit Burn Tracker", key: "⌘Q") { NSApp.terminate(nil) },
        ]
    }

    /// Pausing stops the polling as well as the display: "tracking is off, not
    /// idle". Nothing is read, so nothing can alert, and it survives a relaunch.
    private func setPaused(_ paused: Bool) {
        model.setPaused(paused)
        store.setPaused(paused)
    }

    var body: some View {
        PillView(
            state: model.state,
            snapshot: store.snapshot,
            attention: store.errors[store.activeSource],
            bySource: store.bySource,
            onTogglePinned: { model.togglePinned() },
            onClose: { model.setPinned(false) },
            isMenuOpen: model.isMenuOpen,
            menuItems: menuItems,
            onCloseMenu: { model.closeMenu() },
            onHoverChange: { model.setPointerInside($0) },
            band: model.band
        )
            .onAppear { model.menuHeight = PillState.menuHeight(items: menuItems.count) }
            .onChange(of: store.snapshot) { _, snapshot in
                model.update(snapshot: snapshot)
            }
            // The tone rule reaches every bar, ring and square from one place.
            .environment(\.tone, preferences.thresholds)
            .onChange(of: preferences.criticalAt) { _, _ in model.update(snapshot: store.snapshot) }
            .onChange(of: preferences.hideWhenDormant) { _, _ in
                model.update(snapshot: store.snapshot)
            }
            // The shell is black in every state, so its contents are never styled
            // for a light desktop.
            .environment(\.colorScheme, .dark)
    }
}
