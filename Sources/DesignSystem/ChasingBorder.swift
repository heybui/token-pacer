import SwiftUI

/// A highlight that runs the shell's outline while tokens are flowing.
///
/// The same signal as the activity dot, on the same 2.6s cycle, so the two beat
/// together rather than against each other — one is legible from across the room,
/// the other from arm's length.
struct ChasingBorder<S: InsettableShape>: View {
    let shape: S
    var tone: Color
    var isRunning: Bool
    var lineWidth: CGFloat = 1.5
    /// Fraction of the outline lit at once. Long enough to read as motion on a
    /// 226pt pill, short enough not to become a plain border on a 404pt card.
    var length: Double = 0.2
    /// `PulsingDot`'s full cycle.
    var duration: Double = 2.6

    /// The tail is drawn as this many arcs of falling opacity and width.
    ///
    /// A gradient *stroke* cannot do it: `LinearGradient` fades by position in the
    /// view, so the head vanished down the left and right edges and the light
    /// appeared to run along the top and bottom only. Opacity has to follow the
    /// path, and the path is the only thing that knows where it goes.
    private let segments = 18

    var body: some View {
        // Driven by the clock, not by animating a `phase` of state. `trim` takes
        // the *wrapped* position, and 0 and 1 wrap to the same place — so
        // animating phase 0→1 interpolated every arc from where it was to where
        // it already was, and the light sat still.
        TimelineView(.animation(paused: !isRunning)) { timeline in
            let phase = timeline.date.timeIntervalSinceReferenceDate
                .truncatingRemainder(dividingBy: duration) / duration
            ZStack {
                ForEach(0..<segments, id: \.self) { index in
                    // 0 at the end of the tail, 1 at the head.
                    let t = Double(index) / Double(segments - 1)
                    let step = length / Double(segments)
                    let start = phase - length * (1 - t)
                    arc(
                        // Overlapped: exact joins leave hairline gaps that strobe
                        // as the arc moves.
                        from: start, to: start + step * 1.8,
                        // Squared rather than linear, so the tail dissolves into
                        // the ring instead of ending on a visible step.
                        opacity: t * t,
                        width: lineWidth * (0.5 + 0.5 * t)
                    )
                }
            }
        }
        .shadow(color: tone.opacity(0.45), radius: 3)
        .opacity(isRunning ? 1 : 0)
        .animation(.easeOut(duration: 0.3), value: isRunning)
    }

    /// `trim` does not wrap, so an arc crossing the start of the path is drawn as
    /// two — otherwise it bites off at the same corner every cycle.
    @ViewBuilder
    private func arc(from start: Double, to end: Double, opacity: Double, width: CGFloat) -> some View {
        let from = Self.wrapped(start)
        let to = Self.wrapped(end)

        if to > from {
            stroke(from: from, to: to, opacity: opacity, width: width)
        } else {
            stroke(from: from, to: 1, opacity: opacity, width: width)
            stroke(from: 0, to: to, opacity: opacity, width: width)
        }
    }

    /// The tail runs behind the head, so its position goes negative; a plain
    /// remainder keeps the sign and `trim` would silently draw nothing.
    static func wrapped(_ position: Double) -> Double {
        let remainder = position.truncatingRemainder(dividingBy: 1)
        return remainder < 0 ? remainder + 1 : remainder
    }

    private func stroke(from: Double, to: Double, opacity: Double, width: CGFloat) -> some View {
        shape
            .inset(by: lineWidth / 2)
            .trim(from: from, to: to)
            .stroke(
                tone.opacity(opacity),
                style: StrokeStyle(lineWidth: width, lineCap: .round)
            )
    }
}
