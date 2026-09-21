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
            NotchMenuItem(title: updateTitle, isEnabled: updater?.canCheck ?? false) {
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
    /// The row says what there is to do: check, or install what a background
    /// check already found.
    private var updateTitle: String {
        guard let version = updater?.pendingVersion else { return String(localized: "Check for updates") }
        return String(localized: "Update to \(version)")
    }

    /// The marks each provider is watched at, or none at all when the switch is
    /// off. Per provider, because the two numbers are.
    /// Named rather than inlined: two dictionaries built inside the view's own
    /// body put the type checker over its budget for the whole expression.
    private var zones: [SourceID: ToneScale] {
        Dictionary(uniqueKeysWithValues: SourceID.allCases.map { ($0, preferences.zone(for: $0)) })
    }

    private var jobsBySource: [SourceID: Int] {
        Dictionary(uniqueKeysWithValues: SourceID.allCases.map { ($0, store.workingSessions(of: $0)) })
    }

    /// Which provider the border speaks for while several are working: the one
    /// furthest through its own budget, since that is the one the colour is
    /// there to warn about.
    private var running: UsageSnapshot? {
        SourceID.allCases
            .filter { store.workingSessions(of: $0) > 0 }
            .compactMap { store.snapshots[$0] }
            .max { urgency(of: $0) < urgency(of: $1) }
    }

    /// How far through its own critical mark a provider is. A provider with no
    /// figure at all is the least urgent thing on the machine.
    private func urgency(of snapshot: UsageSnapshot) -> Double {
        guard let percent = snapshot.sessionPercent else { return 0 }
        return percent / max(1, preferences.zone(for: snapshot.source).critAt)
    }

    private var alertMarks: [SourceID: [Double]] {
        guard preferences.notifiesOnZone else { return [:] }
        return Dictionary(uniqueKeysWithValues: SourceID.allCases.map {
            ($0, preferences.alertThresholds(for: $0))
        })
    }

    private var workingSessions: Int {
        preferences.showsJobCount ? store.workingSessions : 0
    }

    /// What the right wing's badge slot holds, if anything. The view draws from
    /// the same answer the model measures the wing with.
    private var badge: PillState.Badge? {
        .of(
            attention: store.errors[store.activeSource],
            workingSessions: workingSessions,
            updateVersion: updater?.pendingVersion
        )
    }

    /// The pill itself, lifted out of `body`: with every input the shell now
    /// takes, one expression carrying both the call and its modifiers went past
    /// what the type checker will sit through.
    private var pill: some View {
        PillView(
            state: model.state,
            snapshot: store.snapshot,
            providers: SourceID.allCases
                .filter { preferences.tracks($0) && preferences.showsOnCard($0) }
                .compactMap { store.snapshots[$0] },
            mark: preferences.mark,
            showsPercentage: preferences.showsPercentage,
            border: preferences.border,
            bordersOn: preferences.bordersOn,
            attention: store.errors[store.activeSource],
            errors: store.errors,
            isAnyoneWorking: store.anyoneWorking,
            running: running,
            alert: store.alert,
            alerting: store.alert.flatMap { store.snapshots[$0.source] },
            pinned: preferences.pillSource,
            jobsBySource: jobsBySource,
            zones: zones,
            onPin: { preferences.pillSource = $0 },
            workingSessions: workingSessions,
            updateVersion: updater?.pendingVersion,
            onInstallUpdate: { updater?.checkForUpdates() },
            onTogglePinned: { model.togglePinned() },
            onClose: { model.setPinned(false) },
            onContentHeight: { model.contentHeight = $0 },
            onOpenSettings: onOpenPreferences,
            onRecheck: { store.recheck() },
            isMenuOpen: model.isMenuOpen,
            menuItems: menuItems,
            onCloseMenu: { model.closeMenu() },
            band: model.band
        )
    }

    var body: some View {
        pill
            .onAppear { model.menuHeight = PillState.menuHeight(items: menuItems.count) }
            .onChange(of: store.snapshot) { _, snapshot in
                model.update(snapshot: snapshot)
            }
            // Quiet is measured across every tracked provider, and a provider
            // that is not the pinned one waking up changes nothing about the
            // pinned one's snapshot.
            .onChange(of: store.lastActivity, initial: true) { _, activity in
                model.inputs.lastActivity = activity
                model.update(snapshot: store.snapshot)
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
            // The marks the store watches: the user's own, and none at all when
            // the switch is off.
            .onChange(of: alertMarks, initial: true) { _, marks in
                store.alertThresholds = marks
            }
            // The crossing the pill is carrying, from any provider. Cleared by
            // the hover that reads it, which the controller hands to the store.
            .onChange(of: store.alert, initial: true) { _, alert in
                model.inputs.alert = alert
                model.update(snapshot: store.snapshot)
            }
            .onChange(of: badge, initial: true) { _, badge in
                model.inputs.badge = badge
                model.update(snapshot: store.snapshot)
            }
            // The tone rule reaches every bar, ring and square from one place.
            .environment(\.tone, preferences.zone(for: preferences.pillSource))
            .onChange(of: preferences.zones) { _, _ in model.update(snapshot: store.snapshot) }
            .onChange(of: preferences.hidesAfterQuietMinutes) { _, _ in
                model.update(snapshot: store.snapshot)
            }
            // The shell is black in every state, so its contents are never styled
            // for a light desktop.
            .environment(\.colorScheme, .dark)
    }
}
