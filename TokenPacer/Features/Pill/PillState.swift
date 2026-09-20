import CoreGraphics

/// The seven states from the design board. One object, one shell, different sizes.
enum PillState: String, CaseIterable, Sendable {
    case hidden, ghost, collapsed, hover, warning, exhausted, pinned

    /// Shell dimensions, verbatim from the design board.
    var size: CGSize {
        switch self {
        case .hidden: CGSize(width: 226, height: 3)
        case .ghost, .collapsed, .exhausted: CGSize(width: 226, height: 36)
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
        case .hidden, .ghost, .collapsed, .exhausted, .pinned: false
        }
    }

    /// States that say everything they have to say in the strips either side of
    /// the notch, and so stop at the bottom of the menu bar row.
    var fillsFlanks: Bool {
        switch self {
        case .collapsed, .ghost, .exhausted: true
        case .hidden, .hover, .warning, .pinned: false
        }
    }

    /// A shadow is cast by something floating above the screen, and the small
    /// states are not floating: they sit flush in the menu bar row, continuous
    /// with the notch's own black. A 31pt shadow under them reads as a seam
    /// across the top of the screen rather than as depth.
    ///
    /// It is also an offscreen render pass, and the collapsed pill is on screen
    /// for hours at a time.
    ///
    /// The two states you open yourself — hover and pinned — dropped theirs as
    /// well. Only the warning still casts one: it is the one surface that
    /// arrives unasked, and the depth is what says so.
    var castsShadow: Bool {
        switch self {
        case .warning: true
        case .hidden, .ghost, .collapsed, .hover, .exhausted, .pinned: false
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
    /// What sits at the end of the right wing, when anything does.
    ///
    /// Two things compete for one slot, and the order is not a toss-up: a source
    /// that cannot be read makes every figure beside it unverified, so it wins.
    /// Jobs working out of sight are the next thing worth a corner of the notch,
    /// and a count rather than a dot because three running and one running are
    /// different answers to "can I close the lid". The pinned provider's own,
    /// like every other figure in the row.
    enum Badge: Equatable, Sendable {
        /// A source is complaining. The message lives on the store.
        case alert
        /// How many background jobs are working.
        case working(Int)

        /// The board's own figures: a circle for one digit, widened to a pill for
        /// two. Counted rather than measured, because the shape is specified as a
        /// multiple of its own diameter and not as whatever the font came out to.
        var width: CGFloat {
            switch self {
            case .alert: PillState.badgeSize
            case .working(let count):
                PillState.badgeDiameter
                    + PillState.badgeDigitWidth * CGFloat(max(0, String(count).count - 1))
            }
        }

        /// What separates it from the thing beside it. The alert badge keeps the
        /// row's own spacing; the count is drawn tight against the countdown it
        /// qualifies, as the board asks.
        var gap: CGFloat {
            switch self {
            case .alert: PillState.markGap
            case .working: PillState.badgeGap
            }
        }
    }

    struct Wings: Equatable, Sendable {
        var mark: Mark = .capsuleBar
        var headline = "100%"
        /// Off drops the figure from the row and its width from the wing.
        var showsPercentage = true
        var tail = "12d 07h"
        var badge: Badge?

        /// Asked of the font, through the same rule the odometer draws by.
        private static func mono(_ text: String, _ size: CGFloat) -> CGFloat {
            Typography.monoWidth(text, size: size)
        }

        @MainActor var flank: CGFloat {
            // The trailing `markGap` on each side is the row's own spacing between
            // the last thing in a wing and the gap held open for the notch. It is
            // not decoration and it is not optional: left it out, the formula came
            // up 12pt short a side, the row over-committed its shell, and the
            // countdown drew through its own gutter towards the edge.
            let figure = showsPercentage ? markGap + Self.mono(headline, 12) : 0
            let left = leadingGutter + mark.width + figure + notchClearance
            let right = notchClearance + Self.mono(tail, 11.5)
                + (badge.map { $0.width + $0.gap } ?? 0)
                + trailingGutter
            return ceil(max(left, right))
        }

        /// What the wings hold in a given state, which is both what the view
        /// draws and what the shell is measured from. One function, so the two
        /// can never disagree about how much room a figure needs.
        static func of(
            state: PillState, snapshot: UsageSnapshot?, mark: Mark,
            badge: Badge?, showsPercentage: Bool = true
        ) -> Wings {
            let headline = switch state {
            case .ghost: Format.percent(snapshot?.weeklyPercent)
            default: Format.percent(snapshot?.sessionPercent)
            }
            let tail = switch state {
            case .ghost: Format.windowName(snapshot?.weeklyWindowMinutes)
            default: Format.countdown(to: snapshot?.resetsAt)
            }
            return Wings(
                mark: mark, headline: headline, showsPercentage: showsPercentage,
                tail: tail, badge: badge
            )
        }

        /// What the host reserves: the widest either wing can ever be, so the
        /// window never has to grow while the shell inside it does.
        @MainActor static let widest = Wings(
            mark: Mark.allCases.max { $0.width < $1.width } ?? .capsuleBar,
            // The widest badge, not merely a badge: a two-digit count of jobs is
            // wider than the alert triangle it shares the slot with. And the
            // widest countdown, which is no longer the weekly window's: a
            // workspace metered in credits resets monthly, an annual limit in
            // three digits of days. The shell still measures itself from what is
            // actually drawn — this is only what the host holds open for it.
            headline: "1.25M", tail: "364d 23h", badge: .working(99)
        ).flank
    }

    /// How far the figures stop short of the shell's own edge.
    ///
    /// The board drew 11 and 13, from a row whose content sat against the outer
    /// edge with the slack beside the notch. The wings lean the other way now —
    /// towards the hardware, with the slack outside — so this is what is left at
    /// the corner of the wider wing, and at 11 the mark was in the curve of it.
    /// Equal on both sides: the shell is symmetric, and two different gutters on
    /// a row that is now centred on the notch read as a mistake.
    static let leadingGutter: CGFloat = 15
    static let trailingGutter: CGFloat = 15
    static let markGap: CGFloat = 12
    /// How far the figures stop short of the hardware.
    ///
    /// The row's own spacing, reused: the notch is one more thing in the row, so
    /// what separates the mark from its percentage separates the percentage from
    /// the camera. Named separately all the same, because the two are free to
    /// disagree — this one is clearance from a piece of hardware, not spacing
    /// between two figures.
    static let notchClearance: CGFloat = 12
    static let badgeSize: CGFloat = 10

    /// The count badge, from the board: a 16.5pt circle whose corner radius is
    /// its own half, so one digit is a circle and nothing has to switch shape.
    static let badgeDiameter: CGFloat = 16.5
    /// What a second digit adds — 23.4pt for two, which is 1.42 × the circle.
    static let badgeDigitWidth: CGFloat = 6.9
    static let badgeCorner: CGFloat = 8.25
    /// Tight to the countdown: the count qualifies the figure it sits beside,
    /// rather than standing as its own item in the row.
    static let badgeGap: CGFloat = 4
    /// The panels redraw it with their header type. The board scales the layer
    /// rather than re-typesetting, so these are multipliers, not sizes.
    static let badgeHoverScale: CGFloat = 1.25
    static let badgePinnedScale: CGFloat = 1.15

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
    /// Hidden is the exception and keeps the board's hairline: "no activity"
    /// means the notch reads as stock hardware, and a black bar beside the
    /// camera is the one thing that would give it away.
    ///
    /// A notchless screen has a band too — the menu bar row — and it is the one
    /// that matters there: the board's 36pt collapsed pill hung below the row on
    /// an external display, its bottom edge lining up with nothing.
    @MainActor func size(around band: NotchBand, wings: Wings = Wings()) -> CGSize {
        guard !band.isEmpty, self != .hidden else { return size }
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
        case .hidden: 6
        case .ghost, .collapsed, .exhausted: 13
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
    @MainActor static func hostSize(around band: NotchBand) -> CGSize {
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
    static let menuDrop = menuGap + menuHeight(items: 4)

    /// The context menu's own geometry, from the same design board.
    static let menuGap: CGFloat = 6
    static let menuWidth: CGFloat = 212
    static let menuRowHeight: CGFloat = 25
    static let menuPadding: CGFloat = 5

    static func menuHeight(items: Int) -> CGFloat {
        CGFloat(items) * menuRowHeight + menuPadding * 2
    }
}
