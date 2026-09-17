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

    /// States that say everything they have to say in the strips either side of
    /// the notch, and so stop at the bottom of the menu bar row.
    var fillsFlanks: Bool {
        switch self {
        case .collapsed, .ghost, .paused, .exhausted: true
        case .dormant, .hover, .warning, .pinned: false
        }
    }

    /// Smallest strip either side of the notch the figures fit in, and no wider.
    ///
    /// The widest each side has to hold: on the left an 11pt gutter, the 17pt
    /// ring, 8pt of spacing and a five-character headline ("1.25M", before a
    /// ceiling is known); on the right a six-character countdown and a 13pt
    /// gutter. Mono at 12pt runs about 7.2pt a character, so 74 fits both with a
    /// couple of points to spare and nothing to waste.
    static let flank: CGFloat = 74

    /// Where an expanded body starts, under the band.
    ///
    /// The board opens every one of them 26pt down so the first line cleared the
    /// notch. The band clears it now, so the body starts here instead and is
    /// `reclaimedTop` shorter — the space is given back, not left empty at the
    /// bottom of the card.
    static let bandedBodyTop: CGFloat = 10
    static let boardBodyTop: CGFloat = 26
    static var reclaimedTop: CGFloat { boardBodyTop - bandedBodyTop }

    /// The shell as actually drawn around a notch: wide enough to reach past the
    /// hardware on both sides, tall enough to run up behind it.
    ///
    /// The black has to span the notch. Stop it at the chin and the wallpaper
    /// shows either side of the camera, so a shell that should look grown out of
    /// the hardware reads as one floating under it. What goes *in* the band is
    /// the flanks, never the middle — the notch's width is dead space by
    /// definition. A state that fits there is exactly the band tall, so its
    /// bottom edge lines up with the end of the menu bar.
    ///
    /// Dormant is the exception and keeps the board's hairline: "no activity"
    /// means the notch reads as stock hardware, and a black bar beside the
    /// camera is the one thing that would give it away.
    func size(around band: NotchBand) -> CGSize {
        guard !band.isEmpty, self != .dormant else { return size }
        // Hovering changes the height, never the width. The shell is one object
        // growing downward out of the notch, and a pill that widened as well read
        // as a second one sliding in behind the first. The panel is the exception:
        // it is a sheet, not a widened pill.
        let banded = band.notchWidth + 2 * PillState.flank
        return CGSize(
            width: self == .pinned ? max(size.width, banded) : banded,
            height: band.height + (fillsFlanks ? 0 : size.height - PillState.reclaimedTop)
        )
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

    /// The host around the same notch: the shell starts a band higher, and on a
    /// wide notch the flanks can outgrow every shell the board drew.
    static func hostSize(around band: NotchBand) -> CGSize {
        CGSize(
            width: max(hostSize.width, band.notchWidth + 2 * (flank + shadowReach)),
            height: hostSize.height + band.height
        )
    }

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
