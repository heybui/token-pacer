import SwiftUI

/// Design tokens lifted from `design/Burn Tracker.dc.html`.
enum Tokens {
    static let green = Color(hex: 0x3ec98a)
    static let amber = Color(hex: 0xe8b33c)
    static let red = Color(hex: 0xe2543f)
    static let blue = Color(hex: 0x5aa9d6)

    /// The one tone rule. Session, weekly cap and every bar share it.
    static func tone(_ pct: Double, warnAt: Double = 75, critAt: Double = 90) -> Color {
        pct >= critAt ? red : pct >= warnAt ? amber : green
    }

    /// The context menu's own surface. Not `.regularMaterial`: a system material
    /// follows the desktop appearance, and in light mode the design's white text
    /// lands on a white sheet.
    static let menuSurface = Color(hex: 0x1e1e22).opacity(0.97)

    static let shellRingIdle = Color.white.opacity(0.06)
    static let shellRingOpen = Color.white.opacity(0.13)

    static let spring = Animation.interpolatingSpring(stiffness: 220, damping: 24)
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
