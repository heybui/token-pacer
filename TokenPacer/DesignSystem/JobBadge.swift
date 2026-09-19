import SwiftUI

/// How many sessions are working right now, across every tracked provider.
///
/// Neutral grey on purpose, and the board says why: the mark owns the zone
/// colour, the badge owns the number. A count tinted green or amber would read
/// as a figure about the window rather than about what is running.
///
/// One digit is a circle; a second widens it to a pill at the same corner
/// radius, so ten jobs is the same shape as one and nothing switches form.
struct JobBadge: View {
    let count: Int
    /// The panels draw the same badge at their own header size. A multiplier
    /// rather than a size: the board scales the layer, it does not re-typeset.
    var scale: CGFloat = 1

    /// Every change pops it, appearing included — that is the whole signal, and
    /// a number that changes without moving is a number nobody notices. A quota
    /// reading landing at the same count changes nothing and stays still.
    @State private var pops = 0

    private var label: String {
        count == 1 ? "1 session working" : "\(count) sessions working"
    }

    private var width: CGFloat {
        PillState.Badge.working(count).width * scale
    }

    var body: some View {
        Text(count.formatted(.number))
            .font(Typography.mono(9.5 * scale, .bold))
            .foregroundStyle(.white)
            .frame(width: width, height: PillState.badgeDiameter * scale)
            .background(Tokens.badgeFill, in: .rect(cornerRadius: PillState.badgeCorner * scale))
            .phaseAnimator([1.0, 1.28, 1.0], trigger: pops) { badge, phase in
                badge.scaleEffect(phase)
            } animation: { phase in
                // 220ms in two unequal halves: out fast at 45% of it, back over
                // the rest. The curve is the board's.
                .timingCurve(0.32, 0.72, 0, 1, duration: phase == 1.28 ? 0.099 : 0.121)
            }
            .onAppear { pops += 1 }
            .onChange(of: count) { pops += 1 }
            .help(label)
            .accessibilityLabel(label)
    }
}
