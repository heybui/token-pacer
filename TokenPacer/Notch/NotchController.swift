import AppKit
import SwiftUI

/// Owns the panel and keeps it glued to the notch of whichever screen is active.
@MainActor
final class NotchController {
    private let model = PillModel()
    /// Retained: releasing the watcher stops its stream, and its gate would then
    /// say "nothing changed" for the rest of the run.
    private var watchers: [LogWatcher]
    private let store: UsageStore
    private let preferences = Preferences()
    private let notifier = Notifier()
    private var alerts = AlertPolicy()
    private let preferencesWindow = PreferencesWindow()
    /// Constructing it starts Sparkle's scheduler, so it is owned here and
    /// handed to the view — never defaulted into a struct that gets rebuilt.
    private let updater = Updater()
    private let panel: NotchPanel
    private let host: PassthroughHostingView<PillRootView>
    private var observers: [NSObjectProtocol] = []
    /// Live only while the panel is pinned — Esc has to close it, and nothing
    /// else in this app takes the keyboard.
    private var escapeMonitor: Any?

    init() {
        let watched = LogWatcher.watchedSources()
        watchers = watched.watchers
        store = UsageStore(
            sources: watched.sources,
            usagePanel: ClaudeUsagePanel(read: ClaudeCLI.reader)
        )

        let size = PillState.hostSize
        panel = NotchPanel(contentRect: NSRect(origin: .zero, size: size))
        host = PassthroughHostingView(rootView: PillRootView(
            model: model, store: store, preferences: preferences, updater: updater,
            onOpenPreferences: { [preferences, preferencesWindow] in
                preferencesWindow.show(preferences: preferences)
            }
        ))
        model.preferences = preferences
        host.frame = NSRect(origin: .zero, size: size)
        panel.contentView = host

        model.onChromeChange = { [weak self] liveSize, wantsKeyboard in
            self?.host.liveSize = liveSize
            self?.setKeyboardActive(wantsKeyboard)
        }
        host.liveSize = model.liveSize
        host.onRightMouseDown = { [weak model] in model?.toggleMenu() }
        // Hover belongs to the host: it is the only thing that knows the rect the
        // shell actually occupies on screen.
        host.onHoverChange = { [weak model] inside in model?.setPointerInside(inside) }

        store.onSnapshot = { [weak self] snapshot in self?.considerAlert(for: snapshot) }

        // The registry pushes rather than being polled: the callback is the whole
        // update, and it hops to the main actor because that is where the store
        // lives, not because the reading needs it.
        if let registry = LogWatcher.registry(onChange: { [weak store] in
            Task { @MainActor in store?.refreshSessions() }
        }) {
            watchers.append(registry)
        }

        observe()
        reanchor()
        panel.orderFrontRegardless()

        // Restored from the archive, so a paused app comes back paused rather
        // than quietly resuming on the next launch.
        model.setPaused(store.isPaused)
        if !store.isPaused { store.start() }
    }

    func flush() async { await store.flush() }

    /// The board's rule: the notch carries the state, the banner carries the
    /// moment it changed. So it fires beside a notch that is in plain sight
    /// rather than only when something is covering it — and only on going over.
    /// Entering watch stays silent and visual; the mark simply tints amber.
    private func considerAlert(for snapshot: UsageSnapshot) {
        guard !store.isPaused else { return }   // "No alerts fire while paused."
        guard alerts.crossing(
            percent: snapshot.sessionPercent,
            resetsAt: snapshot.resetsAt,
            thresholds: [preferences.criticalAt]
        ) != nil else { return }

        notifier.alert(
            title: "Over",
            body: "\(Format.percent(snapshot.sessionPercent)) used, "
                + "\(Format.countdown(to: snapshot.resetsAt)) to the reset. "
                + "Consider finishing the current task before starting anything big.",
            sound: preferences.soundOnThreshold,
            whenNotchHidden: false
        )
        Log.notch.info("over banner at \(Int(self.preferences.criticalAt), privacy: .public)%")
    }

    private func observe() {
        let center = NotificationCenter.default
        // Display connected/disconnected, resolution change, menu-bar height change.
        observers.append(center.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.reanchor() } })

        // The user moved focus to a different display.
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.reanchor() } })
    }

    /// A non-activating panel never sees a keystroke unless it is key, and it
    /// cannot become key while another app is frontmost. Activating is the cost
    /// of Esc; focus goes back the moment the panel closes.
    private func setKeyboardActive(_ active: Bool) {
        guard active != (escapeMonitor != nil) else { return }
        if active {
            NSApp.activate()
            panel.makeKeyAndOrderFront(nil)
            escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                self.flatMap { $0.handle(event) } ?? event
            }
        } else {
            escapeMonitor.map(NSEvent.removeMonitor)
            escapeMonitor = nil
            NSApp.deactivate()
            panel.orderFrontRegardless()
        }
    }

    /// The menu advertises ⌘, and ⌘Q, so they have to work wherever it can be
    /// seen. An app with no menu bar has no responder chain to route them.
    private func handle(_ event: NSEvent) -> NSEvent? {
        if event.keyCode == 53 {                                     // Esc
            // The menu is drawn on top of the panel, so it closes first.
            if model.isMenuOpen { model.closeMenu() } else { model.setPinned(false) }
            return nil
        }
        guard event.modifierFlags.contains(.command) else { return event }
        switch event.charactersIgnoringModifiers {
        case ",": preferencesWindow.show(preferences: preferences); model.closeMenu()
        case "q": NSApp.terminate(nil)
        default: return event
        }
        return nil
    }

    private func reanchor() {
        guard let metrics = NotchAnchor.preferred(
            from: NSScreen.screens.map(\.metrics), main: NSScreen.main?.metrics
        ) else { return }
        let band = NotchAnchor.band(metrics)
        panel.setFrame(
            NotchAnchor.hostFrame(for: metrics, size: PillState.hostSize(around: band)),
            display: true
        )
        model.band = band
        panel.orderFrontRegardless()
    }

    // No deinit: the controller is owned by the app delegate for the whole
    // process lifetime, so there is nothing to tear down.
}

extension NSScreen {
    var metrics: ScreenMetrics {
        ScreenMetrics(
            frame: frame,
            safeAreaTop: safeAreaInsets.top,
            auxiliaryTopLeft: auxiliaryTopLeftArea,
            auxiliaryTopRight: auxiliaryTopRightArea,
            // `visibleFrame` is the screen less the menu bar and the Dock, so the
            // gap at the top is the row itself. An accessory app has no main menu
            // to ask, and `NSStatusBar.thickness` answers a different question.
            menuBarHeight: frame.maxY - visibleFrame.maxY,
            isBuiltIn: isBuiltIn
        )
    }

    /// The one fact AppKit will not state: `safeAreaInsets` and the auxiliary
    /// areas describe a menu bar as readily as a notch. CoreGraphics knows which
    /// panel is wired into the lid.
    private var isBuiltIn: Bool {
        guard let number = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        else { return false }
        return CGDisplayIsBuiltin(CGDirectDisplayID(number.uint32Value)) != 0
    }
}
