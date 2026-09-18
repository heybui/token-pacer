import SwiftUI

/// The ten marks that are neither the capsule bar nor the ring.
///
/// Every one of them is drawn from the same two facts — a percentage and whether
/// a model is answering — and each encodes the first by a different mechanism:
/// level, count, angle, occlusion, depletion, transfer, height. They live in one
/// file because each is a dozen lines of geometry and nothing else; splitting
/// them into ten files would only make the set harder to compare, which is the
/// whole reason the board draws them together.
///
/// **Nothing here animates with SwiftUI.** The one moving part of each mark is a
/// `CreepingMarker` — a `CALayer` with one animation on the render server. The
/// static geometry redraws when a reading lands and at no other time.

// MARK: - Notch tank

/// The app's own silhouette as a fuel tank: the only mark that counts down.
struct NotchTankMark: View {
    let percent: Double?
    var isBurning = false
    @Environment(\.tone) private var tone
    @Environment(\.markEasing) private var markEasing

    private let side: CGFloat = 16
    private let radius: CGFloat = 3.6
    private var value: Double { clamp(percent) }
    /// What is left, which is what the tank shows.
    private var level: CGFloat { side * (100 - value) / 100 }

    var body: some View {
        HStack(spacing: 2) {
            tank
            gauge
        }
    }

    private var tank: some View {
        ZStack(alignment: .bottom) {
            Color.white.opacity(0.1)
            Rectangle().fill(tone(value)).frame(height: level)
            // The surface, bobbing while the tank is being drawn down.
            CreepingMarker(
                color: tone.light(value), width: side, height: 1.5,
                motion: .bob, cornerRadius: 0.75, isRunning: isBurning
            )
            .frame(width: side, height: 1.5)
            .offset(y: -level + 0.75)
            // The notch itself, bitten out of the top edge — the silhouette is
            // the point of this mark.
            VStack(spacing: 0) {
                Color.black
                    .frame(width: side * 0.55, height: side * 0.19)
                    .clipShape(.rect(bottomLeadingRadius: 2.2, bottomTrailingRadius: 2.2))
                Spacer(minLength: 0)
            }
        }
        .frame(width: side, height: side)
        .clipShape(.rect(cornerRadius: radius))
        .overlay {
            RoundedRectangle(cornerRadius: radius)
                .strokeBorder(.white.opacity(0.16), lineWidth: 1)
        }
        .animation(markEasing, value: value)
    }

    /// F and E, with the half mark between them. Three hairlines and no text:
    /// a letter at this size is a smudge.
    private var gauge: some View {
        VStack(spacing: 0) {
            tick(3.5, 0.45)
            Spacer(minLength: 0)
            tick(2, 0.24)
            Spacer(minLength: 0)
            tick(3.5, 0.45)
        }
        .frame(width: 4, height: side)
        .padding(.vertical, 1)
    }

    private func tick(_ width: CGFloat, _ opacity: Double) -> some View {
        Capsule().fill(.white.opacity(opacity)).frame(width: width, height: 1)
    }
}

// MARK: - Pips

/// Discrete and countable — you can say "six of eight" out loud.
struct PipsMark: View {
    let percent: Double?
    var isBurning = false
    @Environment(\.tone) private var tone

    private static let count = 8
    private var lit: Int { Int((clamp(percent) / 100 * Double(Self.count)).rounded()) }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<Self.count, id: \.self) { index in
                // Each pip is tinted by where it sits, not by the reading: the
                // row is the scale, the lit ones are the reading.
                let at = (Double(index) + 0.5) / Double(Self.count) * 100
                if index == lit {
                    // The next one to land, charging before it does.
                    CreepingMarker(
                        color: tone(at).opacity(isBurning ? 1 : 0.16),
                        width: 3, height: 11,
                        motion: .charge, cornerRadius: 1.5, isRunning: isBurning
                    )
                    .frame(width: 3, height: 11)
                } else {
                    Capsule()
                        .fill(index < lit ? tone(at) : .white.opacity(0.15))
                        .frame(width: 3, height: 11)
                }
            }
        }
    }
}

// MARK: - Half gauge

/// The zone track with a dial's authority, in half a ring's height.
struct HalfGaugeMark: View {
    let percent: Double?
    var isBurning = false
    @Environment(\.tone) private var tone
    @Environment(\.markEasing) private var markEasing

    private let diameter: CGFloat = 32
    private let lineWidth: CGFloat = 3
    private var value: Double { clamp(percent) }

    var body: some View {
        ZStack {
            arc(from: 0, to: tone.warnAt - 1, Tokens.green)
            arc(from: tone.warnAt + 1, to: tone.critAt - 1, Tokens.amber)
            arc(from: tone.critAt + 1, to: 100, Tokens.red)
            needle
        }
        .frame(width: diameter, height: diameter)
        .padding(.top, 2)
        // Half a ring: the box is 20 tall and the bottom of the circle is cut
        // away by it rather than masked, which is one fewer layer to composite.
        .frame(width: 36, height: 20, alignment: .top)
        .clipped()
    }

    /// The scale runs 9 o'clock to 3 o'clock over the top, so the trim starts a
    /// half-turn round: 100% of the reading is 50% of the circle.
    private func arc(from start: Double, to end: Double, _ color: Color) -> some View {
        Circle()
            .trim(from: start / 200, to: end / 200)
            .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .butt))
            .rotationEffect(.degrees(180))
            .padding(lineWidth / 2)
    }

    private var needle: some View {
        let angle = Angle.degrees(180 + value * 1.8)
        let radius = (diameter - lineWidth) / 2
        return CreepingMarker(
            color: tone.light(value), width: 5.5, height: 5.5,
            motion: .pulse, isRunning: isBurning
        )
        .frame(width: 5.5, height: 5.5)
        .background { Circle().fill(.black).frame(width: 8, height: 8) }
        .offset(x: radius * cos(angle.radians), y: radius * sin(angle.radians))
        .animation(markEasing, value: value)
    }
}

// MARK: - Eclipse

/// A shadow slides across the disc as you spend, leaving a thinning crescent.
struct EclipseMark: View {
    let percent: Double?
    var isBurning = false
    @Environment(\.tone) private var tone
    @Environment(\.markEasing) private var markEasing

    private let diameter: CGFloat = 17
    private var value: Double { clamp(percent) }

    var body: some View {
        ZStack {
            Circle().fill(tone(value))
            // The shell's own black, creeping the last two points of the way.
            CreepingMarker(
                color: .black, width: diameter, height: diameter,
                distance: 2, motion: .creep, isRunning: isBurning
            )
            .frame(width: diameter, height: diameter)
            .offset(x: -diameter + diameter * value / 100)
        }
        .frame(width: diameter, height: diameter)
        .clipShape(.circle)
        // The outline keeps the full extent visible, so the crescent has
        // something to be judged against.
        .overlay { Circle().strokeBorder(.white.opacity(0.22), lineWidth: 1) }
        .animation(markEasing, value: value)
    }
}

// MARK: - Token stack

/// Depletion rather than accumulation: spent tokens hollow out.
struct TokenStackMark: View {
    let percent: Double?
    var isBurning = false
    @Environment(\.tone) private var tone

    private static let count = 4
    private let width: CGFloat = 15
    private let height: CGFloat = 3
    private var spent: Int { Int((clamp(percent) / 100 * Double(Self.count)).rounded()) }

    var body: some View {
        VStack(spacing: 1.5) {
            ForEach(0..<Self.count, id: \.self) { index in
                if index == spent {
                    CreepingMarker(
                        color: tone(clamp(percent)).opacity(isBurning ? 1 : 0.5),
                        width: width, height: height,
                        motion: .charge, cornerRadius: height / 2, isRunning: isBurning
                    )
                    .frame(width: width, height: height)
                } else if index < spent {
                    Capsule()
                        .strokeBorder(.white.opacity(0.22), lineWidth: 1)
                        .frame(width: width, height: height)
                } else {
                    Capsule().fill(tone(clamp(percent))).frame(width: width, height: height)
                }
            }
        }
    }
}

// MARK: - Hourglass

/// Sand from the upper cone to the lower: time and consumption at once, which
/// is exactly what a rolling window is.
struct HourglassMark: View {
    let percent: Double?
    var isBurning = false
    @Environment(\.tone) private var tone
    @Environment(\.markEasing) private var markEasing

    private let width: CGFloat = 14
    private let chamber: CGFloat = 8
    private static let glass = Color.white.opacity(0.4)
    private var value: Double { clamp(percent) }

    var body: some View {
        VStack(spacing: 0) {
            cap
            cone(pointsDown: true) {
                sand(alignment: .top, fraction: (100 - value) / 100)
            }
            cone(pointsDown: false) {
                sand(alignment: .bottom, fraction: value / 100)
            }
            .overlay(alignment: .top) {
                // The grain in flight. The one motion in the set that does not
                // come back.
                CreepingMarker(
                    color: tone(value), width: 1.5, height: 1.5,
                    distance: chamber - 2, motion: .fall, isRunning: isBurning
                )
                .frame(width: 1.5, height: 1.5)
            }
            cap
        }
        .animation(markEasing, value: value)
    }

    private var cap: some View {
        Capsule().fill(Self.glass).frame(width: width, height: 1.5)
    }

    /// The glass, then the void inside it, then whatever sand is in the void —
    /// the padding is the wall's thickness.
    private func cone(pointsDown: Bool, @ViewBuilder fill: () -> some View) -> some View {
        Cone(pointsDown: pointsDown)
            .fill(Self.glass)
            .frame(width: width, height: chamber)
            .overlay {
                ZStack { Color.black; fill() }
                    .clipShape(Cone(pointsDown: pointsDown))
                    .padding(1.1)
            }
    }

    private func sand(alignment: Alignment, fraction: Double) -> some View {
        VStack(spacing: 0) {
            if alignment == .bottom { Spacer(minLength: 0) }
            Rectangle().fill(tone(value)).frame(height: chamber * fraction)
            if alignment == .top { Spacer(minLength: 0) }
        }
    }
}

/// Half an hourglass. Two of them, nose to nose.
private struct Cone: Shape {
    let pointsDown: Bool

    func path(in rect: CGRect) -> Path {
        var path = Path()
        if pointsDown {
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        } else {
            path.move(to: CGPoint(x: rect.midX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        }
        path.closeSubpath()
        return path
    }
}

// MARK: - Dotted arc

/// Discrete cousin of the ring wings: countable like pips, circular like a clock.
struct DottedArcMark: View {
    let percent: Double?
    var isBurning = false
    @Environment(\.tone) private var tone

    private static let count = 12
    private let size: CGFloat = 19
    private let dot: CGFloat = 3
    private var value: Double { clamp(percent) }
    private var lit: Int { Int((value / 100 * Double(Self.count)).rounded()) }

    var body: some View {
        ZStack {
            ForEach(0..<Self.count, id: \.self) { index in
                place(index) {
                    if index == lit {
                        CreepingMarker(
                            color: tone(value).opacity(isBurning ? 1 : 0.16),
                            width: dot, height: dot,
                            motion: .charge, isRunning: isBurning
                        )
                        .frame(width: dot, height: dot)
                    } else {
                        Circle()
                            .fill(index < lit ? tone(value) : .white.opacity(0.16))
                            .frame(width: dot, height: dot)
                    }
                }
            }
        }
        .frame(width: size, height: size)
    }

    private func place(_ index: Int, @ViewBuilder content: () -> some View) -> some View {
        let angle = Angle.degrees(Double(index) / Double(Self.count) * 360 - 90)
        let radius = (size - dot) / 2
        return content()
            .offset(x: radius * cos(angle.radians), y: radius * sin(angle.radians))
    }
}

// MARK: - Dot matrix

/// The squarest footprint in the set, for sitting next to square status icons.
struct DotMatrixMark: View {
    let percent: Double?
    var isBurning = false
    @Environment(\.tone) private var tone

    private let cell: CGFloat = 3.5
    private var lit: Int { Int((clamp(percent) / 100 * 9).rounded()) }

    var body: some View {
        VStack(spacing: 2) {
            ForEach(0..<3, id: \.self) { row in
                HStack(spacing: 2) {
                    ForEach(0..<3, id: \.self) { column in dot(row * 3 + column) }
                }
            }
        }
    }

    private func dot(_ index: Int) -> some View {
        let at = (Double(index) + 0.5) / 9 * 100
        return Group {
            if index == lit {
                CreepingMarker(
                    color: tone(at).opacity(isBurning ? 1 : 0.16),
                    width: cell, height: cell,
                    motion: .charge, cornerRadius: 1, isRunning: isBurning
                )
            } else {
                RoundedRectangle(cornerRadius: 1)
                    .fill(index < lit ? tone(at) : .white.opacity(0.15))
            }
        }
        .frame(width: cell, height: cell)
    }
}

// MARK: - Signal strength

/// Borrowed literacy: a full green signal degrading to one weak red bar.
struct SignalMark: View {
    let percent: Double?
    var isBurning = false
    @Environment(\.tone) private var tone

    private static let count = 6
    private var value: Double { clamp(percent) }
    /// Never zero: a signal with no bars at all reads as "no source", not as
    /// "nothing left".
    private var lit: Int {
        max(1, Int(((100 - value) / 100 * Double(Self.count)).rounded(.up)))
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<Self.count, id: \.self) { index in
                let height = 3.5 + Double(index) * 2
                if index == lit - 1 {
                    CreepingMarker(
                        color: tone(value), width: 2.5, height: height,
                        motion: .charge, cornerRadius: 1.25, isRunning: isBurning
                    )
                    .frame(width: 2.5, height: height)
                } else {
                    Capsule()
                        .fill(index < lit ? tone(value) : .white.opacity(0.14))
                        .frame(width: 2.5, height: height)
                }
            }
        }
        .frame(height: 14, alignment: .bottom)
    }
}

// MARK: - Thermometer

/// Height reads differently from every other horizontal thing in the menu bar.
struct ThermometerMark: View {
    let percent: Double?
    var isBurning = false
    @Environment(\.tone) private var tone
    @Environment(\.markEasing) private var markEasing

    private let tube = CGSize(width: 6, height: 13)
    private var value: Double { clamp(percent) }
    private var column: CGFloat { tube.height * value / 100 }

    var body: some View {
        VStack(spacing: -3) {
            ZStack(alignment: .bottom) {
                Capsule().fill(.white.opacity(0.15))
                Rectangle().fill(tone(value)).frame(height: column)
                CreepingMarker(
                    color: tone.light(value), width: tube.width, height: 1.5,
                    motion: .bob, cornerRadius: 0.75, isRunning: isBurning
                )
                .frame(width: tube.width, height: 1.5)
                .offset(y: -column + 0.75)
            }
            .frame(width: tube.width, height: tube.height)
            .clipShape(.capsule)

            // The bulb costs 8pt for no information, which the board says out
            // loud. It is what makes the mark read as a thermometer rather than
            // as a very thin tank.
            Circle()
                .fill(tone(value))
                .frame(width: 8, height: 8)
                // A point of rim, not two: the tube's column runs behind the
                // bulb, and a thick collar cuts it off short of the thing it is
                // supposed to be filling.
                .background { Circle().fill(.black).frame(width: 10, height: 10) }
        }
        .animation(markEasing, value: value)
    }
}

extension EnvironmentValues {
    /// How a mark moves to a new reading.
    ///
    /// Easing is right in the band, where a figure lands every few seconds. It is
    /// wrong wherever a mark is *walked* through its scale — the Appearance grid
    /// steps twelve of them ten times a second, and an 0.6s ease on each step
    /// turns that into sixty layout passes a second for the whole window. Which
    /// is the bill this app has already paid once, for a 3pt wobble.
    @Entry var markEasing: Animation? = .easeOut(duration: 0.6)
}

/// Out of range is not a reading. Nothing has reported is drawn as empty, which
/// is also what the band shows while the first poll is still running.
private func clamp(_ percent: Double?) -> Double {
    min(100, max(0, percent ?? 0))
}
