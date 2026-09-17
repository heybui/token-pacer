import SwiftUI

/// A highlight that runs the shell's outline while tokens are flowing.
///
/// Measured in points, not in fractions of the path. The shell morphs from a
/// 226×36 pill to a 404×98 card — more than double the outline — so a tail of
/// "18% of the path" was half the pill and the length of a finger on the card,
/// and it crawled on one and raced on the other. A fixed length at a fixed speed
/// looks like the same light on every state.
struct ChasingBorder<S: InsettableShape>: View {
    let shape: S
    var tone: Color
    var isRunning: Bool
    var lineWidth: CGFloat = 1.5
    /// Length of the lit arc, in points.
    var tail: Double = 104
    /// Points per second. 2.6s round the collapsed pill — `PulsingDot`'s cycle,
    /// which is where the pairing was set.
    var speed: Double = 200

    /// The tail is drawn as this many arcs of falling opacity and width.
    ///
    /// A gradient *stroke* cannot do it: `LinearGradient` fades by position in the
    /// view, so the head vanished down the left and right edges and the light
    /// appeared to run along the top and bottom only. Opacity has to follow the
    /// path, and the path is the only thing that knows where it goes.
    private let segments = 24

    var body: some View {
        GeometryReader { geometry in
            // Straight-edge estimate: a couple of percent long on a rounded
            // shape, which is a speed knob, not geometry.
            let perimeter = max(1, 2 * (geometry.size.width + geometry.size.height))
            let length = min(0.5, tail / perimeter)
            let duration = perimeter / speed

            // Driven by the clock, not by animating a `phase` of state. `trim`
            // takes the *wrapped* position, and 0 and 1 wrap to the same place —
            // so animating phase 0→1 interpolated every arc from where it was to
            // where it already was, and the light sat still.
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
                            // Overlapped: exact joins leave hairline gaps that
                            // strobe as the arc moves.
                            from: start, to: start + step * 1.8,
                            // Cubed, not linear: the tail has to dissolve into the
                            // ring rather than end on a step, and the eye finds a
                            // linear ramp's shoulder every time.
                            opacity: t * t * t,
                            width: lineWidth * (0.35 + 0.65 * t)
                        )
                    }
                    // The head alone, blurred. Gives the light a source instead of
                    // a leading edge — a shadow under the whole tail just smears it.
                    arc(from: phase - length / Double(segments), to: phase,
                        opacity: 0.9, width: lineWidth)
                        .blur(radius: 2.5)
                }
            }
        }
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
