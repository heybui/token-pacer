import SwiftUI

struct ScaleRow: View {
    let line: ScaleLine
    let barWidth: CGFloat
    /// Called with what the column under the pointer means, and with nil when it
    /// leaves. The card prints it; the row only knows what it is drawing.
    var explain: (String?) -> Void = { _ in }
    /// Pin the menu bar to this row's provider. The card is where the providers
    /// are side by side, which is the moment the choice is being made.
    var onPin: () -> Void = {}

    /// Each column is its widest content and no more, and the numeric ones are
    /// trailing so what slack is left falls between the columns rather than
    /// inside them. Left-aligned and oversized, every number sat at the far side
    /// of its own gap and the row read as four islands.
    static let wordmarkWidth: CGFloat = 48    // "COPILOT" at 9.5pt mono
    static let percentWidth: CGFloat = 28     // "100%"
    static let weekWidth: CGFloat = 28        // "100%"
    static let resetWidth: CGFloat = 42       // "12d 07h"
    static let jobsWidth: CGFloat = 24        // the badge at two digits
    /// The job badge belongs to the row beside it rather than to the row's list
    /// of figures, so it sits closer than the columns do.
    static let tightGap: CGFloat = 8
    /// 14, not the 8 the rest of the app uses between neighbours. These columns
    /// are not neighbours — each is a different kind of fact about the same line,
    /// and at 8 the bar ran into its own percentage and the three figures read as
    /// one string. The bar pays for it, which is the right pocket: it is the only
    /// column that can be any length at all.
    static let spacing: CGFloat = 14
    static var fixedColumns: CGFloat {
        wordmarkWidth + percentWidth + weekWidth + resetWidth + jobsWidth
            + spacing * 4 + tightGap
    }

    @Environment(\.tone) private var tone
    /// The wordmark lifts under the pointer, so a name that can be pressed is
    /// told apart from three that are only labels.
    @State private var isHovering = false

    /// The row on the pill wears its own zone, the same rule as every mark and
    /// every figure in the app: green under 75, amber to 90, red over. A fixed
    /// accent colour here would have been the one place in the app where a
    /// colour meant "selected" rather than "this is how much is left".
    private var wordmarkTone: Color {
        if line.isPinned { return tone(line.percent) }
        return .white.opacity(isHovering ? 0.95 : 0.62)
    }

    /// What is behind the row: the pinned one keeps a wash of its own zone, the
    /// one under the pointer lifts off the card, the rest are flat.
    private var rowTint: Color {
        if line.isPinned { return tone(line.percent).opacity(isHovering ? 0.22 : 0.15) }
        return .white.opacity(isHovering ? 0.08 : 0)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            // The whole row is the target. The wordmark alone was a 48pt strip
            // to aim at in a row four times that wide, and the pointer is
            // already on the row whenever the choice is being made.
            Button { if !line.isPinned { onPin() } } label: { columns }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Show \(line.name) on the pill"))
                .onHover { isHovering = $0 }
                .background {
                    // Bled outwards rather than padded inwards: the columns are
                    // measured against the card's width, and moving them to make
                    // room for a highlight would cost the bar its length.
                    RoundedRectangle(cornerRadius: 7)
                        .fill(rowTint)
                        .padding(.horizontal, -8)
                        .padding(.vertical, -4)
                        .animation(.easeOut(duration: 0.15), value: isHovering)
                }
            if let attention = line.attention {
                // Under the row, not in place of it: the figures above may be the
                // last good reading, and this says why they stopped moving.
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 8.5))
                    Text(attention)
                        .font(Typography.mono(9))
                        .lineLimit(1)
                }
                .foregroundStyle(Tokens.amber)
                // Aligned under the bar, so the wordmark column still reads as a
                // list of providers down the card.
                .padding(.leading, Self.wordmarkWidth + Self.spacing)
            }
        }
    }

    /// The bar carries both windows when there are two, and says so. A row with
    /// one — a workspace on a credit budget has a month and nothing else — has
    /// no dot to explain.
    private var barCaption: String {
        let window = Format.windowName(line.windowMinutes)
        guard line.weekPercent != nil else { return String(localized: "Used in this \(window)") }
        return String(
            localized: "This \(window) · the dot is the \(Format.windowName(line.weekWindowMinutes))",
            comment: "Both values name a window: a 5-hour window, a week, a month."
        )
    }

    private var columns: some View {
        HStack(spacing: Self.spacing) {

            Text(line.label)
                .font(Typography.mono(9.5, .semibold))
                .tracking(0.95)
                .foregroundStyle(wordmarkTone)
                .animation(.easeOut(duration: 0.15), value: isHovering)
                .frame(width: Self.wordmarkWidth, alignment: .leading)
                .onHover {
                    explain($0
                        ? (line.isPinned
                            ? String(localized: "\(line.name) is on the pill")
                            : String(localized: "Show \(line.name) on the pill"))
                        : nil)
                }

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
            .onHover { explain($0 ? barCaption : nil) }

            OdometerText(text: Format.percent(line.percent), size: 11, color: tone(line.percent))
                .frame(width: Self.percentWidth, alignment: .trailing)
                .onHover {
                    explain($0 ? String(localized: "Used in this \(Format.windowName(line.windowMinutes))") : nil)
                }

            // The dot's own figure. Without it the second marker is a position
            // with no number, which is half a reading.
            Text(line.weekPercent == nil ? "" : Format.percent(line.weekPercent))
                .font(Typography.mono(9.5))
                .foregroundStyle(.white.opacity(0.5))
                .frame(width: Self.weekWidth, alignment: .trailing)
                .onHover {
                    explain($0 ? String(localized: "Used in this \(Format.windowName(line.weekWindowMinutes))") : nil)
                }

            Text(Format.countdown(to: line.resetsAt))
                .font(Typography.mono(9.5))
                .foregroundStyle(.white.opacity(0.42))
                .frame(width: Self.resetWidth, alignment: .trailing)
                .onHover { explain($0 ? String(localized: "Time left until the window resets") : nil) }
                .padding(.trailing, Self.tightGap - Self.spacing)

            // The slot is held whether or not there is a number in it: a column
            // that appears and disappears moves every row beside it.
            Group {
                if line.jobs > 0 { JobBadge(count: line.jobs) } else { Color.clear }
            }
            .frame(width: Self.jobsWidth, height: PillState.badgeDiameter)
            .onHover {
                explain($0 ? String(localized: "\(line.name) sessions working now") : nil)
            }
        }
        // The gaps between the columns are part of the row, for the pointer as
        // much as for the eye.
        .contentShape(.rect)
    }
}
