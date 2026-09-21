import SwiftUI

/// The 752×540 panel: everything stacked, no tabs, read-only. Settings live in
/// Preferences; this only ever reports.
struct PinnedPanelView: View {
    /// The provider the menu bar is carrying. What the panel opens on, and what
    /// it falls back to.
    let snapshot: UsageSnapshot?
    /// Every tracked provider, so the panel can be read about one at a time
    /// without the pill changing what it reports.
    var providers: [UsageSnapshot] = []
    var errors: [SourceID: String] = [:]
    var zones: [SourceID: ToneScale] = [:]

    /// Which provider is being read about, when it is not the pinned one.
    ///
    /// A view of the panel, not a setting: the pill goes on reporting whatever
    /// it was pinned to and nothing is written down. Held by the shell rather
    /// than here, because the control that changes it lives in the band around
    /// the notch, which is the shell's own row.
    @Binding var viewing: SourceID?
    /// Cross-source split — the only figure the per-source snapshot cannot hold.
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


    /// The provider every figure below belongs to.
    private var shown: UsageSnapshot? {
        providers.first { $0.source == viewing } ?? snapshot
    }

    /// The marks of the provider on screen, not of the pinned one: switching
    /// tabs switches the rule the figures are read by, as well as the figures.
    private var scale: ToneScale { shown.flatMap { zones[$0.source] } ?? toneScale }
    private var tone: Color { scale(shown?.sessionPercent) }
    private var panel: PanelData { shown?.panel ?? .empty }

    /// The complaint of the provider on screen, which is not always the pinned
    /// one any more.
    private var complaint: String? {
        shown.flatMap { errors[$0.source] } ?? (viewing == nil ? attention : nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if showsHeader {
                header
            }
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
            // Where the status line was. Three tabs spelled out took a row of
            // their own for a choice made once and then read: the name of the
            // provider on screen is the useful half, and the list only has to
            // exist while it is being changed.
            ProviderPicker(
                providers: providers, shown: shown?.source, zones: zones,
                onPick: { viewing = $0 == snapshot?.source ? nil : $0 }
            )
            if let complaint {
                AttentionBadge(message: complaint, size: 10)
            }
            Spacer(minLength: 12)
            // Collapse, not close: the panel goes back to the pill, which never
            // left. A cross says the thing is gone, and the arrows are the same
            // pair the card wears to open it, pointing the other way.
            Button(action: onClose) {
                Image(systemName: "arrow.down.right.and.arrow.up.left")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.42))
                    .frame(width: 18, height: 14)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .hoverChip()
            .accessibilityLabel("Collapse the panel")
            .help("Collapse the panel")
        }
        // Tall enough for the tabs that now ride in it, rather than the 20pt a
        // line of 9.5pt type needed on its own.
        .frame(height: 26)
        // The provider list drops out of this row over the sections below it.
        .zIndex(1)
    }


// MARK: - which provider is being read

    
    // MARK: - ring, weekly cap, sparkline

    private var summary: some View {
        HStack(alignment: .center, spacing: 24) {
            VStack(spacing: 12) {
                // The same mark, three times the size, with the figure under it
                // rather than inside it: only one of the twelve has a hole in the
                // middle to put a number in.
                MarkHero(
                    mark: mark, percent: shown?.sessionPercent,
                    isBurning: shown?.isBurning == true, scale: 3
                )
                .frame(height: 60)
                OdometerText(text: Format.percent(shown?.sessionPercent), size: 30, color: tone)
                Text(verbatim: Format.windowTag(shown?.windowMinutes))
                    .font(Typography.sans(8.5))
                    .tracking(0.34)
                    .foregroundStyle(.white.opacity(0.36))
                Text("Resets in \(Format.countdown(to: shown?.resetsAt))")
                    .font(Typography.sans(11.5))
                    .foregroundStyle(.white.opacity(0.6))
            }
            .frame(width: 152)

            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 7) {
                    captionRow(capLabel, weeklyCaption)
                    CapBar(
                        percent: shown?.weeklyPercent,
                        tone: toneScale(shown?.weeklyPercent),
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

    /// The longer window is a week on every plan but one: a workspace metered in
    /// credits has a month there, and calling it a weekly cap names the wrong
    /// fact about the figure beside it.
    ///
    /// Some accounts have no second window at all — an Enterprise workspace on a
    /// credit budget reports one limit and nothing else — and for those the row
    /// stays, so the panel keeps its height across providers, but it stops
    /// naming a cap the account does not have.
    private var capLabel: LocalizedStringKey {
        switch shown?.weeklyWindowMinutes {
        case 1_440: "Daily cap"
        case 43_200: "Monthly cap"
        case 525_600: "Annual cap"
        // Only once a reading has arrived. Before the first one every window is
        // absent, and that is "not known yet", not "does not exist".
        case nil where shown?.sessionPercent != nil: "No weekly cap"
        default: "Weekly cap"
        }
    }

    private var weeklyCaption: String {
        let percent = Format.percent(shown?.weeklyPercent)
        guard let resetsAt = shown?.weeklyResetsAt else { return percent }
        // A weekday says everything about a reset inside the week and nothing
        // about one three weeks out, which wants a date.
        let stamp = (shown?.weeklyWindowMinutes ?? 0) > 10_080
            ? Format.day(resetsAt)
            : Format.weekday(resetsAt)
        return String(
            localized: "\(percent) · resets \(stamp)",
            comment: "Longer cap's caption. Second value is a localized weekday or date."
        )
    }

    /// The sparkline's own span, not a figure derived from it: 26 five-minute
    /// buckets. A rate in tokens an hour used to sit here and said nothing a
    /// person could act on — the shape is the whole point of this row.
    ///
    /// Read off the buckets themselves rather than off `isActive`, which asks
    /// whether a five-hour window is open. A provider metered by the month never
    /// has one, so this row said "window empty" beside a month that was 42%
    /// spent — about the only thing it could not have meant.
    private var activityCaption: String {
        panel.sparkline.contains { $0 > 0 }
            ? String(localized: "last 2 hours")
            : String(localized: "nothing in 2 hours")
    }

    private func captionRow(_ label: LocalizedStringKey, _ value: String, tone: Color? = nil) -> some View {
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
            SplitColumn(title: "By kind", rows: panel.byKind)
        }
    }

    // MARK: - history and spend

    /// Takes whatever height the sections above leave, so the 30-day list fills
    /// the panel instead of scrolling inside a 118pt window with dead space below.
    private var footer: some View {
        HStack(alignment: .top, spacing: 26) {
            history.frame(maxWidth: .infinity, alignment: .leading)
            if let spend = shown?.spend {
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
            return String(localized: "No history yet")
        }
        return String(
            localized: "Last \(rows.count) days · busiest \(Format.day(peak.day))",
            comment: "History caption. Second value is a localized short date."
        )
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
    let title: LocalizedStringKey
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
                            .foregroundStyle(.white.opacity(0.6))
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

    private static let calendar = Calendar.current

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
        // Grouped once and handed down. Read straight off the computed property
        // it regrouped the whole range on every access, and `startsNewMonth`
        // asked for it twice per column — 2N + 2 groupings for one body pass.
        let weeks = self.weeks
        return HStack(alignment: .top, spacing: gap) {
            weekdayLabels
            VStack(alignment: .leading, spacing: 4) {
                monthLabels(weeks)
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
    private func monthLabels(_ weeks: [Week]) -> some View {
        HStack(spacing: gap) {
            ForEach(Array(weeks.enumerated()), id: \.element.id) { index, week in
                Text(startsNewMonth(index, in: weeks) ? week.id.formatted(.dateTime.month(.abbreviated)) : "")
                    .font(Typography.mono(9))
                    .foregroundStyle(.white.opacity(0.3))
                    .fixedSize()
                    .frame(width: cell, height: 11, alignment: .leading)
            }
        }
    }

    private func startsNewMonth(_ index: Int, in weeks: [Week]) -> Bool {
        guard index > 0 else { return true }
        return Self.calendar.component(.month, from: weeks[index].id)
            != Self.calendar.component(.month, from: weeks[index - 1].id)
    }

    private func weekdayName(_ row: Int) -> String {
        let index = (Self.calendar.firstWeekday - 1 + row) % 7
        return String(Self.calendar.shortWeekdaySymbols[index].prefix(3))
    }

    private func weekStart(of date: Date) -> Date {
        Self.calendar.dateInterval(of: .weekOfYear, for: date)?.start ?? date
    }

    private func row(of date: Date) -> Int {
        (Self.calendar.component(.weekday, from: date) - Self.calendar.firstWeekday + 7) % 7
    }
}

/// Only drawn for accounts that meter something beyond their windows: money
/// bought past the plan, or a workspace's monthly credit budget. The budget is
/// the account's own monthly limit, not a preference we invented.
private struct SpendCell: View {
    @Environment(\.tone) private var toneScale
    let spend: Spend

    /// Credits are the plan, not an overage bought on top of it, so calling them
    /// extra usage would be a straight lie about what the number is.
    private var title: LocalizedStringKey {
        spend.used.isCredits ? "Plan credits · month to date" : "Extra usage · month to date"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
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
                percent: spend.share,
                tone: toneScale(spend.share),
                height: 7, trackOpacity: 0.12
            )
            Text(Format.projection(used: spend.used))
                .font(Typography.mono(10.5))
                .foregroundStyle(.white.opacity(0.4))
        }
    }
}
