import AppKit
import SwiftUI

/// Owns the panel and keeps it glued to the notch of whichever screen is active.
@MainActor
final class NotchController {
    private let model = PillModel()
    private let store = UsageStore(
        usageAPI: ClaudeUsageAPI(token: ClaudeCredentials.tokenProvider)
    )
    private let panel: NotchPanel
    private let host: PassthroughHostingView<PillRootView>
    private var observers: [NSObjectProtocol] = []
    /// Live only while the panel is pinned — Esc has to close it, and nothing
    /// else in this app takes the keyboard.
    private var escapeMonitor: Any?

    init() {
        let size = PillState.hostSize
        panel = NotchPanel(contentRect: NSRect(origin: .zero, size: size))
        host = PassthroughHostingView(rootView: PillRootView(model: model, store: store))
        host.frame = NSRect(origin: .zero, size: size)
        panel.contentView = host

        model.onChromeChange = { [weak self] liveSize, wantsKeyboard in
            self?.host.liveSize = liveSize
            self?.setKeyboardActive(wantsKeyboard)
        }
        host.liveSize = model.liveSize
        host.onRightMouseDown = { [weak model] in model?.toggleMenu() }

        observe()
        reanchor()
        panel.orderFrontRegardless()
        store.start()
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
        panel.setFrame(NotchAnchor.hostFrame(for: metrics, size: PillState.hostSize), display: true)
        model.hasNotch = NotchAnchor.notchWidth(metrics) != nil
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
            auxiliaryTopRight: auxiliaryTopRightArea
        )
    }
}
