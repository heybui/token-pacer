import AppKit
import SwiftUI

/// Owns the panel and keeps it glued to the notch of whichever screen is active.
@MainActor
final class NotchController {
    private let model = PillModel()
    private let panel: NotchPanel
    private let host: PassthroughHostingView<PillRootView>
    private var observers: [NSObjectProtocol] = []

    init() {
        let size = PillState.hostSize
        panel = NotchPanel(contentRect: NSRect(origin: .zero, size: size))
        host = PassthroughHostingView(rootView: PillRootView(model: model))
        host.frame = NSRect(origin: .zero, size: size)
        panel.contentView = host

        model.onStateChange = { [weak self] state in self?.host.liveSize = state.size }
        host.liveSize = model.state.size

        observe()
        reanchor()
        panel.orderFrontRegardless()
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

    private func reanchor() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let metrics = screen.metrics
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
