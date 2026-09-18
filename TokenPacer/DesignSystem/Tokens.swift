import SwiftUI

/// Design tokens lifted from `design/Token Pacer.dc.html`.
enum Tokens {
    static let green = Color(hex: 0x3ec98a)
    static let amber = Color(hex: 0xe8b33c)
    static let red = Color(hex: 0xe2543f)
    static let blue = Color(hex: 0x5aa9d6)

    /// The marker's own scale, one step brighter than the zone it sits in. A
    /// marker in the zone's own colour disappears into the capsule under it.
    static let lightGreen = Color(hex: 0xa5f0cd)
    static let lightAmber = Color(hex: 0xfbcda2)
    static let lightRed = Color(hex: 0xf4ab9e)

    /// The one tone rule. Session, weekly cap and every bar share it.
    static func tone(_ pct: Double, warnAt: Double = 75, critAt: Double = 90) -> Color {
        pct >= critAt ? red : pct >= warnAt ? amber : green
    }

    /// The same rule, one scale up, for whatever rides the zones rather than
    /// filling them.
    static func light(_ pct: Double, warnAt: Double = 75, critAt: Double = 90) -> Color {
        pct >= critAt ? lightRed : pct >= warnAt ? lightAmber : lightGreen
    }

    /// The context menu's own surface. Not `.regularMaterial`: a system material
    /// follows the desktop appearance, and in light mode the design's white text
    /// lands on a white sheet.
    static let menuSurface = Color(hex: 0x1e1e22).opacity(0.97)

    /// The count badge's own fill. Deliberately outside the tone scale: the
    /// number says how much is running, never how much is left.
    static let badgeFill = Color(hex: 0x4a4b53)

    static let shellRingIdle = Color.white.opacity(0.06)
    static let shellRingOpen = Color.white.opacity(0.13)

    /// The shell opening and closing. Stated as a duration, not as a stiffness:
    /// how long the expansion reads for is the thing being tuned, and
    /// `interpolatingSpring(stiffness:damping:)` hides that behind two figures
    /// that have to be solved for it. `bounce` holds the old settle — 0.18 is
    /// the damping ratio the 220/24 pair worked out to, just stretched in time.
    static let spring = Animation.spring(duration: 0.6, bounce: 0.18)
}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xff) / 255,
            green: Double((hex >> 8) & 0xff) / 255,
            blue: Double(hex & 0xff) / 255
        )
    }
}
