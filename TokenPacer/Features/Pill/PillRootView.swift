import AppKit
import SwiftUI

struct PillRootView: View {
    let model: PillModel
    let store: UsageStore
    /// Never defaulted. `Preferences.init` reads and writes `UserDefaults`, and a
    /// default on a view property runs it every time SwiftUI rebuilds the struct.
    let preferences: Preferences
    /// Nil in tests and in a `swift run` build: constructing one starts
    /// Sparkle's scheduler, and a menu row is not worth a network call.
    var updater: Updater?
    var onOpenPreferences: () -> Void = {}

    var menuItems: [NotchMenuItem] {
        [
            NotchMenuItem(title: String(localized: "Preferences"), key: "⌘,", action: onOpenPreferences),
            NotchMenuItem(title: String(localized: "Check for updates"), isEnabled: updater?.canCheck ?? false) {
                updater?.checkForUpdates()
            },
            NotchMenuItem(title: String(localized: "Send feedback")) {
                NSWorkspace.shared.open(AppInfo.feedbackPage)
            },
            NotchMenuItem(title: String(localized: "Quit Token Pacer"), key: "⌘Q") { NSApp.terminate(nil) },
        ]
    }

    /// Jobs in flight, or none when the count is switched off. One answer, so
    /// the badge the view draws and the wing the model measures cannot disagree
    /// about whether the count is there.
    private var workingSessions: Int {
        preferences.showsJobCount ? store.workingSessions : 0
    }

    /// What the right wing's badge slot holds, if anything. The view draws from
    /// the same answer the model measures the wing with.
    private var badge: PillState.Badge? {
        if store.errors[store.activeSource] != nil { return .alert }
        return workingSessions > 0 ? .working(workingSessions) : nil
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
            errors: store.errors,
            workingSessions: workingSessions,
            bySource: store.bySource,
            onTogglePinned: { model.togglePinned() },
            onClose: { model.setPinned(false) },
            onContentHeight: { model.contentHeight = $0 },
            onOpenMenu: { model.toggleMenu() },
            onRecheck: { store.recheck() },
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
            // Which provider the strip reports. The card compares them all;
            // this is the one the menu bar carries.
            .onChange(of: preferences.pillSource, initial: true) { _, source in
                store.activeSource = source
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
            .onChange(of: preferences.hidesAfterQuietMinutes) { _, _ in
                model.update(snapshot: store.snapshot)
            }
            // The shell is black in every state, so its contents are never styled
            // for a light desktop.
            .environment(\.colorScheme, .dark)
    }
}
