import CoreGraphics

/// Screen facts the anchor needs. Pure value type so the geometry is testable
/// without an NSScreen.
struct ScreenMetrics: Equatable, Sendable {
    var frame: CGRect
    var safeAreaTop: CGFloat
    var auxiliaryTopLeft: CGRect?
    var auxiliaryTopRight: CGRect?
}

/// Where the panel sits. Pure geometry — no AppKit.
enum NotchAnchor {
    /// Physical notch width, or nil on a screen without one (external displays,
    /// pre-2021 Macs). The pill still docks top-centre there; it just isn't hidden
    /// behind hardware.
    static func notchWidth(_ m: ScreenMetrics) -> CGFloat? {
        guard m.safeAreaTop > 0,
              let left = m.auxiliaryTopLeft,
              let right = m.auxiliaryTopRight
        else { return nil }
        let width = m.frame.width - left.width - right.width
        return width > 0 ? width : nil
    }

    /// The screen the pill belongs on. A notch, when the Mac has one — that is
    /// the whole product, and `NSScreen.main` is the screen holding the key
    /// window, which for an app with no windows is whatever was focused last.
    /// Clamshell or a desktop Mac falls back to the main screen.
    static func preferred(from screens: [ScreenMetrics], main: ScreenMetrics?) -> ScreenMetrics? {
        screens.first { notchWidth($0) != nil } ?? main ?? screens.first
    }

    /// Fixed-size host frame in global screen coordinates: top-centred, top edge
    /// flush with the top of the screen so the shell grows downward out of the notch.
    static func hostFrame(for m: ScreenMetrics, size: CGSize) -> CGRect {
        CGRect(
            x: m.frame.midX - size.width / 2,
            y: m.frame.maxY - size.height,
            width: size.width,
            height: size.height
        )
    }
}
