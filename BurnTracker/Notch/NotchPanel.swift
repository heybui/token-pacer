import AppKit

/// Borderless, non-activating panel that floats above the menu bar and rides
/// along to every space and full-screen app.
final class NotchPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        level = .statusBar                       // above .mainMenu (24)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false                        // the shell draws its own
        isMovable = false
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
    }

    // Needed for Esc and ⌘⇧B on the pinned panel. `.nonactivatingPanel` keeps this
    // from stealing activation from the frontmost app.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
