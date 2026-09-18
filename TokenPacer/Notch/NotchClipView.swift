import AppKit

/// Holds the hosting view at a fixed size inside a window that changes size.
///
/// The window tracks the state (`NotchController.fit`), but SwiftUI must not:
/// handing it the window's bounds re-lays the whole tree out in the same
/// transaction as the state change, and the shell jumps between sizes instead of
/// springing between them. So the hosting view keeps the largest state's frame
/// for ever, pinned to the top of this view, and the window simply clips it.
///
/// `autoresizesSubviews` is off for the same reason: an automatic resize is the
/// bounds change this exists to prevent.
final class NotchClipView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        autoresizesSubviews = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Clicks that the hosting view lets through must keep going — to the menu
    /// bar, or to whatever is on the desktop below. `NSView`'s own answer is
    /// "me, if the point is inside my bounds", which would swallow them.
    override func hitTest(_ point: NSPoint) -> NSView? {
        subviews.lazy.compactMap { $0.hitTest(point) }.first
    }

    /// The hosting view hangs from the top edge, centred. A window shorter than
    /// it leaves the rest below the sill, which is exactly what should be cut.
    func pin(_ view: NSView, size: CGSize) {
        view.frame = CGRect(
            x: ((bounds.width - size.width) / 2).rounded(),
            y: bounds.height - size.height,
            width: size.width,
            height: size.height
        )
    }
}
