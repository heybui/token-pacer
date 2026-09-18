import AppKit
import SwiftUI

/// The panel is permanently the size of the largest state, so most of it is empty.
/// Without this, that empty area would swallow menu-bar and desktop clicks.
///
/// Hit-testing and hover are both limited to the shell rect the current state
/// actually draws.
final class PassthroughHostingView<Content: View>: NSHostingView<Content> {
    /// Size of the shell currently drawn, top-centred in the host.
    var liveSize: CGSize = .zero {
        didSet { if liveSize != oldValue { updateTrackingAreas() } }
    }
    /// SwiftUI has no right-click gesture, and the design's menu is not an NSMenu.
    var onRightMouseDown: (() -> Void)?
    /// Hover is tracked here rather than with SwiftUI's `.onHover`. That installs
    /// one tracking area over the whole host — measured at 876x765 points against
    /// a 368x39 shell — and answers for all of it, so the pointer opened the card
    /// far below the notch, anywhere in the top third of the screen.
    var onHoverChange: ((Bool) -> Void)?

    private var hoverArea: NSTrackingArea?
    private var isInside = false

    /// The shell as drawn: top-centred, the size the current state reports. Both
    /// the click-through and the hover answer to this one rect, so they cannot
    /// drift apart.
    private var liveRect: CGRect {
        CGRect(
            x: (bounds.width - liveSize.width) / 2,
            y: isFlipped ? 0 : bounds.height - liveSize.height,
            width: liveSize.width,
            height: liveSize.height
        )
    }

    override func rightMouseDown(with event: NSEvent) { onRightMouseDown?() }

    override func hitTest(_ point: NSPoint) -> NSView? {
        liveRect.contains(convert(point, from: superview)) ? super.hitTest(point) : nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        // Not `.inVisibleRect`: that is exactly the host-wide area this replaces.
        // The rect is the shell, so entering it is entering the pill.
        let area = NSTrackingArea(
            rect: liveRect,
            options: [.mouseEnteredAndExited, .activeAlways],
            owner: self
        )
        addTrackingArea(area)
        hoverArea = area

        // Hovering resizes the shell, which rebuilds this area under a pointer
        // that never moved, and AppKit sends neither enter nor exit for that.
        // Settle it from where the pointer actually is rather than waiting for a
        // move that may never come.
        guard let point = window?.mouseLocationOutsideOfEventStream else { return }
        report(liveRect.contains(convert(point, from: nil)))
    }

    override func mouseEntered(with event: NSEvent) { report(true) }
    override func mouseExited(with event: NSEvent) { report(false) }

    /// Only on a change: a report resizes the shell, which rebuilds the area,
    /// which reports again. Second time round the answer is the same and it stops.
    private func report(_ inside: Bool) {
        guard inside != isInside else { return }
        isInside = inside
        onHoverChange?(inside)
    }

    @MainActor required init(rootView: Content) { super.init(rootView: rootView) }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}
