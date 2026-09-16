import AppKit
import SwiftUI

struct PillRootView: View {
    let model: PillModel
    let store: UsageStore

    /// Preferences and updates are phases 4 and 6; the items are shown greyed
    /// rather than left out, so the menu keeps its shape.
    private var menuItems: [NotchMenuItem] {
        [
            NotchMenuItem(title: "Preferences…", key: "⌘,", isEnabled: false),
            NotchMenuItem(title: model.inputs.isPaused ? "Resume tracking" : "Pause tracking") {
                setPaused(!model.inputs.isPaused)
            },
            NotchMenuItem(title: "Copy usage summary", key: "⌘C") {
                UsageClipboard.copy(store.snapshot)
            },
            NotchMenuItem(title: "Check for updates…", isEnabled: false),
            NotchMenuItem(title: "About Burn Tracker") {
                NSApp.activate()
                NSApp.orderFrontStandardAboutPanel(nil)
            },
            NotchMenuItem(title: "Quit Burn Tracker", key: "⌘Q") { NSApp.terminate(nil) },
        ]
    }

    /// Pausing stops the polling as well as the display: "tracking is off, not
    /// idle". Nothing is read, so nothing can alert.
    private func setPaused(_ paused: Bool) {
        model.setPaused(paused)
        paused ? store.stop() : store.start()
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
            onCloseMenu: { model.closeMenu() }
        )
            .onAppear { model.menuHeight = NotchMenuView.height(items: menuItems.count) }
            .onHover { inside in
                // Only fires inside the shell rect, which is how we know
                // PassthroughHostingView is letting the rest of the panel through.
                model.setPointerInside(inside)
            }
            .onChange(of: store.snapshot) { _, snapshot in
                model.update(snapshot: snapshot)
            }
            // The shell is black in every state, so its contents are never styled
            // for a light desktop.
            .environment(\.colorScheme, .dark)
    }
}
