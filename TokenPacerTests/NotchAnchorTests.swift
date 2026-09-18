import Foundation
import CoreGraphics
import Testing
@testable import TokenPacer

// 14-inch MacBook Pro: 1512x982 points, 32pt notch/menu-bar band.
private let builtIn = ScreenMetrics(
    frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
    safeAreaTop: 32,
    auxiliaryTopLeft: CGRect(x: 0, y: 950, width: 655, height: 32),
    auxiliaryTopRight: CGRect(x: 857, y: 950, width: 655, height: 32),
    menuBarHeight: 33,
    isBuiltIn: true
)

// External display to the right of the built-in: no notch, negative-origin
// frame, and a 24pt menu bar row of its own.
private let external = ScreenMetrics(
    frame: CGRect(x: 1512, y: -98, width: 2560, height: 1440),
    safeAreaTop: 0,
    auxiliaryTopLeft: nil,
    auxiliaryTopRight: nil,
    menuBarHeight: 24
)

@MainActor @Test func notchWidthFromAuxiliaryAreas() {
    #expect(NotchAnchor.notchWidth(builtIn) == 202)
}

@MainActor @Test func noNotchOnExternalDisplay() {
    #expect(NotchAnchor.notchWidth(external) == nil)
}

/// An external display reports a top safe area for its menu bar and fills in
/// both auxiliary areas with it — notch-shaped, on hardware that has none. Left
/// unchecked the shell sized its flanks around a phantom and came out far wider
/// than the board ever drew.
@MainActor @Test func noNotchOnADisplayThatOnlyLooksLikeOne() {
    var phantom = builtIn
    phantom.isBuiltIn = false
    #expect(NotchAnchor.notchWidth(phantom) == nil)
    #expect(NotchAnchor.band(phantom).notchWidth == 0)
    #expect(PillState.collapsed.size(around: NotchAnchor.band(phantom)).width
            == PillState.collapsed.size.width)
}

@MainActor @Test func noNotchWhenSafeAreaIsZero() {
    var faked = builtIn
    faked.safeAreaTop = 0
    #expect(NotchAnchor.notchWidth(faked) == nil)
}

@MainActor @Test func hostIsTopCentredFlushWithScreenTop() {
    let frame = NotchAnchor.hostFrame(for: builtIn, size: PillState.hostSize)
    #expect(frame.midX == builtIn.frame.midX)
    #expect(frame.maxY == builtIn.frame.maxY)
}

/// The shell wraps the hardware: up behind it, past it on both sides, and down
/// to the end of the menu bar row. The figures go in the strips that leaves,
/// which is the whole point — grow the shell without moving the content and the
/// ring sits behind the camera.
@MainActor @Test func theShellSpansTheBandAndLeavesFlanksToFill() {
    let band = NotchAnchor.band(builtIn)
    #expect(band.notchWidth == 202)
    // The row, not the notch: they differ by a point, and a shell cut to the
    // notch ends its bottom edge on the chin.
    #expect(band.height == builtIn.menuBarHeight)
    #expect(band.height > builtIn.safeAreaTop)

    for state in PillState.allCases where state != .hidden {
        let drawn = state.size(around: band)
        #expect(drawn.width >= band.notchWidth + 2 * PillState.Wings().flank)
        #expect(drawn.height
                == band.height
                + (state.fillsFlanks ? 0 : state.size.height - PillState.reclaimedTop))
        // The light runs the bottom edge, so that edge is never on the chin.
        #expect(drawn.height > builtIn.safeAreaTop)
    }
    // Hovering grows the shell downward and nothing else: one object, one width.
    let widths = Set(PillState.allCases.filter { $0 != .hidden && $0 != .pinned }
        .map { $0.size(around: band).width })
    #expect(widths.count == 1)
    #expect(PillState.pinned.size(around: band).width == PillState.pinned.size.width)

    #expect(PillState.hostSize(around: band).height - PillState.hostSize.height == band.height)
    #expect(PillState.hostSize(around: band).width >= band.notchWidth + 2 * PillState.Wings().flank)
}

/// A menu bar set to hide automatically measures zero. The hardware is still
/// there, so the safe area is the floor the band never drops below.
@MainActor @Test func aHiddenMenuBarFallsBackToTheNotch() {
    var hidden = builtIn
    hidden.menuBarHeight = 0
    #expect(NotchAnchor.band(hidden).height == builtIn.safeAreaTop)
}

/// "No activity" means the notch reads as stock hardware. A black bar beside the
/// camera is the one thing that would give it away, so hidden keeps the board's
/// hairline and stays behind the hardware.
@MainActor @Test func hiddenNeverSpansTheNotch() {
    #expect(PillState.hidden.size(around: NotchAnchor.band(builtIn)) == PillState.hidden.size)
}

/// An external display has no hardware to reach around, but it has a menu bar
/// row and the shell still has to end at the bottom of it. The board's 36pt
/// collapsed pill hung a finger's width below the row on every external screen.
@MainActor @Test func theShellMeetsTheMenuBarWithoutANotch() {
    let band = NotchAnchor.band(external)
    #expect(band.notchWidth == 0)
    #expect(band.height == external.menuBarHeight)

    for state in PillState.allCases where state != .hidden {
        // No notch, no flanks to measure: the width is the one the board drew.
        #expect(state.size(around: band).width == state.size.width)
    }
    // The states that live in the row are exactly the row tall — no more.
    for state in PillState.allCases where state.fillsFlanks {
        #expect(state.size(around: band).height == external.menuBarHeight)
    }
}

/// Nothing reported at all — no safe area, no row — and there is nothing to
/// measure against, so the board stands.
@MainActor @Test func theShellIsUnchangedWithoutABand() {
    var blank = external
    blank.menuBarHeight = 0
    #expect(NotchAnchor.band(blank).isEmpty)
    for state in PillState.allCases {
        #expect(state.size(around: NotchBand()) == state.size)
    }
}

/// The regression that matters on multi-monitor: a screen whose origin is not (0,0).
@MainActor @Test func hostFollowsScreenOrigin() {
    let frame = NotchAnchor.hostFrame(for: external, size: PillState.hostSize)
    #expect(frame.midX == 2792)
    #expect(frame.maxY == 1342)
}

@MainActor @Test func shellOnlyEverGrowsDownward() {
    for state in PillState.allCases {
        let frame = NotchAnchor.hostFrame(for: builtIn, size: PillState.hostSize)
        #expect(state.size.height <= PillState.hostSize.height)
        #expect(state.size.width <= PillState.hostSize.width)
        #expect(frame.maxY == builtIn.frame.maxY)
    }
}

/// The hosting view clips to its bounds, so a host that only just contains the
/// pinned panel cuts its shadow off in a hard rectangle.
@MainActor @Test func theHostClearsTheLargestShellByTheWholeShadow() {
    let panel = PillState.pinned.size
    let reach = PillState.shadowRadius * 2

    #expect(PillState.hostSize.width - panel.width >= reach * 2)
    #expect(PillState.hostSize.height - panel.height >= reach + PillState.shadowOffsetY)
}

/// The menu opens under the pinned panel too, and a host that does not reserve
/// its drop clips it — silently, because the rows simply are not drawn.
@MainActor @Test func theHostReservesRoomForEveryMenuItem() {
    let items = PillRootView(
        model: PillModel(),
        store: UsageStore(archive: nil),
        preferences: Preferences(store: UserDefaults(suiteName: #function) ?? .standard)
    ).menuItems
    let needed = PillState.pinned.size.height
        + PillState.menuGap + PillState.menuHeight(items: items.count)

    #expect(PillState.hostSize.height >= needed)
    #expect(PillState.hostSize.width >= PillState.menuWidth)
}

/// With an external display attached, the pill belongs in the notch — that is
/// the product. `NSScreen.main` is the screen holding the key window, which for
/// an app with no windows is wherever the user last clicked.
@MainActor @Test func theNotchedScreenWinsOverTheFocusedOne() {
    let external = ScreenMetrics(
        frame: CGRect(x: 0, y: 0, width: 2560, height: 1440), safeAreaTop: 0,
        auxiliaryTopLeft: nil, auxiliaryTopRight: nil
    )
    let laptop = ScreenMetrics(
        frame: CGRect(x: 0, y: -1000, width: 1512, height: 982), safeAreaTop: 37,
        auxiliaryTopLeft: CGRect(x: 0, y: 0, width: 640, height: 37),
        auxiliaryTopRight: CGRect(x: 872, y: 0, width: 640, height: 37),
        isBuiltIn: true
    )

    #expect(NotchAnchor.preferred(from: [external, laptop], main: external) == laptop)
    // Lid closed: no notch anywhere, so the focused screen is the right answer.
    #expect(NotchAnchor.preferred(from: [external], main: external) == external)
    #expect(NotchAnchor.preferred(from: [], main: nil) == nil)
}
