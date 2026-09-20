import SwiftUI

/// What the pill says when a window crosses one of the two marks.
///
/// Raised by the store for whichever provider crossed — the pinned one or not —
/// and held until the pointer comes near, which is the whole of the interaction.
/// No dismiss button by design: reading it is answering it.
struct WarningCard: View {
    let alert: ZoneAlert?
    /// The provider that crossed, whose figures these are.
    let snapshot: UsageSnapshot?
    let mark: Mark
    /// Under the band on a notched screen, under the notch itself on one without.
    let topInset: CGFloat

    private var isOver: Bool { alert?.isOver ?? true }
    private var tone: Color { isOver ? Tokens.red : Tokens.amber }
    private var percent: Double? { alert?.percent ?? snapshot?.sessionPercent }

    var body: some View {
        HStack(spacing: 16) {
            // The mark the menu bar wears, twice the size. The card is the same
            // reading opened up, and a different drawing here would make it a
            // second opinion.
            MarkHero(
                mark: mark, percent: percent,
                isBurning: snapshot?.isBurning == true, scale: 2
            )
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    OdometerText(text: Format.percent(percent), size: 26, color: tone)
                    // Which provider this is about. The pill may be reporting
                    // another one entirely, and a figure with no name on it
                    // would be read as the one already on screen.
                    Text(verbatim: snapshot?.source.wordmark ?? "")
                        .font(Typography.mono(10, .semibold))
                        .tracking(1.1)
                        .foregroundStyle(.white.opacity(0.5))
                }
                Text(line)
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
    private var line: String {
        let countdown = Format.countdown(to: alert?.resetsAt ?? snapshot?.resetsAt)
        return isOver
            ? String(
                localized: "\(countdown) to reset · wrap up soon",
                comment: "The card's one line past the far mark. Value is a countdown."
            )
            : String(
                localized: "\(countdown) to reset · still room",
                comment: "The card's one line past the first mark. Value is a countdown."
            )
    }
}
