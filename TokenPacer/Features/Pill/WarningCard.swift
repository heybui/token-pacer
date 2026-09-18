import SwiftUI

/// Fires once when the window crosses critical: the figure big enough to read
/// from across the desk, and the one number that matters — how long is left.
///
/// No dismiss button by design: mousing over it acknowledges, and it never
/// re-fires for this window.
struct WarningCard: View {
    let snapshot: UsageSnapshot?
    let mark: Mark
    let headline: String
    /// Under the band on a notched screen, under the notch itself on one without.
    let topInset: CGFloat

    var body: some View {
        HStack(spacing: 16) {
            // The mark the menu bar wears, twice the size. The card is the same
            // reading opened up, and a different drawing here would make it a
            // second opinion.
            MarkHero(
                mark: mark, percent: snapshot?.sessionPercent,
                isBurning: snapshot?.isBurning == true, scale: 2
            )
            VStack(alignment: .leading, spacing: 4) {
                OdometerText(text: headline, size: 26, color: Tokens.red)
                Text(warningLine)
                    .font(Typography.sans(12.5))
                    .foregroundStyle(.white.opacity(0.66))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.top, topInset)
        .padding(.horizontal, 20)
        .padding(.bottom, 16)
    }

    /// The reset, never a projection of when the window runs dry: that needed a
    /// conversion from tokens to points that no provider publishes.
    private var warningLine: String {
        "\(Format.countdown(to: snapshot?.resetsAt)) to reset · wrap up soon"
    }
}
