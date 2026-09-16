import SwiftUI

/// The 752×540 panel: everything stacked, no tabs, read-only. Settings live in
/// Preferences; this only ever reports.
struct PinnedPanelView: View {
    let snapshot: UsageSnapshot?
    /// Cross-source split — the only figure the per-source snapshot cannot hold.
    let bySource: [UsageSplit]
    var attention: String?
    let onClose: () -> Void

    @State private var showAllHistory = false

    private var tone: Color { Tokens.tone(snapshot?.sessionPercent ?? 0) }
    private var panel: PanelData { snapshot?.panel ?? .empty }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            summary
            divider
            splits
            divider
            footer
        }
        // Same clearance the hover card uses: the first 26pt sit under the notch.
        .padding(.top, 26)
        .padding(.horizontal, 22)
        .padding(.bottom, 22)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var divider: some View {
        Rectangle().fill(.white.opacity(0.08)).frame(height: 1)
    }

    // MARK: - header

    private var header: some View {
        HStack(spacing: 7) {
            PulsingDot(color: tone, isPulsing: snapshot?.isBurning == true)
            Text(headerLabel)
                .font(Typography.mono(9.5))
                .tracking(1.4)
                .foregroundStyle(.white.opacity(0.38))
            if let attention {
                AttentionBadge(message: attention, size: 10)
            }
            Spacer(minLength: 0)
            Button(action: onClose) {
                Text("✕")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.42))
                    .padding(.horizontal, 4)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .frame(height: 20)
    }

    private var headerLabel: String {
        guard let snapshot else { return "READING LOGS · PINNED" }
        return snapshot.isActive ? "SESSION ACTIVE · PINNED" : "WINDOW EMPTY · PINNED"
    }

    // MARK: - ring, weekly cap, sparkline

    private var summary: some View {
        HStack(alignment: .center, spacing: 24) {
            VStack(spacing: 10) {
                UsageRing(
                    percent: snapshot?.sessionPercent, tone: tone, size: 118, lineWidth: 12,
                    label: heroLabel, labelSize: 30
                )
                .overlay(alignment: .bottom) {
                    Text("5-HOUR")
                        .font(Typography.sans(8.5))
                        .tracking(0.34)
                        .foregroundStyle(.white.opacity(0.36))
                        .offset(y: -32)
                }
                Text("Resets in \(Format.countdown(to: snapshot?.resetsAt))")
                    .font(Typography.sans(11.5))
                    .foregroundStyle(.white.opacity(0.6))
            }
            .frame(width: 152)

            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 7) {
                    captionRow("Weekly cap", weeklyCaption)
                    CapBar(
                        percent: snapshot?.weeklyPercent,
                        tone: Tokens.tone(snapshot?.weeklyPercent ?? 0),
                        height: 7, trackOpacity: 0.12
                    )
                }
                VStack(alignment: .leading, spacing: 8) {
                    captionRow("Burn rate", burnCaption)
                    Sparkline(values: panel.sparkline, tone: tone)
                }
            }
        }
    }

    /// The ring carries the percentage; with no ceiling yet it carries raw tokens,
    /// which do not fit — so the hero falls back to the count alone.
    private var heroLabel: String? {
        guard let snapshot else { return nil }
        return snapshot.sessionPercent == nil
            ? Format.tokens(snapshot.sessionTokens)
            : Format.percent(snapshot.sessionPercent)
    }

    private var weeklyCaption: String {
        let percent = Format.percent(snapshot?.weeklyPercent)
        guard let resetsAt = snapshot?.weeklyResetsAt else { return percent }
        return "\(percent) · resets \(Format.weekday(resetsAt))"
    }

    private var burnCaption: String {
        guard let burn = snapshot?.burn else { return "—" }
        var parts: [String] = []
        if let rate = burn.percentPerHour, rate > 0 {
            parts.append("\(Int(rate.rounded()))%/hr")
        }
        parts.append(burn.headroomMinutes.map { "~\($0) min headroom" }
            ?? (snapshot?.isActive == true ? "no limit in sight" : "window empty"))
        return parts.joined(separator: " · ")
    }

    private func captionRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(label)
                .font(Typography.sans(11))
                .foregroundStyle(.white.opacity(0.44))
            Spacer(minLength: 0)
            Text(value)
                .font(Typography.mono(11))
                .foregroundStyle(.white.opacity(0.7))
                .lineLimit(1)
        }
    }

    // MARK: - splits

    private var splits: some View {
        HStack(alignment: .top, spacing: 22) {
            SplitColumn(title: "By model", rows: panel.byModel)
            SplitColumn(title: "By project", rows: panel.byProject)
            SplitColumn(title: "By source", rows: bySource)
        }
    }

    // MARK: - history and spend

    /// Takes whatever height the sections above leave, so the 30-day list fills
    /// the panel instead of scrolling inside a 118pt window with dead space below.
    private var footer: some View {
        history
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(maxHeight: .infinity, alignment: .top)
    }

    private var historyRows: [DayUsage] {
        showAllHistory ? panel.history : Array(panel.history.suffix(7))
    }

    private var history: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(historyLabel)
                    .font(Typography.sans(11))
                    .foregroundStyle(.white.opacity(0.4))
                Spacer(minLength: 0)
                Button(showAllHistory ? "Show 7" : "Show all 30") {
                    showAllHistory.toggle()
                }
                .buttonStyle(.plain)
                .font(Typography.sans(10.5))
                .foregroundStyle(Tokens.amber)
            }
            ScrollView(showAllHistory ? .vertical : []) {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(historyRows) { day in
                        HistoryRow(day: day, label: Format.historyLabel(day.day, compact: !showAllHistory))
                    }
                }
            }
            // A scroller bar over a black panel reads as damage; the rows that
            // run past the edge are the affordance.
            .scrollIndicators(.hidden)
            .frame(maxHeight: .infinity, alignment: .top)
        }
    }

    /// The share is of the busiest day in range, so the average is only ever a
    /// relative figure — it says how even the fortnight was, not how full it was.
    private var historyLabel: String {
        let rows = panel.history
        guard !rows.isEmpty else { return "No history yet" }
        let average = Int((rows.map(\.percent).reduce(0, +) / Double(rows.count)).rounded())
        return showAllHistory
            ? "Last 30 days · avg \(average)% of peak"
            : "Last 7 days · 30-day avg \(average)% of peak"
    }
}

// MARK: - components

/// 26 bars of weighted tokens per 5 minutes. The bar in progress carries the
/// session tone; the rest are neutral, so the eye lands on now.
private struct Sparkline: View {
    let values: [Double]
    let tone: Color
    var height: CGFloat = 40

    var body: some View {
        HStack(alignment: .bottom, spacing: 3) {
            ForEach(Array(values.enumerated()), id: \.offset) { index, value in
                RoundedRectangle(cornerRadius: 2)
                    .fill(index == values.count - 1 ? tone : .white.opacity(0.24))
                    .frame(height: max(3, value * height))
            }
        }
        .frame(height: height, alignment: .bottom)
        .animation(.easeOut(duration: 0.32), value: values)
    }
}

private struct SplitColumn: View {
    let title: String
    let rows: [UsageSplit]

    /// The design's ranking colours: the leader stands out, the tail recedes.
    private static let rank: [Color] = [Tokens.amber, Tokens.blue, .white.opacity(0.3)]

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title)
                .font(Typography.sans(11))
                .foregroundStyle(.white.opacity(0.4))
            if rows.isEmpty {
                Text("no open window")
                    .font(Typography.sans(11.5))
                    .foregroundStyle(.white.opacity(0.3))
            }
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(row.name)
                            .font(Typography.sans(11.5))
                            .foregroundStyle(.white.opacity(0.82))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        CapBar(
                            percent: row.share,
                            tone: Self.rank[min(index, Self.rank.count - 1)],
                            height: 3, trackOpacity: 0.1
                        )
                    }
                    Text(Format.percent(row.share))
                        .font(Typography.mono(10.5))
                        .foregroundStyle(.white.opacity(0.48))
                        .frame(width: 36, alignment: .trailing)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct HistoryRow: View {
    let day: DayUsage
    let label: String

    var body: some View {
        HStack(spacing: 10) {
            Text(label)
                .foregroundStyle(.white.opacity(0.38))
                .frame(width: 48, alignment: .leading)
            Text(Format.blocks(day.percent))
                .tracking(0.55)
                .foregroundStyle(Tokens.tone(day.percent))
            Text(Format.percent(day.percent))
                .foregroundStyle(.white.opacity(0.52))
        }
        .font(Typography.mono(11))
    }
}
