import SwiftUI

/// The capsule bar folded into a circle: the same zone track, the same marker,
/// 18pt instead of 36.
///
/// The board draws it as the answer to the bar's appetite — "70px per wing
/// instead of 160, small enough that the left wing stops fighting app menus" —
/// and names the cost itself: an angle is harder to read precisely than a
/// position on a line. Which zone you are in is instant; how deep into it is not.
struct RingMark: View {
    let percent: Double?
    var weekPercent: Double?
    var size: CGFloat = 18
    var lineWidth: CGFloat = 2.5
    var isBurning = false

    @Environment(\.tone) private var tone

    /// A point of gap either side of each threshold, as on the bar.
    private static let gap: Double = 1

    var body: some View {
        ZStack {
            arc(from: 0, to: tone.warnAt - Self.gap, Tokens.green)
            arc(from: tone.warnAt + Self.gap, to: tone.critAt - Self.gap, Tokens.amber)
            arc(from: tone.critAt + Self.gap, to: 100, Tokens.red)
            if let weekPercent { dot(at: weekPercent, diameter: 3, moving: false) }
            if let percent { dot(at: percent, diameter: 4.5, moving: isBurning) }
        }
        .frame(width: size, height: size)
    }

    /// Trimmed strokes rather than an angular gradient: three arcs of flat colour
    /// are what the zones are, and a gradient would fade between them.
    private func arc(from start: Double, to end: Double, _ color: Color) -> some View {
        Circle()
            .trim(from: start / 100, to: end / 100)
            .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .butt))
            .rotationEffect(.degrees(-90))
            .padding(lineWidth / 2)
    }

    /// The reading, on the track it belongs to. Pulsing rather than creeping,
    /// because a dot on a circle has nowhere to creep to — and drawn by
    /// CoreAnimation for the reason `CreepingMarker` carries.
    private func dot(at percent: Double, diameter: CGFloat, moving: Bool) -> some View {
        let clamped = min(100, max(0, percent))
        let angle = Angle.degrees(clamped * 3.6 - 90)
        let radius = (size - lineWidth) / 2
        return CreepingMarker(
            color: tone.light(clamped),
            width: diameter, height: diameter,
            motion: .pulse,
            isRunning: moving
        )
        .frame(width: diameter, height: diameter)
        .background {
            // The shell's own black, so the dot reads against whichever arc it
            // lands on without a blur to separate them. A point and a half, not
            // two: on an 18pt ring the ring itself is only 2.5pt wide, and a
            // thicker collar eats the track the dot is supposed to be riding.
            Circle().fill(.black).frame(width: diameter + 1.5, height: diameter + 1.5)
        }
        .offset(x: radius * cos(angle.radians), y: radius * sin(angle.radians))
        .animation(.easeOut(duration: 0.6), value: percent)
    }
}
