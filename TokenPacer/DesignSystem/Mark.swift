import SwiftUI

/// Which progress mark the pill leads with.
///
/// The board offers twelve, judged by eye against each other, and says why they
/// are worth judging as a set: each encodes progress by a different mechanism —
/// position, angle, count, level, depletion — so the choice is not decoration.
/// Two are built. The other ten arrive with the Appearance pane that picks them.
enum Mark: String, CaseIterable, Sendable {
    case capsuleBar
    case ringWings

    var displayName: String {
        switch self {
        case .capsuleBar: "Capsule bar"
        case .ringWings: "Ring wings"
        }
    }

    /// How it reads progress. The board's own one-line verdict on each, which is
    /// what the Appearance pane shows under the selected tile.
    var axis: String {
        switch self {
        case .capsuleBar: "position on a zone track"
        case .ringWings: "angle on a zone track"
        }
    }

    /// What it costs in a wing, which is the whole argument between these two.
    var width: CGFloat {
        switch self {
        case .capsuleBar: 36
        case .ringWings: 18
        }
    }
}

/// The mark, whichever one is chosen. Every caller passes the same facts and the
/// mark decides what to do with them — which is the seam the other ten arrive at.
struct MarkView: View {
    let mark: Mark
    let percent: Double?
    var weekPercent: Double?
    var isBurning = false
    /// What the caller can spare. Marks that do not stretch ignore it.
    var width: CGFloat?

    var body: some View {
        switch mark {
        case .capsuleBar:
            CapsuleBar(
                percent: percent, weekPercent: weekPercent,
                width: width ?? mark.width, isBurning: isBurning
            )
        case .ringWings:
            RingMark(
                percent: percent, weekPercent: weekPercent,
                size: mark.width, isBurning: isBurning
            )
        }
    }
}
