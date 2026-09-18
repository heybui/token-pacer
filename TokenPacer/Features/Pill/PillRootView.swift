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
                NSWorkspace.shared.open(AppInfo.landingPage)
            },
            NotchMenuItem(title: "Quit Token Pacer", key: "⌘Q") { NSApp.terminate(nil) },
        ]
    }

    /// Pausing stops the polling as well as the display: "tracking is off, not
    /// idle". Nothing is read, so nothing can alert, and it survives a relaunch.
    private func setPaused(_ paused: Bool) {
        model.setPaused(paused)
        store.setPaused(paused)
    }

    /// What the right wing's badge slot holds, if anything. The view draws from
    /// the same answer the model measures the wing with.
    private var badge: PillState.Badge? {
        if store.errors[store.activeSource] != nil { return .alert }
        let working = store.runningJobs
        return working > 0 ? .working(working) : nil
    }

    var body: some View {
        PillView(
            state: model.state,
            snapshot: store.snapshot,
            providers: SourceID.allCases
                .filter(preferences.tracks)
                .compactMap { store.snapshots[$0] },
            mark: preferences.mark,
            showsPercentage: preferences.showsPercentage,
            border: preferences.border,
            bordersOn: preferences.bordersOn,
            attention: store.errors[store.activeSource],
            workingJobs: store.runningJobs,
            bySource: store.bySource,
            onTogglePinned: { model.togglePinned() },
            onClose: { model.setPinned(false) },
            isMenuOpen: model.isMenuOpen,
            menuItems: menuItems,
            onCloseMenu: { model.closeMenu() },
            band: model.band
        )
            .onAppear { model.menuHeight = PillState.menuHeight(items: menuItems.count) }
            .onChange(of: store.snapshot) { _, snapshot in
                model.update(snapshot: snapshot)
            }
            // Geometry inputs: both change how wide the wings have to be.
            .onChange(of: preferences.mark, initial: true) { _, mark in
                model.inputs.mark = mark
                model.update(snapshot: store.snapshot)
            }
            .onChange(of: preferences.showsPercentage, initial: true) { _, shows in
                model.inputs.showsPercentage = shows
                model.update(snapshot: store.snapshot)
            }
            // Which providers are polled at all. Pushed into the store rather
            // than filtered out of its answers: an untracked CLI should not be
            // asked anything.
            .onChange(of: preferences.trackedSources, initial: true) { _, tracked in
                store.tracked = tracked
                model.update(snapshot: store.snapshot)
            }
            // Both feed one slot in the right wing, and either appearing changes
            // how wide that wing has to be.
            .onChange(of: badge, initial: true) { _, badge in
                model.inputs.badge = badge
                model.update(snapshot: store.snapshot)
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
