import AppKit
import SwiftUI

/// Which progress mark the pill leads with.
///
/// The board offers twelve, judged by eye against each other, and says why they
/// are worth judging as a set: each encodes progress by a different mechanism —
/// position, angle, count, level, depletion, occlusion — so the choice is not
/// decoration. The order here is the board's own, which is the order the
/// Appearance grid draws them in.
enum Mark: String, CaseIterable, Sendable {
    case capsuleBar
    case ringWings
    case notchTank
    case pips
    case halfGauge
    case eclipse
    case tokenStack
    case hourglass
    case dottedArc
    case dotMatrix
    case signalStrength
    case thermometer

    var displayName: String {
        switch self {
        case .capsuleBar: "Capsule bar"
        case .ringWings: "Ring wings"
        case .notchTank: "Notch tank"
        case .pips: "Pips"
        case .halfGauge: "Half gauge"
        case .eclipse: "Eclipse"
        case .tokenStack: "Token stack"
        case .hourglass: "Hourglass"
        case .dottedArc: "Dotted arc"
        case .dotMatrix: "Dot matrix"
        case .signalStrength: "Signal strength"
        case .thermometer: "Thermometer"
        }
    }

    /// How it reads progress. The board's own one-line verdict on each, which is
    /// what the Appearance pane shows under the selected tile.
    var axis: String {
        switch self {
        case .capsuleBar: "position on a zone track"
        case .ringWings: "angle on a zone track"
        case .notchTank: "liquid remaining"
        case .pips: "count of 8"
        case .halfGauge: "needle angle"
        case .eclipse: "disc occluded"
        case .tokenStack: "discs remaining"
        case .hourglass: "sand transferred"
        case .dottedArc: "count of 12, circular"
        case .dotMatrix: "count of 9"
        case .signalStrength: "bars remaining"
        case .thermometer: "column height"
        }
    }

    /// What it costs in a wing, which is the whole argument between them. Both
    /// wings are measured from the wider one, so this figure is paid twice.
    ///
    /// Measured from the drawing, not declared beside it. A number kept in step
    /// with a mark by hand is a number that goes out of step the first time the
    /// mark is nudged — and it goes out of step *silently*, because the band
    /// would still be laid out to the old figure while the new one drew over its
    /// own gutter. So the mark is laid out once and asked how wide it came out.
    ///
    /// Cached: it is asked for on every layout pass, and a mark's resting size
    /// cannot change — nothing in it depends on the reading.
    @MainActor
    var width: CGFloat { size.width }

    /// The whole drawing's size. The wings only ever ask for the width; an
    /// expanded state scaling the mark up needs both.
    @MainActor
    var size: CGSize {
        if let known = Self.measured[self] { return known }
        // A resting mark: at rest nothing in the set hosts an `NSView`, so this
        // is a plain SwiftUI layout with nothing to start or tear down.
        let view = NSHostingView(rootView: MarkView(mark: self, percent: 100))
        let size = CGSize(
            width: ceil(view.fittingSize.width), height: ceil(view.fittingSize.height)
        )
        Self.measured[self] = size
        return size
    }

    @MainActor private static var measured: [Mark: CGSize] = [:]
}

/// The chosen mark, scaled up to lead an expanded state.
///
/// The board's rule for every state that opens: the same mark the menu bar wears,
/// larger — not a different drawing. Scaled rather than redrawn, because a mark
/// is a proportion and the proportion is the reading.
struct MarkHero: View {
    let mark: Mark
    let percent: Double?
    var isBurning = false
    var scale: CGFloat

    var body: some View {
        MarkView(mark: mark, percent: percent, isBurning: isBurning)
            .scaleEffect(scale)
            .frame(width: mark.size.width * scale, height: mark.size.height * scale)
    }
}

/// The mark, whichever one is chosen. Every caller passes the same facts and the
/// mark decides what to do with them — the one place a reading becomes a drawing.
///
/// Nothing below animates with SwiftUI. Every mark that moves while a model is
/// answering moves one `CreepingMarker`, which is a `CALayer` on the render
/// server; the rest of each mark is static and redrawn only when a reading lands.
struct MarkView: View {
    let mark: Mark
    let percent: Double?
    /// Only the two zone-track marks carry a second reading. The other ten say
    /// one thing, which is the point of choosing them.
    var weekPercent: Double?
    var isBurning = false
    /// What the caller can spare. Marks that do not stretch ignore it.
    var width: CGFloat?

    var body: some View {
        switch mark {
        case .capsuleBar:
            CapsuleBar(
                percent: percent, weekPercent: weekPercent,
                width: width ?? CapsuleBar.intrinsicWidth, isBurning: isBurning
            )
        case .ringWings:
            RingMark(
                percent: percent, weekPercent: weekPercent,
                size: RingMark.intrinsicSize, isBurning: isBurning
            )
        case .notchTank: NotchTankMark(percent: percent, isBurning: isBurning)
        case .pips: PipsMark(percent: percent, isBurning: isBurning)
        case .halfGauge: HalfGaugeMark(percent: percent, isBurning: isBurning)
        case .eclipse: EclipseMark(percent: percent, isBurning: isBurning)
        case .tokenStack: TokenStackMark(percent: percent, isBurning: isBurning)
        case .hourglass: HourglassMark(percent: percent, isBurning: isBurning)
        case .dottedArc: DottedArcMark(percent: percent, isBurning: isBurning)
        case .dotMatrix: DotMatrixMark(percent: percent, isBurning: isBurning)
        case .signalStrength: SignalMark(percent: percent, isBurning: isBurning)
        case .thermometer: ThermometerMark(percent: percent, isBurning: isBurning)
        }
    }
}
