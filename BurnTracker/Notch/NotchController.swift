import AppKit
import SwiftUI

/// Owns the panel and keeps it glued to the notch of whichever screen is active.
@MainActor
final class NotchController {
    private let model = PillModel()
    private let store = UsageStore(
        usagePanel: ClaudeUsagePanel(read: ClaudeCLI.reader)
    )
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

        store.onSnapshot = { [weak self] snapshot in self?.considerAlert(for: snapshot) }

        observe()
        reanchor()
        panel.orderFrontRegardless()

        // Restored from the archive, so a paused app comes back paused rather
        // than quietly resuming on the next launch.
        model.setPaused(store.isPaused)
        if !store.isPaused { store.start() }
    }

    func flush() async { await store.flush() }

    /// The notch carries the alert itself whenever it can be seen; this is the
    /// fallback for the case where it cannot.
    private func considerAlert(for snapshot: UsageSnapshot) {
        guard !store.isPaused else { return }   // "No alerts fire while paused."
        let thresholds = [preferences.warnAt, preferences.criticalAt]
        guard let crossed = alerts.crossing(
            percent: snapshot.sessionPercent, resetsAt: snapshot.resetsAt, thresholds: thresholds
        ) else { return }

        let critical = crossed >= preferences.criticalAt
        notifier.alert(
            title: "\(snapshot.source.displayName) · \(Format.percent(snapshot.sessionPercent)) of the 5-hour window",
            body: critical
                ? "Wrap up soon — \(Format.countdown(to: snapshot.resetsAt)) until it resets."
                : "Running hot. \(Format.countdown(to: snapshot.resetsAt)) left at this pace.",
            sound: preferences.soundOnThreshold
        )
        Log.notch.info("alert at \(Int(crossed), privacy: .public)% (banner only if the notch is hidden)")
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

    /// The menu advertises ⌘C and ⌘Q, so they have to work wherever it can be
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
        case "c": UsageClipboard.copy(store.snapshot); model.closeMenu()
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
