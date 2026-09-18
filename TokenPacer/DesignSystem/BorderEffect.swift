import SwiftUI

/// Which light runs the shell's outline while tokens are flowing.
///
/// Twelve, as the board draws them, and judged the same way as the marks: at real
/// size, moving, against each other. They differ in what they say — a head that
/// drags a tail says direction, a dash train says process, a brightening hairline
/// says only "on" — and in how much of your eyeline they take while you are
/// working under them.
///
/// The order is the board's own, which is the order the Appearance grid draws.
enum BorderEffect: String, CaseIterable, Sendable {
    case comet
    case dualComet
    case zoneSweep
    case marchingDashes
    case pulseWave
    case quarterTrace
    case counterPair
    case breathe
    case breatheGlow
    case edgeRunners
    case sideDrip
    case bottomSweep

    var displayName: String {
        switch self {
        case .comet: "Comet"
        case .dualComet: "Dual comet"
        case .zoneSweep: "Zone sweep"
        case .marchingDashes: "Marching dashes"
        case .pulseWave: "Pulse wave"
        case .quarterTrace: "Quarter trace"
        case .counterPair: "Counter pair"
        case .breathe: "Breathe"
        case .breatheGlow: "Breathe glow"
        case .edgeRunners: "Edge runners"
        case .sideDrip: "Side drip"
        case .bottomSweep: "Bottom sweep"
        }
    }

    /// The board's own one-line verdict, which is what the pane shows under the
    /// selected tile.
    var axis: String {
        switch self {
        case .comet: "one head, fading tail"
        case .dualComet: "two heads, opposed"
        case .zoneSweep: "whole palette rotating"
        case .marchingDashes: "dash train"
        case .pulseWave: "soft band, no head"
        case .quarterTrace: "long arc"
        case .counterPair: "two heads crossing"
        case .breathe: "edge brightness, in place"
        case .breatheGlow: "cast glow, outside the edge"
        case .edgeRunners: "three edges, staggered"
        case .sideDrip: "verticals only"
        case .bottomSweep: "one edge"
        }
    }

    /// What the light is made of, in the one vocabulary every effect is built
    /// from. Lengths are fractions of the track and speeds are points per second,
    /// so an effect means the same thing on a 226pt pill and a 752pt panel — the
    /// lesson the comet was rewritten for once already.
    func pieces(tone: Color, light: Color, zones: (Color, Color, Color), lineWidth: CGFloat)
        -> [BorderPiece]
    {
        switch self {
        case .comet:
            // 26% of the outline lit, one lap every 2.4s on the collapsed shell.
            Self.comet(tone: tone, head: light, lineWidth: lineWidth, speed: 192, length: 0.26)
        case .dualComet:
            Self.comet(tone: tone, head: light, lineWidth: lineWidth, speed: 154, length: 0.14)
                + Self.comet(
                    tone: tone, head: light, lineWidth: lineWidth,
                    speed: 154, length: 0.14, phase: 0.5
                )
        case .counterPair:
            Self.comet(tone: tone, head: light, lineWidth: lineWidth, speed: 165, length: 0.16)
                + Self.comet(
                    tone: tone, head: tone, lineWidth: lineWidth,
                    speed: 128, length: 0.16, reversed: true
                )
        case .pulseWave:
            // No head at all: the swell fades in from nothing and back out, which
            // is why it reads as calm and why its direction barely reads.
            Self.band(
                color: tone, lineWidth: lineWidth, length: 0.52,
                speed: 136, peak: 0.85, segments: 16
            )
        case .quarterTrace:
            // A quarter of the perimeter, lit flat, going fast.
            [BorderPiece(color: tone, opacity: 0.9, width: lineWidth, length: 0.26, speed: 243)]
        case .zoneSweep:
            Self.palette(zones, lineWidth: lineWidth, speed: 92)
        case .marchingDashes:
            [BorderPiece(
                motion: .dash, color: tone, opacity: 0.8, width: lineWidth,
                speed: 26, dash: [3, 9]
            )]
        case .breathe:
            [BorderPiece(motion: .pulse, color: tone, opacity: 1, width: lineWidth, period: 1.8)]
        case .breatheGlow:
            // A halo rather than a hairline. Two strokes, not a blur: a blur is an
            // offscreen pass every frame for a glow on a 1.5pt line, which is what
            // the comet's own head used to cost.
            [
                BorderPiece(
                    motion: .pulse, color: tone, opacity: 0.22,
                    width: lineWidth * 7, period: 2
                ),
                BorderPiece(
                    motion: .pulse, color: tone, opacity: 0.5,
                    width: lineWidth * 3, period: 2
                ),
            ]
        case .edgeRunners:
            // Timed, not paced: each edge gets its own runner and they hand off
            // at the corners, which only works if the 36pt sides and the 390pt
            // bottom take the same 2.2s to cross.
            Self.band(color: tone, lineWidth: lineWidth, length: 0.46, pass: 2.2, on: .left)
                + Self.band(
                    color: light, lineWidth: lineWidth, length: 0.46,
                    pass: 2.2, phase: 0.33, on: .bottom
                )
                + Self.band(
                    color: tone, lineWidth: lineWidth, length: 0.46,
                    pass: 2.2, phase: 0.66, on: .right
                )
        case .sideDrip:
            Self.band(color: tone, lineWidth: lineWidth, length: 0.52, pass: 2.6, on: .left)
                + Self.band(
                    color: tone, lineWidth: lineWidth, length: 0.52,
                    pass: 2.6, phase: 0.5, reversed: true, on: .right
                )
        case .bottomSweep:
            Self.band(color: light, lineWidth: lineWidth, length: 0.46, pass: 2.4, on: .bottom)
        }
    }

    /// The default reading of "working": one bright head dragging a tail.
    ///
    /// The tail is drawn as arcs of falling opacity and width. A gradient *stroke*
    /// cannot do it — a gradient fades by position in the view, so the head
    /// vanished down the left and right edges and the light appeared to run along
    /// the top and bottom only. Opacity has to follow the path, and the path is
    /// the only thing that knows where it goes.
    private static func comet(
        tone: Color, head: Color, lineWidth: CGFloat, speed: Double,
        length: Double = 0.2, phase: Double = 0, reversed: Bool = false, segments: Int = 20
    ) -> [BorderPiece] {
        let step = length / Double(segments)
        var pieces = (0..<segments).map { index -> BorderPiece in
            // Faint at the end of the tail, 1 at the head. Cubed, not linear: the
            // tail has to dissolve into the ring rather than end on a step, and
            // the eye finds a linear ramp's shoulder every time. It starts one
            // step above nothing — a layer at zero opacity is a layer that is
            // composited and never seen.
            let t = Double(index + 1) / Double(segments)
            return BorderPiece(
                // The board's own ramp: nothing at the end of the tail, a third
                // of the way up by two thirds along, full at the head. Cubed was
                // too steep — it left a bright bead with a wisp behind it where
                // the board draws a long lit smear.
                color: tone, opacity: CGFloat(pow(t, 1.6)),
                // One width the whole way. A tail that also thins reads as a
                // hair, not as a light that is passing.
                width: lineWidth,
                // Overlapped: exact joins leave hairline gaps that strobe as the
                // light moves.
                length: step * 1.8, trail: length * (1 - t),
                speed: speed, reversed: reversed, phase: phase
            )
        }
        // The halo under the head, then the head itself.
        pieces.append(BorderPiece(
            color: tone, opacity: 0.2, width: lineWidth * 3, length: step,
            speed: speed, reversed: reversed, phase: phase
        ))
        pieces.append(BorderPiece(
            color: head, opacity: 0.9, width: lineWidth, length: step,
            speed: speed, reversed: reversed, phase: phase
        ))
        return pieces
    }

    /// A soft band with no head: bright in the middle, gone at both ends.
    private static func band(
        color: Color, lineWidth: CGFloat, length: Double = 0.3, speed: Double = 0,
        pass: Double = 0, phase: Double = 0, reversed: Bool = false,
        peak: CGFloat = 0.95, segments: Int = 8,
        on segment: BorderPiece.Segment = .whole
    ) -> [BorderPiece] {
        let step = length / Double(segments)
        return (0..<segments).map { index in
            // A half-sine, so both ends dissolve and the middle carries the
            // light — sampled between the ends rather than on them, so no piece
            // is drawn at nothing.
            let t = (Double(index) + 0.5) / Double(segments)
            let ramp = CGFloat(sin(t * .pi))
            return BorderPiece(
                color: color, opacity: peak * ramp * ramp,
                width: lineWidth * (0.4 + 0.6 * ramp),
                length: step * 1.8, trail: length * (1 - t),
                speed: speed, period: pass, reversed: reversed,
                phase: phase, segment: segment
            )
        }
    }

    /// The safe/watch/over palette itself, rotating. Each zone is drawn twice, a
    /// lap apart: the track clips at both ends, so the second copy is what comes
    /// round rather than a gap opening behind the last colour.
    private static func palette(
        _ zones: (Color, Color, Color), lineWidth: CGFloat, speed: Double
    ) -> [BorderPiece] {
        let spans: [(Color, Double)] = [(zones.0, 0.5), (zones.1, 0.28), (zones.2, 0.22)]
        var trail = 0.0
        var pieces: [BorderPiece] = []
        for (color, length) in spans {
            // Behind the head by its own length as well as everything before it,
            // so the three zones are contiguous and together cover the track.
            trail += length
            // Twice, a lap apart: the track clips at both ends, so the second
            // copy is what comes round rather than a gap opening behind the last
            // colour.
            for lap in [0.0, -1.0] {
                pieces.append(BorderPiece(
                    color: color, opacity: 0.85, width: lineWidth,
                    length: length, trail: trail + lap, speed: speed
                ))
            }
        }
        return pieces
    }
}

/// One lit piece of the outline, in the vocabulary every effect is built from.
///
/// Fractions of the track rather than points, so the same description survives the
/// shell morphing from a 226×36 pill to a 752×540 panel.
struct BorderPiece: Equatable {
    enum Motion: Equatable {
        /// Travels along the track.
        case sweep
        /// Sits still and brightens.
        case pulse
        /// Sits still and creeps by one dash.
        case dash
    }

    /// Which part of the outline it is confined to. The track is traversed from
    /// the top-left, down and round the bottom, up to the top-right.
    enum Segment: Equatable { case whole, left, bottom, right }

    var motion: Motion = .sweep
    var color: Color
    var opacity: CGFloat = 1
    var width: CGFloat = 1.5
    /// Lit length, as a fraction of the track.
    var length: Double = 0.05
    /// How far behind the head this piece runs, as a fraction of the track.
    var trail: Double = 0
    /// Points per second along the track.
    var speed: Double = 200
    /// Seconds for one cycle, for the motions that do not travel.
    var period: Double = 1.8
    var reversed = false
    /// Where in its own lap it starts, 0...1.
    var phase: Double = 0
    var segment: Segment = .whole
    /// Dash pattern in points, for `.dash`.
    var dash: [CGFloat] = []
}
