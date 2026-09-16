import CoreGraphics
import Testing
@testable import BurnTracker

// 14-inch MacBook Pro: 1512x982 points, 32pt notch/menu-bar band.
private let builtIn = ScreenMetrics(
    frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
    safeAreaTop: 32,
    auxiliaryTopLeft: CGRect(x: 0, y: 950, width: 655, height: 32),
    auxiliaryTopRight: CGRect(x: 857, y: 950, width: 655, height: 32)
)

// External display to the right of the built-in: no notch, negative-origin frame.
private let external = ScreenMetrics(
    frame: CGRect(x: 1512, y: -98, width: 2560, height: 1440),
    safeAreaTop: 0,
    auxiliaryTopLeft: nil,
    auxiliaryTopRight: nil
)

@Test func notchWidthFromAuxiliaryAreas() {
    #expect(NotchAnchor.notchWidth(builtIn) == 202)
}

@Test func noNotchOnExternalDisplay() {
    #expect(NotchAnchor.notchWidth(external) == nil)
}

@Test func noNotchWhenSafeAreaIsZero() {
    var faked = builtIn
    faked.safeAreaTop = 0
    #expect(NotchAnchor.notchWidth(faked) == nil)
}

@Test func hostIsTopCentredFlushWithScreenTop() {
    let frame = NotchAnchor.hostFrame(for: builtIn, size: PillState.hostSize)
    #expect(frame.midX == builtIn.frame.midX)
    #expect(frame.maxY == builtIn.frame.maxY)
}

/// The regression that matters on multi-monitor: a screen whose origin is not (0,0).
@Test func hostFollowsScreenOrigin() {
    let frame = NotchAnchor.hostFrame(for: external, size: PillState.hostSize)
    #expect(frame.midX == 2792)
    #expect(frame.maxY == 1342)
}

@Test func shellOnlyEverGrowsDownward() {
    for state in PillState.allCases {
        let frame = NotchAnchor.hostFrame(for: builtIn, size: PillState.hostSize)
        #expect(state.size.height <= PillState.hostSize.height)
        #expect(state.size.width <= PillState.hostSize.width)
        #expect(frame.maxY == builtIn.frame.maxY)
    }
}

/// The hosting view clips to its bounds, so a host that only just contains the
/// pinned panel cuts its shadow off in a hard rectangle.
@Test func theHostClearsTheLargestShellByTheWholeShadow() {
    let panel = PillState.pinned.size
    let reach = PillState.shadowRadius * 2

    #expect(PillState.hostSize.width - panel.width >= reach * 2)
    #expect(PillState.hostSize.height - panel.height >= reach + PillState.shadowOffsetY)
}

/// The menu opens under the pinned panel too, and a host that does not reserve
/// its drop clips it — silently, because the rows simply are not drawn.
@MainActor
@Test func theHostReservesRoomForEveryMenuItem() {
    let items = PillRootView(model: PillModel(), store: UsageStore()).menuItems
    let needed = PillState.pinned.size.height
        + PillState.menuGap + PillState.menuHeight(items: items.count)

    #expect(PillState.hostSize.height >= needed)
    #expect(PillState.hostSize.width >= PillState.menuWidth)
}
