import CoreGraphics

/// Screen facts the anchor needs. Pure value type so the geometry is testable
/// without an NSScreen.
struct ScreenMetrics: Equatable, Sendable {
    var frame: CGRect
    var safeAreaTop: CGFloat
    var auxiliaryTopLeft: CGRect?
    var auxiliaryTopRight: CGRect?
    /// Height of the menu bar row on this screen. 39pt beside a 38pt notch —
    /// they are not the same figure, and the shell answers to this one.
    var menuBarHeight: CGFloat = 0
    /// Only the panel wired into the Mac can have a notch. Nothing else in these
    /// metrics can tell an external display apart from the built-in one.
    var isBuiltIn: Bool = false
}

/// The strip the shell lives in, and the hardware it works around.
struct NotchBand: Equatable, Sendable {
    /// The physical notch: dead space, no content ever laid out across it.
    /// Zero off a notched screen, where the row is still there and only the
    /// hardware is missing.
    var notchWidth: CGFloat = 0
    /// The menu bar row, which is a point taller than the notch it wraps.
    ///
    /// The shell's band is this, never the notch's own height. Deeper and the
    /// pill hangs below the menu bar with its bottom edge lining up with
    /// nothing; shallower and its edge sits on the chin, where the running
    /// light is drawn along the hardware instead of below it.
    var height: CGFloat = 0

    var isEmpty: Bool { height <= 0 }
}

/// Where the panel sits. Pure geometry — no AppKit.
enum NotchAnchor {
    /// Physical notch width, or nil on a screen without one (external displays,
    /// pre-2021 Macs). The pill still docks top-centre there; it just isn't hidden
    /// behind hardware.
    static func notchWidth(_ m: ScreenMetrics) -> CGFloat? {
        // The built-in check is the load-bearing one. A external display reports a
        // top safe area for the menu bar and fills in both auxiliary areas with
        // it, which is the same shape a notch makes — and the shell then sized
        // itself around hardware that is not there.
        guard m.isBuiltIn,
              m.safeAreaTop > 0,
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

    /// The hardware itself: the hole the shell reaches around, and the one
    /// rectangle no content may be laid out in.
    ///
    /// Not an offset. Hanging the shell off the notch's chin instead leaves
    /// wallpaper either side of the camera and the card reads as floating under
    /// the hardware rather than grown out of it.
    ///
    /// Measured per screen, never assumed. The same panel reports 220x38 scaled
    /// and 185x32 at default, so a constant would be wrong on most Macs.
    /// See crestnotch.app/macbook-notch-dimensions.
    ///
    /// Measured on every screen, notch or none. An external display has no
    /// hardware to reach around but it still has a menu bar row, and that row is
    /// what the shell's height answers to — it is taller on a scaled 5K panel
    /// than on a 1080p one, so the board's 36pt is wrong on both. AppKit reports
    /// the row in points already, which is the resolution and the backing scale
    /// resolved: `frame - visibleFrame` needs no DPI arithmetic on top of it.
    static func band(_ m: ScreenMetrics) -> NotchBand {
        // The safe area is the floor, not the answer: with the menu bar set to
        // hide automatically the row measures zero, and the hardware is still
        // there.
        let height = max(m.safeAreaTop, m.menuBarHeight)
        guard height > 0 else { return NotchBand() }
        return NotchBand(notchWidth: notchWidth(m) ?? 0, height: height)
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
