import SwiftUI

/// One row per provider, on the same scale.
///
/// The band above already carries the active source; this is where the others
/// become comparable — same capsules, same domain, each ending in its own
/// reset, because 81% of a five-hour window and 81% of a week are not the same
/// problem. A provider that reports nothing keeps its row and shows `--`:
/// absent is a state worth seeing, and it is not the same as zero.
struct HoverCard: View {
    let snapshot: UsageSnapshot?
    /// Every source the store has a reading for, in a stable order.
    let providers: [UsageSnapshot]
    let attention: String?
    /// What is left for the bar once each row's fixed columns are paid for. The
    /// shell measures it: the card is as wide as the state it is drawn in.
    let barWidth: CGFloat

    @Environment(\.tone) private var toneScale

    /// What the figure under the pointer means. The card is the only place with
    /// room to say it, and a system tooltip never appears here: the panel never
    /// activates, so AppKit never draws one.
    @State private var caption: String?

    var body: some View {
        // 11 between lines. Each row is a whole reading — a provider, where it
        // stands, its week, its reset — and at 6 they stacked into a block the eye
        // had to take apart. The card sizes to its content, so the air costs
        // nothing but the height it is worth.
        VStack(alignment: .leading, spacing: 11) {
            // Kept even when the rows below say the same thing in figures. With
            // one provider tracked the card would otherwise be a single line, and
            // "Plenty of room" is the sentence the pill exists to say.
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(statusLine)
                    .font(Typography.sans(13, .semibold))
                    .foregroundStyle(.white)
                    .onHover { caption = $0 ? zoneRule : nil }
                Spacer(minLength: 8)
                if let attention {
                    AttentionBadge(message: attention, size: 10)
                } else if let snapshot, snapshot.sessionPercent != nil {
                    // How old the figure is. Between readings the pill is showing
                    // the last one unmoved, and saying so is the difference
                    // between a stale number and a lying one.
                    Text(reportedLabel(snapshot))
                        .font(Typography.mono(9.5))
                        .foregroundStyle(.white.opacity(0.34))
                        .onHover { caption = $0 ? "When the numbers were last read" : nil }
                }
            }

            ForEach(scaleLines) { line in
                ScaleRow(line: line, barWidth: barWidth) { caption = $0 }
            }

            Text(caption ?? Self.hint)
                .font(Typography.mono(9.5))
                .foregroundStyle(.white.opacity(caption == nil ? 0.3 : 0.55))
                .lineLimit(1)
                // A change of words, not of place: the line fades from one to the
                // next rather than swapping under the pointer.
                .contentTransition(.opacity)
                .animation(.easeInOut(duration: 0.18), value: caption)
        }
        // The band above is already a full menu-bar row of clearance, so the card
        // needs a line of air under it, not a margin. It was reading as a third
        // empty.
        .padding(.top, 4)
        .padding(.horizontal, 18)
        .padding(.bottom, 10)
    }

    /// The line under the rows when nothing is under the pointer: what this
    /// window can do, since neither gesture is one you would guess at.
    private static let hint = "Double-click details · right-click settings"

    private var statusLine: String {
        guard let percent = snapshot?.sessionPercent else { return "Measuring" }
        if percent >= toneScale.critAt { return "Wrap up soon" }
        return percent >= toneScale.warnAt ? "Running hot" : "Plenty of room"
    }

    /// What the colours mean, in the user's own numbers.
    private var zoneRule: String {
        "Safe to \(Int(toneScale.warnAt))% · watch to \(Int(toneScale.critAt))% · over above"
    }

    /// Every window worth a row, in the order they belong to each other.
    ///
    /// The weekly cap is a provider's, not the app's: Claude states one and so
    /// does Codex, and they run out on different days. So the week follows its own
    /// provider rather than sitting once at the bottom, where it silently belonged
    /// to whichever source happened to be active.
    private var scaleLines: [ScaleLine] {
        providers.map { provider in
            ScaleLine(
                id: provider.source.rawValue,
                label: provider.source.wordmark,
                name: provider.source.displayName,
                percent: provider.sessionPercent,
                resetsAt: provider.resetsAt,
                weekPercent: provider.weeklyPercent,
                isBurning: provider.isBurning
            )
        }
    }

    /// "reported" alone would imply the figure was just read. Between anchors it
    /// is that reading carried forward by local token flow, so say how old it is.
    private func reportedLabel(_ snapshot: UsageSnapshot) -> String {
        guard let confirmedAt = snapshot.confirmedAt else { return "reported" }
        let minutes = Int(Date.now.timeIntervalSince(confirmedAt) / 60)
        return minutes < 1 ? "reported" : "reported \(minutes)m ago"
    }
}
