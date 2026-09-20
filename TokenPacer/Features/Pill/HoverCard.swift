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
    /// Every provider's complaint, so a row that cannot report says why on its
    /// own line. The badge above follows the active source alone, and a second
    /// provider failing used to raise nothing at all.
    var errors: [SourceID: String] = [:]
    /// What is left for the bar once each row's fixed columns are paid for. The
    /// shell measures it: the card is as wide as the state it is drawn in.
    let barWidth: CGFloat
    /// The two gestures the card used to spell out in a hint, as buttons.
    var onExpand: () -> Void = {}
    var onOpenMenu: () -> Void = {}
    /// Ask every provider again. Only reachable while something is wrong, which
    /// is the only time there is anything to ask again about.
    var onRecheck: () -> Void = {}

    @Environment(\.tone) private var toneScale

    /// What the figure under the pointer means. The card is the only place with
    /// room to say it, and a system tooltip never appears here: the panel never
    /// activates, so AppKit never draws one.
    @State private var caption: String?

    /// Which of the rotating lines is showing. The footer says something about
    /// the reading whenever the pointer is not asking about a figure.
    @State private var line = 0

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
                if let trouble {
                    // A triangle here repeated what the failing rows already say
                    // under their own bars, and it could not be pressed: the only
                    // way to clear a stale complaint was Preferences → Check
                    // again. The slot is worth more as the button for that.
                    CardButton(
                        symbol: "arrow.clockwise", label: String(localized: "Check again"),
                        tint: Tokens.amber, spins: true, action: onRecheck
                    ) { caption = $0 ?? trouble }
                } else if let snapshot, snapshot.sessionPercent != nil {
                    // How old the figure is. Between readings the pill is showing
                    // the last one unmoved, and saying so is the difference
                    // between a stale number and a lying one.
                    Text(reportedLabel(snapshot))
                        .font(Typography.mono(9.5))
                        .foregroundStyle(.white.opacity(0.34))
                        .onHover { caption = $0 ? String(localized: "When the numbers were last read") : nil }
                }
            }

            ForEach(scaleLines) { line in
                ScaleRow(line: line, barWidth: barWidth) { caption = $0 }
            }

            HStack(spacing: 6) {
                Text(footer)
                    .font(Typography.mono(9.5))
                    .foregroundStyle(.white.opacity(caption == nil ? 0.34 : 0.55))
                    .lineLimit(1)
                    // A change of words, not of place: the line fades from one to
                    // the next rather than swapping under the pointer.
                    .contentTransition(.opacity)
                    .animation(.easeInOut(duration: 0.3), value: footer)
                    // Only while the card is on screen, which is the only time it
                    // is read. The id restarts it when the readings change, so a
                    // line that just went stale is not held for its four seconds.
                    .task(id: reports) {
                        while !Task.isCancelled {
                            try? await Task.sleep(for: .seconds(4))
                            line += 1
                        }
                    }
                Spacer(minLength: 8)
                CardButton(
                    symbol: "arrow.down.left.and.arrow.up.right",
                    label: String(localized: "Open the panel"),
                    action: onExpand
                ) { caption = $0 }
                CardButton(symbol: "gearshape", label: String(localized: "Settings"), action: onOpenMenu) {
                    caption = $0
                }
            }
        }
        // The band above is already a full menu-bar row of clearance, so the card
        // needs a line of air under it, not a margin. It was reading as a third
        // empty.
        .padding(.top, 4)
        .padding(.horizontal, 18)
        .padding(.bottom, 10)
    }

    /// The complaint the button answers. The badge this slot used to hold
    /// followed the active source alone, so a card whose Codex row was saying it
    /// could not be read showed nothing up here and offered nothing to press —
    /// which is the state the button exists for. `recheck` asks every provider
    /// again regardless, so any row's complaint is reason enough to draw it.
    private var trouble: String? {
        attention ?? providers.lazy.compactMap { errors[$0.source] }.first
    }

    /// What the pointer asked about, or the rotating report when it asked
    /// nothing. Hovering a figure always wins: an answer to a question beats a
    /// line that arrived on a timer.
    private var footer: String { caption ?? reports[line % reports.count] }

    /// The state of the reading in sentences, one at a time. Never a figure the
    /// rows already carry — this is what the numbers add up to.
    private var reports: [String] {
        guard let snapshot else { return [String(localized: "Reading the logs")] }
        var lines: [String] = []
        if let percent = snapshot.sessionPercent {
            lines.append(String(
                localized: "\(snapshot.source.displayName) at \(Format.percent(percent)) of this window",
                comment: "Rotating footer line. First value is a product name, second a percentage."
            ))
        }
        if snapshot.resetsAt != nil {
            lines.append(String(localized: "Window resets in \(Format.countdown(to: snapshot.resetsAt))"))
        }
        if let week = snapshot.weeklyPercent {
            lines.append(String(localized: "Week at \(Format.percent(week))"))
        }
        lines.append(snapshot.isBurning
            ? String(localized: "A model is answering now")
            : String(localized: "Nothing is running"))
        return lines
    }

    private var statusLine: String {
        guard let percent = snapshot?.sessionPercent else { return String(localized: "Measuring") }
        if percent >= toneScale.critAt { return String(localized: "Wrap up soon") }
        return percent >= toneScale.warnAt
            ? String(localized: "Running hot")
            : String(localized: "Plenty of room")
    }

    /// What the colours mean, in the user's own numbers.
    private var zoneRule: String {
        String(
            localized: "Safe to \(Int(toneScale.warnAt))% · watch to \(Int(toneScale.critAt))% · over above",
            comment: "What the three tones mean, in the user's own thresholds."
        )
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
                isBurning: provider.isBurning,
                attention: errors[provider.source]
            )
        }
    }

    /// "reported" alone would imply the figure was just read. Between anchors it
    /// is that reading carried forward by local token flow, so say how old it is.
    private func reportedLabel(_ snapshot: UsageSnapshot) -> String {
        guard let confirmedAt = snapshot.confirmedAt else { return String(localized: "reported") }
        let minutes = Int(Date.now.timeIntervalSince(confirmedAt) / 60)
        return minutes < 1
            ? String(localized: "reported")
            : String(localized: "reported \(minutes)m ago")
    }
}

/// A control in the card's footer: an icon that says what it does on hover, in
/// the same line the rows caption themselves into.
private struct CardButton: View {
    let symbol: String
    let label: String
    var tint: Color = .white.opacity(0.42)
    /// One turn on press. A reading takes seconds to come back and the panel
    /// looks identical while it does, so without this a press reads as a miss.
    var spins = false
    let action: () -> Void
    let onCaption: (String?) -> Void

    @State private var turns = 0

    var body: some View {
        Button {
            if spins { turns += 1 }
            action()
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(tint)
                .rotationEffect(.degrees(Double(turns) * 360))
                .animation(.easeInOut(duration: 0.55), value: turns)
                .frame(width: 18, height: 14)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .onHover { onCaption($0 ? label : nil) }
    }
}
