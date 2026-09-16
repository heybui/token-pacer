import AppKit
import SwiftUI

/// The panel is permanently the size of the largest state, so most of it is empty.
/// Without this, that empty area would swallow menu-bar and desktop clicks.
///
/// Hit-testing is limited to the shell rect the current state actually draws.
final class PassthroughHostingView<Content: View>: NSHostingView<Content> {
    /// Size of the shell currently drawn, top-centred in the host.
    var liveSize: CGSize = .zero
    /// SwiftUI has no right-click gesture, and the design's menu is not an NSMenu.
    var onRightMouseDown: (() -> Void)?

    override func rightMouseDown(with event: NSEvent) { onRightMouseDown?() }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        let rect = CGRect(
            x: (bounds.width - liveSize.width) / 2,
            y: isFlipped ? 0 : bounds.height - liveSize.height,
            width: liveSize.width,
            height: liveSize.height
        )
        return rect.contains(local) ? super.hitTest(point) : nil
    }

    @MainActor required init(rootView: Content) { super.init(rootView: rootView) }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}
