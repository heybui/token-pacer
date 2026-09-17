import CoreGraphics

/// The eight states from the design board. One object, one shell, different sizes.
enum PillState: String, CaseIterable, Sendable {
    case dormant, ghost, collapsed, hover, warning, exhausted, paused, pinned

    /// Shell dimensions, verbatim from the design board.
    var size: CGSize {
        switch self {
        case .dormant: CGSize(width: 226, height: 3)
        case .ghost, .collapsed, .exhausted, .paused: CGSize(width: 226, height: 36)
        case .hover, .warning: CGSize(width: 404, height: 98)
        case .pinned: CGSize(width: 752, height: 540)
        }
    }

    /// Bottom corner radius; the shell only ever grows downward out of the notch.
    var cornerRadius: CGFloat {
        switch self {
        case .dormant: 6
        case .ghost, .collapsed, .exhausted, .paused: 13
        case .hover, .warning, .pinned: 26
        }
    }

    var opacity: Double { self == .ghost ? 0.45 : 1 }

    /// The shell casts its own shadow, so its geometry belongs here with the rest.
    static let shadowRadius: CGFloat = 31
    static let shadowOffsetY: CGFloat = 22

    /// How far the shadow reaches past the shell it is cast from.
    static let shadowReach: CGFloat = shadowRadius * 2

    /// A hosting view clips to its bounds, so the host has to clear the largest
    /// shell by the shadow's whole reach — otherwise the blur ends in a hard
    /// rectangle around the pinned panel — and by the menu's drop, which opens
    /// under the panel as readily as under the pill. Derived, never typed in:
    /// the margin and the things needing it cannot drift apart.
    static let hostSize = CGSize(
        width: max(PillState.pinned.size.width, menuWidth) + shadowReach * 2,
        height: PillState.pinned.size.height + menuDrop + shadowOffsetY + shadowReach
    )

    /// Room for the menu below the tallest shell. `PillModel.menuHeight` carries
    /// the real figure at runtime; this reserves for the list the app builds.
    static let menuDrop = menuGap + menuHeight(items: 6)

    /// The context menu's own geometry, from the same design board.
    static let menuGap: CGFloat = 6
    static let menuWidth: CGFloat = 212
    static let menuRowHeight: CGFloat = 25
    static let menuPadding: CGFloat = 5

    static func menuHeight(items: Int) -> CGFloat {
        CGFloat(items) * menuRowHeight + menuPadding * 2
    }
}
