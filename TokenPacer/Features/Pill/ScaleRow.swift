import SwiftUI

struct ScaleRow: View {
    let line: ScaleLine
    let barWidth: CGFloat
    /// Called with what the column under the pointer means, and with nil when it
    /// leaves. The card prints it; the row only knows what it is drawing.
    var explain: (String?) -> Void = { _ in }

    /// Each column is its widest content and no more, and the numeric ones are
    /// trailing so what slack is left falls between the columns rather than
    /// inside them. Left-aligned and oversized, every number sat at the far side
    /// of its own gap and the row read as four islands.
    static let wordmarkWidth: CGFloat = 48    // "COPILOT" at 9.5pt mono
    static let percentWidth: CGFloat = 28     // "100%"
    static let weekWidth: CGFloat = 28        // "100%"
    static let resetWidth: CGFloat = 42       // "12d 07h"
    /// 14, not the 8 the rest of the app uses between neighbours. These columns
    /// are not neighbours — each is a different kind of fact about the same line,
    /// and at 8 the bar ran into its own percentage and the three figures read as
    /// one string. The bar pays for it, which is the right pocket: it is the only
    /// column that can be any length at all.
    static let spacing: CGFloat = 14
    static var fixedColumns: CGFloat {
        wordmarkWidth + percentWidth + weekWidth + resetWidth + spacing * 4
    }

    @Environment(\.tone) private var tone

    var body: some View {
        HStack(spacing: Self.spacing) {
            Text(line.label)
                .font(Typography.mono(9.5, .semibold))
                .tracking(0.95)
                .foregroundStyle(.white.opacity(0.62))
                .frame(width: Self.wordmarkWidth, alignment: .leading)
                .onHover { explain($0 ? line.name : nil) }

            // The capsule bar whatever the menu bar is wearing. These rows are a
            // comparison — four readings down a column, on one domain — and that
            // is the job position on a line does better than any of the other
            // eleven. It is also the only mark that can take the width the card
            // has to give it. The choice in Preferences dresses the menu bar,
            // where space is the constraint; here it is not.
            CapsuleBar(
                percent: line.percent,
                weekPercent: line.weekPercent,
                width: barWidth,
                isBurning: line.isBurning
            )
            .onHover { explain($0 ? "5-hour window · the dot is the week" : nil) }

            OdometerText(text: Format.percent(line.percent), size: 11, color: tone(line.percent))
                .frame(width: Self.percentWidth, alignment: .trailing)
                .onHover { explain($0 ? "Used in this 5-hour window" : nil) }

            // The dot's own figure. Without it the second marker is a position
            // with no number, which is half a reading.
            Text(line.weekPercent == nil ? "" : Format.percent(line.weekPercent))
                .font(Typography.mono(9.5))
                .foregroundStyle(.white.opacity(0.5))
                .frame(width: Self.weekWidth, alignment: .trailing)
                .onHover { explain($0 ? "Used of the weekly cap" : nil) }

            Text(Format.countdown(to: line.resetsAt))
                .font(Typography.mono(9.5))
                .foregroundStyle(.white.opacity(0.42))
                .frame(width: Self.resetWidth, alignment: .trailing)
                .onHover { explain($0 ? "Time left until the window resets" : nil) }
        }
    }
}
