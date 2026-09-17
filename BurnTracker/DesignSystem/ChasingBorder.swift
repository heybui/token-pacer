import SwiftUI

/// The shell's outline minus its top edge: an open path from the top-left corner,
/// down and round the bottom, up to the top-right.
///
/// Open, not closed. The top edge lies against the notch, and a light run along
/// it is a light run under the hardware — half of it eaten, the rest reading as a
/// seam. The bottom is always in open screen: every shell keeps either a body or
/// `PillState.overhang` below the notch, so this is one straight sweep and never
/// a climb around the hardware. Drawn in traversal order, so `trim` positions and
/// the eye agree: 0 is the left, 1 is the right.
struct ShellTrack: Shape {
    var cornerRadius: CGFloat
    var inset: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let left = rect.minX + inset
        let right = rect.maxX - inset
        let bottom = rect.maxY - inset
        let radius = min(cornerRadius, (right - left) / 2, bottom - rect.minY)

        var path = Path()
        path.move(to: CGPoint(x: left, y: rect.minY))
        // Tangent arcs, not quad curves: the static ring is a circular
        // `UnevenRoundedRectangle`, and the light has to sit on it, not near it.
        path.addArc(
            tangent1End: CGPoint(x: left, y: bottom),
            tangent2End: CGPoint(x: right, y: bottom), radius: radius
        )
        path.addArc(
            tangent1End: CGPoint(x: right, y: bottom),
            tangent2End: CGPoint(x: right, y: rect.minY), radius: radius
        )
        path.addLine(to: CGPoint(x: right, y: rect.minY))
        return path
    }
}

/// A highlight that runs the shell's outline while tokens are flowing.
///
/// Measured in points, not in fractions of the path. The shell morphs from a
/// 226×36 pill to a 404×98 card — more than double the outline — so a tail of
/// "18% of the path" was half the pill and the length of a finger on the card,
/// and it crawled on one and raced on the other. A fixed length at a fixed speed
/// looks like the same light on every state.
struct ChasingBorder: View {
    var cornerRadius: CGFloat
    var tone: Color
    var isRunning: Bool
    var lineWidth: CGFloat = 1.5
    /// Length of the lit arc, in points.
    var tail: Double = 104
    /// Points per second. 2.6s round the collapsed pill — the ring's breath,
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
            // Straight-edge estimate of the track: down, across, up. A couple of
            // percent long on a rounded shape, which is a speed knob, not geometry.
            // Straight-edge estimate of the track: down, across, up. A couple of
            // percent long on a rounded shape, which is a speed knob, not geometry.
            let track = max(1, geometry.size.width + 2 * geometry.size.height)
            let length = min(0.5, tail / track)
            // The head runs from the start to one tail past the end, so the light
            // drains off the right rather than being cut mid-glow and restarting.
            let sweep = 1 + length
            let duration = track * sweep / speed

            // Driven by the clock, not by animating a `phase` of state. An open
            // path has no wrap to fight, but the clock still beats a state
            // animation that has to be restarted every cycle.
            TimelineView(.animation(paused: !isRunning)) { timeline in
                let head = timeline.date.timeIntervalSinceReferenceDate
                    .truncatingRemainder(dividingBy: duration) / duration * sweep
                ZStack {
                    ForEach(0..<segments, id: \.self) { index in
                        // 0 at the end of the tail, 1 at the head.
                        let t = Double(index) / Double(segments - 1)
                        let step = length / Double(segments)
                        let start = head - length * (1 - t)
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
                    arc(from: head - length / Double(segments), to: head,
                        opacity: 0.9, width: lineWidth)
                        .blur(radius: 2.5)
                }
            }
        }
        .opacity(isRunning ? 1 : 0)
        .animation(.easeOut(duration: 0.3), value: isRunning)
    }

    /// Clipped at both ends, never wrapped: the track is open, so a tail hanging
    /// off the left belongs nowhere — least of all spliced onto the right, which
    /// is what the closed outline used to do.
    @ViewBuilder
    private func arc(from start: Double, to end: Double, opacity: Double, width: CGFloat) -> some View {
        let from = min(max(start, 0), 1)
        let to = min(max(end, 0), 1)
        if to > from {
            stroke(from: from, to: to, opacity: opacity, width: width)
        }
    }

    private func stroke(from: Double, to: Double, opacity: Double, width: CGFloat) -> some View {
        ShellTrack(cornerRadius: cornerRadius, inset: lineWidth / 2)
            .trim(from: from, to: to)
            .stroke(
                tone.opacity(opacity),
                style: StrokeStyle(lineWidth: width, lineCap: .round)
            )
    }
}
