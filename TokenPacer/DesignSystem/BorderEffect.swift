import SwiftUI

/// Which light runs the shell's outline while tokens are flowing.
///
/// Twelve, as the board draws them, and judged the same way as the marks: at real
/// size, moving, against each other. They differ in what they say — a head that
/// drags a tail says direction, a dash train says process, a brightening hairline
/// says only "on" — and in how much of your eyeline they take while you work.
///
/// The figures below are the board's own rendering spec, not an approximation of
/// its previews: angles are absolute, clockwise from twelve o'clock, alphas are
/// straight from the source, and the durations are one full turn.
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

    /// How the light is painted, in the three kinds the spec names.
    var paint: BorderPaint {
        switch self {
        case .comet:
            .angular([ConicRamp(
                stops: [
                    .init(0, .clear), .init(266.4, .clear),
                    .init(324, .zone, 0.33), .init(360, .head, 1),
                ],
                duration: 2.4
            )])

        case .dualComet:
            .angular([ConicRamp(
                stops: [
                    .init(0, .clear), .init(129.6, .clear),
                    .init(169.2, .zone, 0.33), .init(180, .head, 1),
                    .init(190.8, .clear), .init(309.6, .clear),
                    .init(349.2, .zone, 0.33), .init(360, .head, 1),
                ],
                duration: 3
            )])

        case .zoneSweep:
            .angular([ConicRamp(
                stops: [
                    .init(0, .safe, 1), .init(120, .watch, 1),
                    .init(240, .over, 1), .init(360, .safe, 1),
                ],
                duration: 5
            )])

        case .marchingDashes:
            // Snapped to 24 dashes — 15° period, 5.36° lit. The board's own
            // 15.12° leaves 23.8 dashes in a lap, and the seam rotates past.
            .angular([ConicRamp(stops: Self.dashes(count: 24, lit: 5.36), duration: 9)])

        case .pulseWave:
            .angular([ConicRamp(
                stops: [
                    .init(0, .clear), .init(172.8, .clear),
                    .init(252, .zone, 0.15), .init(309.6, .zone, 0.80),
                    .init(345.6, .zone, 0.15), .init(360, .clear),
                ],
                duration: 3.4
            )])

        case .quarterTrace:
            // A hard cut, no ramp: two stops at the same angle.
            .angular([ConicRamp(
                stops: [
                    .init(0, .zone, 0.9), .init(93.6, .zone, 0.9),
                    .init(93.6, .clear), .init(360, .clear),
                ],
                duration: 1.9
            )])

        case .counterPair:
            .angular([
                ConicRamp(
                    stops: [
                        .init(0, .clear), .init(302.4, .clear),
                        .init(345.6, .zone, 0.30), .init(360, .head, 1),
                    ],
                    duration: 2.8
                ),
                ConicRamp(
                    stops: [
                        .init(0, .clear), .init(302.4, .clear),
                        .init(345.6, .zone, 0.20), .init(360, .zone, 1),
                    ],
                    duration: 3.6, reversed: true
                ),
            ])

        case .breathe:
            .solid(SolidLight(tint: .zone, alpha: 1, pulse: 0.22...1, duration: 1.8))

        case .breatheGlow:
            // The one variant that paints outside the mask: a static hairline
            // under a shadow cast onto the desktop.
            .solid(SolidLight(tint: .zone, alpha: 0.30, glow: true, duration: 2))

        case .edgeRunners:
            .bands([
                EdgeBand(edge: .right, tint: .zone, duration: 2.2, begin: 0),
                EdgeBand(edge: .bottom, tint: .head, duration: 2.2, begin: 0.73),
                EdgeBand(edge: .left, tint: .zone, duration: 2.2, begin: 1.46),
            ])

        case .sideDrip:
            .bands([
                EdgeBand(edge: .left, tint: .zone, duration: 2.6, begin: 0),
                EdgeBand(edge: .right, tint: .zone, duration: 2.6, begin: 1.3),
            ])

        case .bottomSweep:
            .bands([EdgeBand(edge: .bottom, tint: .head, duration: 2.4, begin: 0)])
        }
    }

    /// A dash train as a stop table: lit, then a hard cut to clear, repeated.
    private static func dashes(count: Int, lit: Double) -> [ConicStop] {
        let period = 360 / Double(count)
        return (0..<count).flatMap { index -> [ConicStop] in
            let start = Double(index) * period
            return [
                .init(start, .zone, 0.80), .init(start + lit, .zone, 0.80),
                .init(start + lit, .clear), .init(start + period, .clear),
            ]
        }
    }
}

/// How a light is painted. The board's spec names three kinds and the port keeps
/// them apart, because they are three different pieces of Core Animation: a
/// rotating ramp, a travelling band, and something that does not move at all.
enum BorderPaint: Equatable {
    case angular([ConicRamp])
    case bands([EdgeBand])
    case solid(SolidLight)
}

/// Which colour a stop takes. Resolved per reading rather than stored, and never
/// animated between zones — the swap happens on the boundary crossing.
enum BorderTint: Equatable {
    /// The zone the panel is in, and its lightened head colour.
    case zone, head
    /// A named zone, for the one variant that carries the whole palette.
    case safe, watch, over
    case clear
}

/// One stop in a conic ramp: an absolute angle, clockwise from twelve o'clock.
struct ConicStop: Equatable {
    var angle: Double
    var tint: BorderTint
    var alpha: Double

    init(_ angle: Double, _ tint: BorderTint, _ alpha: Double = 0) {
        self.angle = angle
        self.tint = tint
        self.alpha = tint == .clear ? 0 : alpha
    }
}

/// A ramp painted once into an image and then turned.
///
/// The turn is the whole point: CSS spins a conic gradient at constant *angular*
/// speed, so on a shallow wide panel the head sprints across the ends and crawls
/// along the long edges. Animating `strokeStart`/`strokeEnd` instead moves at
/// constant *path* speed — visibly calmer, and not what the board drew.
struct ConicRamp: Equatable {
    var stops: [ConicStop]
    /// One full turn, in seconds.
    var duration: Double
    var reversed = false
}

/// A gradient band travelling one edge, top to bottom or left to right.
struct EdgeBand: Equatable {
    enum Edge: Equatable { case left, right, bottom }

    var edge: Edge
    var tint: BorderTint
    var duration: Double
    /// Where it starts in the shared timeline, so three of them hand off at the
    /// corners rather than running as one.
    var begin: Double

    /// The spec's proportions: a vertical band is 52% of the height, a horizontal
    /// one 46% of the width.
    var lengthFraction: Double { edge == .bottom ? 0.46 : 0.52 }
}

/// A light that does not travel.
struct SolidLight: Equatable {
    var tint: BorderTint
    var alpha: Double
    /// The hairline brightening in place.
    var pulse: ClosedRange<Double>?
    /// The shadow cast outside the mask.
    var glow = false
    var duration: Double
}
