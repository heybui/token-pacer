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
    /// Keeps `host` at the largest state's size while the window changes around
    /// it — see `NotchClipView`.
    private let clip: NotchClipView
    private var observers: [NSObjectProtocol] = []
    /// Live only while the panel is pinned — Esc has to close it, and nothing
    /// else in this app takes the keyboard.
    private var escapeMonitor: Any?
    /// The screen the panel is anchored to, kept so a resize can re-derive the
    /// frame without asking AppKit for the display list again.
    private var metrics: ScreenMetrics?
    /// A pending shrink. Cancelled by whatever happens next, which is what makes
    /// a hover that comes back mid-collapse cost nothing.
    private var shrink: Task<Void, Never>?

    init() {
        let watched = LogWatcher.watchedSources()
        watchers = watched.watchers
        store = UsageStore(
            sources: watched.sources,
            panels: [
                .claude: ClaudeUsagePanel(read: TerminalCLI.reader(.claude)),
                .codex: CodexStatusPanel(read: TerminalCLI.reader(.codex)),
                .copilot: CopilotUsagePanel(read: TerminalCLI.reader(.copilot)),
            ]
        )

        let size = PillState.hostSize
        panel = NotchPanel(contentRect: NSRect(origin: .zero, size: size))
        host = PassthroughHostingView(rootView: PillRootView(
            model: model, store: store, preferences: preferences, updater: updater,
            onOpenPreferences: { [preferences, preferencesWindow, store, updater] in
                preferencesWindow.show(preferences: preferences, store: store, updater: updater)
            }
        ))
        model.preferences = preferences
        clip = NotchClipView(frame: NSRect(origin: .zero, size: size))
        host.frame = NSRect(origin: .zero, size: size)
        clip.addSubview(host)
        panel.contentView = clip

        model.onChromeChange = { [weak self] liveSize, wantsKeyboard in
            self?.host.liveSize = liveSize
            self?.fit(to: liveSize)
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

        store.start()
        if ProcessInfo.processInfo.environment["TP_OPEN_PREFS"] != nil {
            NSApp.setActivationPolicy(.regular)
            preferencesWindow.show(preferences: preferences, store: store, updater: updater)
        }
    }

    func flush() async { await store.flush() }

    /// The board's rule: the notch carries the state, the banner carries the
    /// moment it changed. So it fires beside a notch that is in plain sight
    /// rather than only when something is covering it — and only on going over.
    /// Entering watch stays silent and visual; the mark simply tints amber.
    private func considerAlert(for snapshot: UsageSnapshot) {
        // The board's "Notify when over". Off, the crossing is still carried by
        // the pill — this silences the banner, not the reading.
        guard preferences.notifiesWhenOver else { return }
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
        case ",":
            preferencesWindow.show(preferences: preferences, store: store, updater: updater)
            model.closeMenu()
        case "q": NSApp.terminate(nil)
        default: return event
        }
        return nil
    }

    private func reanchor() {
        guard let screen = NotchAnchor.preferred(
            from: NSScreen.screens.map(\.metrics), main: NSScreen.main?.metrics
        ) else { return }
        metrics = screen
        model.band = NotchAnchor.band(screen)     // publishes chrome, which fits the window
        resize(to: windowSize(for: model.liveSize))
        // Also when the window did not move: a new band changes the size the
        // hosting view is held at, even on a screen of the same dimensions.
        clip.pin(host, size: PillState.hostSize(around: model.band))
        panel.orderFrontRegardless()
    }

    // MARK: - the window tracks the state

    /// How long to wait before shrinking: the shell's spring, plus a margin.
    ///
    /// §1.1's rule is that the window frame never moves *while a spring runs* —
    /// you cannot get overshoot out of `setFrame` and it jitters against the
    /// compositor. Growing before the spring starts and shrinking after it has
    /// settled keeps that rule and still leaves the window the size of what is
    /// drawn in it, which is what the screenshot picker highlights: it was
    /// offering an 876×795 frame for a 226×30 pill.
    private static let settle: Duration = .milliseconds(750)

    private func fit(to liveSize: CGSize) {
        shrink?.cancel()
        let target = windowSize(for: liveSize)
        let current = panel.frame.size

        // Grow at once. A shell that outran its window would be clipped for the
        // length of the morph, which is the one frame anybody is looking at.
        if target.width > current.width || target.height > current.height {
            resize(to: CGSize(
                width: max(target.width, current.width),
                height: max(target.height, current.height)
            ))
        }
        guard target.width < current.width || target.height < current.height else { return }

        shrink = Task { [weak self] in
            try? await Task.sleep(for: Self.settle)
            guard !Task.isCancelled, let self else { return }
            resize(to: windowSize(for: model.liveSize))
        }
    }

    /// The window a shell of this size needs: the shell, plus the room its own
    /// shadow falls into, and never more than the largest state would take.
    ///
    /// The shadow's margin doubles as headroom for the spring's overshoot — 62pt
    /// each side against a bounce that peaks under 8% of 752 — so the shell is
    /// never clipped at the top of its travel.
    private func windowSize(for liveSize: CGSize) -> CGSize {
        let full = PillState.hostSize(around: model.band)
        guard liveSize.width > 0, liveSize.height > 0 else { return full }
        return CGSize(
            width: min(full.width, liveSize.width + 2 * PillState.shadowReach),
            height: min(full.height, liveSize.height + PillState.shadowOffsetY + PillState.shadowReach)
        )
    }

    private func resize(to size: CGSize) {
        guard let metrics, size != panel.frame.size else { return }
        panel.setFrame(NotchAnchor.hostFrame(for: metrics, size: size), display: true)
        clip.pin(host, size: PillState.hostSize(around: model.band))
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
