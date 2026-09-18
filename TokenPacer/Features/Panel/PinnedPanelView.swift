import SwiftUI

/// The 752×540 panel: everything stacked, no tabs, read-only. Settings live in
/// Preferences; this only ever reports.
struct PinnedPanelView: View {
    let snapshot: UsageSnapshot?
    /// Cross-source split — the only figure the per-source snapshot cannot hold.
    let bySource: [UsageSplit]
    /// The mark the menu bar is wearing. Every expanded state leads with it.
    var mark: Mark = .capsuleBar
    var attention: String?
    /// Where the panel's first row starts: under the band on a notched screen,
    /// under the notch itself on one without.
    var topInset: CGFloat = PillState.boardBodyTop
    /// False on a notched screen, where the band carries the label and the close
    /// button. There is no band off one, so the panel keeps its own row.
    var showsHeader = true
    let onClose: () -> Void

    @Environment(\.tone) private var toneScale

    private var tone: Color { toneScale(snapshot?.sessionPercent) }
    private var panel: PanelData { snapshot?.panel ?? .empty }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if showsHeader { header }
            summary
            divider
            splits
            divider
            footer
        }
        // Same clearance the hover card uses: under the band, or under the notch
        // itself on a screen that has none.
        .padding(.top, topInset)
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
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
        }
        .frame(height: 20)
    }

    private var headerLabel: String { PillView.pinnedLabel(for: snapshot) }

    // MARK: - ring, weekly cap, sparkline

    private var summary: some View {
        HStack(alignment: .center, spacing: 24) {
            VStack(spacing: 12) {
                // The same mark, three times the size, with the figure under it
                // rather than inside it: only one of the twelve has a hole in the
                // middle to put a number in.
                MarkHero(
                    mark: mark, percent: snapshot?.sessionPercent,
                    isBurning: snapshot?.isBurning == true, scale: 3
                )
                .frame(height: 60)
                OdometerText(text: Format.percent(snapshot?.sessionPercent), size: 30, color: tone)
                Text("5-HOUR")
                    .font(Typography.sans(8.5))
                    .tracking(0.34)
                    .foregroundStyle(.white.opacity(0.36))
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
                        tone: toneScale(snapshot?.weeklyPercent),
                        height: 7, trackOpacity: 0.12
                    )
                }
                VStack(alignment: .leading, spacing: 8) {
                    captionRow("Activity", activityCaption)
                    Sparkline(values: panel.sparkline, tone: tone)
                }
            }
        }
    }

    private var weeklyCaption: String {
        let percent = Format.percent(snapshot?.weeklyPercent)
        guard let resetsAt = snapshot?.weeklyResetsAt else { return percent }
        return "\(percent) · resets \(Format.weekday(resetsAt))"
    }

    /// The sparkline's own span, not a figure derived from it: 26 five-minute
    /// buckets. A rate in tokens an hour used to sit here and said nothing a
    /// person could act on — the shape is the whole point of this row.
    private var activityCaption: String {
        snapshot?.isActive == true ? "last 2 hours" : "window empty"
    }

    private func captionRow(_ label: String, _ value: String, tone: Color? = nil) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(label)
                .font(Typography.sans(11))
                .foregroundStyle(.white.opacity(0.44))
            Spacer(minLength: 0)
            Text(value)
                .font(Typography.mono(11))
                .foregroundStyle(tone ?? .white.opacity(0.7))
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
        HStack(alignment: .top, spacing: 26) {
            history.frame(maxWidth: .infinity, alignment: .leading)
            if let spend = snapshot?.spend {
                SpendCell(spend: spend).frame(width: 260)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var history: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(historyLabel)
                .font(Typography.sans(11))
                .foregroundStyle(.white.opacity(0.4))
            HistoryHeatmap(days: panel.history)
        }
    }

    /// The grid is relative to the busiest day in range: no daily cap exists to
    /// be a percentage of, so the darkest square is the peak, not "full".
    private var historyLabel: String {
        let rows = panel.history
        guard let peak = rows.max(by: { $0.weighted < $1.weighted }), peak.weighted > 0 else {
            return "No history yet"
        }
        return "Last \(rows.count) days · busiest \(Format.day(peak.day))"
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

/// A calendar grid rather than a list: one square per day, one column per week.
/// A quarter fits in the space seven rows took, and the shape of a fortnight is
/// visible at a glance where a list only ever showed the last seven days.
private struct HistoryHeatmap: View {
    @Environment(\.tone) private var toneScale
    let days: [DayUsage]
    var cell: CGFloat = 15
    var gap: CGFloat = 4

    private var calendar: Calendar { .current }

    private struct Week: Identifiable {
        let id: Date
        /// Seven slots from the week's first day; nil where the range starts or
        /// ends mid-week.
        let days: [DayUsage?]
    }

    private var weeks: [Week] {
        let grouped = Dictionary(grouping: days) { weekStart(of: $0.day) }
        return grouped.keys.sorted().map { start in
            let week = grouped[start] ?? []
            return Week(id: start, days: (0..<7).map { row in
                week.first { self.row(of: $0.day) == row }
            })
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: gap) {
            weekdayLabels
            VStack(alignment: .leading, spacing: 4) {
                monthLabels
                HStack(spacing: gap) {
                    ForEach(weeks) { week in
                        VStack(spacing: gap) {
                            ForEach(Array(week.days.enumerated()), id: \.offset) { _, day in
                                square(day)
                            }
                        }
                    }
                }
            }
        }
    }

    private func square(_ day: DayUsage?) -> some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(fill(day))
            .frame(width: cell, height: cell)
            .help(day.map { "\(Format.day($0.day)) · \(Format.percent($0.percent)) of peak" } ?? "")
    }

    /// Empty days keep the track colour: a quiet day is not a faint busy one.
    private func fill(_ day: DayUsage?) -> Color {
        guard let day, day.percent > 0 else { return .white.opacity(0.06) }
        return toneScale(day.percent).opacity(0.35 + 0.65 * min(1, day.percent / 100))
    }

    private var weekdayLabels: some View {
        VStack(spacing: gap) {
            ForEach(0..<7, id: \.self) { row in
                Text(row % 2 == 1 ? weekdayName(row) : "")
                    .font(Typography.mono(9))
                    .foregroundStyle(.white.opacity(0.3))
                    .frame(width: 22, height: cell, alignment: .leading)
            }
        }
        // Clears the month strip above the grid.
        .padding(.top, 15)
    }

    /// Named where the month turns, so thirteen identical columns can be placed.
    private var monthLabels: some View {
        HStack(spacing: gap) {
            ForEach(Array(weeks.enumerated()), id: \.element.id) { index, week in
                Text(startsNewMonth(index) ? week.id.formatted(.dateTime.month(.abbreviated)) : "")
                    .font(Typography.mono(9))
                    .foregroundStyle(.white.opacity(0.3))
                    .fixedSize()
                    .frame(width: cell, height: 11, alignment: .leading)
            }
        }
    }

    private func startsNewMonth(_ index: Int) -> Bool {
        guard index > 0 else { return true }
        return calendar.component(.month, from: weeks[index].id)
            != calendar.component(.month, from: weeks[index - 1].id)
    }

    private func weekdayName(_ row: Int) -> String {
        let index = (calendar.firstWeekday - 1 + row) % 7
        return String(calendar.shortWeekdaySymbols[index].prefix(3))
    }

    private func weekStart(of date: Date) -> Date {
        calendar.dateInterval(of: .weekOfYear, for: date)?.start ?? date
    }

    private func row(of date: Date) -> Int {
        (calendar.component(.weekday, from: date) - calendar.firstWeekday + 7) % 7
    }
}

/// Only drawn for accounts that buy usage past the plan. The budget is the
/// account's own monthly limit, not a preference we invented.
private struct SpendCell: View {
    @Environment(\.tone) private var toneScale
    let spend: Spend

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Extra usage · month to date")
                .font(Typography.sans(11))
                .foregroundStyle(.white.opacity(0.4))
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text(spend.used.currency)
                    .font(Typography.mono(11))
                    .foregroundStyle(.white.opacity(0.5))
                OdometerText(text: Format.amount(spend.used), size: 22, color: .white)
            }
            if let limit = spend.limit {
                Text("of \(Format.amount(limit)) budget")
                    .font(Typography.sans(11.5))
                    .foregroundStyle(.white.opacity(0.44))
            }
            CapBar(
                percent: spend.percent,
                tone: toneScale(spend.percent),
                height: 7, trackOpacity: 0.12
            )
            Text(Format.projection(used: spend.used))
                .font(Typography.mono(10.5))
                .foregroundStyle(.white.opacity(0.4))
        }
    }
}
