import CoreGraphics

/// The eight states from the design board. One object, one shell, different sizes.
enum PillState: String, CaseIterable, Sendable {
    case dormant, ghost, collapsed, hover, warning, exhausted, paused, pinned

    /// Shell dimensions, verbatim from the design board.
    var size: CGSize {
        switch self {
        case .dormant: CGSize(width: 226, height: 3)
        case .ghost, .collapsed, .exhausted, .paused: CGSize(width: 226, height: 36)
        // A floor, not the height. These two size to their content (`fitsContent`)
        // because the card's rows are a list now — one per provider plus the week,
        // and a preference is coming that turns providers off. The board's 98 was
        // drawn for a ring and two lines; any single number here is wrong for some
        // of the lists the card can hold.
        case .hover, .warning: CGSize(width: 404, height: 98)
        case .pinned: CGSize(width: 752, height: 540)
        }
    }

    /// States whose height is their content's, not the board's.
    ///
    /// The hover card holds a row per tracked provider and the week, and how many
    /// of those there are is a preference. A fixed height is either short of the
    /// longest list or padded out below the shortest — the screenshot that started
    /// this showed a third of the card empty under two rows.
    var fitsContent: Bool {
        switch self {
        case .hover, .warning: true
        case .dormant, .ghost, .collapsed, .exhausted, .paused, .pinned: false
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

    /// A shadow is cast by something floating above the screen, and the small
    /// states are not floating: they sit flush in the menu bar row, continuous
    /// with the notch's own black. A 31pt shadow under them reads as a seam
    /// across the top of the screen rather than as depth.
    ///
    /// It is also an offscreen render pass, and the collapsed pill is on screen
    /// for hours at a time.
    var castsShadow: Bool {
        switch self {
        case .hover, .warning, .pinned: true
        case .dormant, .ghost, .collapsed, .paused, .exhausted: false
        }
    }

    /// Smallest strip either side of the notch the figures fit in, and no wider.
    ///
    /// What the two wings hold, and therefore how wide they are.
    ///
    /// Measured from the content rather than fixed, because the content moves:
    /// the mark is a preference (18pt for the ring, 36 for the bar), the headline
    /// is four characters or two, and the countdown is "4h 59m" until a weekly
    /// window makes it "12d 07h". A constant sized for the worst of those leaves
    /// the band permanently wider than what is in it.
    ///
    /// **One figure for both wings.** The shell is centred on the notch, so
    /// unequal flanks would sit the hardware off-centre inside its own shell.
    /// Whichever side is wider sets both, and the other carries the slack.
    struct Wings: Equatable, Sendable {
        var mark: Mark = .capsuleBar
        var headline = "100%"
        var tail = "12d 07h"
        var hasBadge = false

        /// SF Mono runs 0.6em to the character, which is the figure the flanks
        /// were sized by hand from before this measured them.
        private static func mono(_ text: String, _ size: CGFloat) -> CGFloat {
            CGFloat(text.count) * size * 0.6
        }

        var flank: CGFloat {
            let left = leadingGutter + mark.width + markGap + Self.mono(headline, 12)
            let right = Self.mono(tail, 11.5)
                + (hasBadge ? badgeSize + markGap : 0)
                + trailingGutter
            return ceil(max(left, right))
        }

        /// What the wings hold in a given state, which is both what the view
        /// draws and what the shell is measured from. One function, so the two
        /// can never disagree about how much room a figure needs.
        static func of(
            state: PillState, snapshot: UsageSnapshot?, mark: Mark, hasBadge: Bool
        ) -> Wings {
            let headline = switch state {
            case .ghost: Format.percent(snapshot?.weeklyPercent)
            default: Format.percent(snapshot?.sessionPercent)
            }
            let tail = switch state {
            case .paused: "paused"
            case .ghost: "week"
            default: Format.countdown(to: snapshot?.resetsAt)
            }
            return Wings(mark: mark, headline: headline, tail: tail, hasBadge: hasBadge)
        }

        /// What the host reserves: the widest either wing can ever be, so the
        /// window never has to grow while the shell inside it does.
        static let widest = Wings(
            mark: Mark.allCases.max { $0.width < $1.width } ?? .capsuleBar,
            headline: "1.25M", tail: "12d 07h", hasBadge: true
        ).flank
    }

    static let leadingGutter: CGFloat = 11
    static let trailingGutter: CGFloat = 13
    static let markGap: CGFloat = 12
    static let badgeSize: CGFloat = 10

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
    ///
    /// A notchless screen has a band too — the menu bar row — and it is the one
    /// that matters there: the board's 36pt collapsed pill hung below the row on
    /// an external display, its bottom edge lining up with nothing.
    func size(around band: NotchBand, wings: Wings = Wings()) -> CGSize {
        guard !band.isEmpty, self != .dormant else { return size }
        // Hovering changes the height, never the width. The shell is one object
        // growing downward out of the notch, and a pill that widened as well read
        // as a second one sliding in behind the first. The panel is the exception:
        // it is a sheet, not a widened pill.
        // Off a notched screen there is no hardware to reach around and no
        // flanks to measure, so the board's width stands; the row only ever sets
        // the height there.
        let banded = band.notchWidth > 0 ? band.notchWidth + 2 * wings.flank : size.width
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
            // The widest the flanks can ever be, not the widest they are now: the
            // window is resized by the controller, the shell by a spring inside
            // it, and a shell that outgrew its window would be clipped mid-morph.
            width: max(hostSize.width, band.notchWidth + 2 * (Wings.widest + shadowReach)),
            height: hostSize.height + band.height
        )
    }

    /// Room for the menu below the tallest shell. `PillModel.menuHeight` carries
    /// the real figure at runtime; this reserves for the list the app builds.
    static let menuDrop = menuGap + menuHeight(items: 5)

    /// The context menu's own geometry, from the same design board.
    static let menuGap: CGFloat = 6
    static let menuWidth: CGFloat = 212
    static let menuRowHeight: CGFloat = 25
    static let menuPadding: CGFloat = 5

    static func menuHeight(items: Int) -> CGFloat {
        CGFloat(items) * menuRowHeight + menuPadding * 2
    }
}
