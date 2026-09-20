import Foundation

/// One row of a split — a name and its share of the slice, 0–100.
struct UsageSplit: Equatable, Sendable, Identifiable {
    let name: String
    let share: Double
    var id: String { name }
}

/// One calendar day of the history strip.
struct DayUsage: Equatable, Sendable, Identifiable {
    let day: Date
    let weighted: Double
    /// Share of the busiest day in range, 0–100. A daily cap does not exist —
    /// roughly five windows fit in a day — so the strip is relative, not absolute.
    let percent: Double
    var id: Date { day }
}

/// Everything the pinned panel draws that the headline figures don't already carry.
struct PanelData: Equatable, Sendable {
    /// Weighted tokens per 5-minute bucket, oldest first, scaled 0–1 against the
    /// tallest bucket. Ready to multiply by a bar height.
    var sparkline: [Double] = []
    var byModel: [UsageSplit] = []
    var byProject: [UsageSplit] = []
    /// What the window's weighted tokens were spent on, rather than who spent
    /// them. The only split that explains the figure above it: a cached read is
    /// a tenth of a fresh one, so the kind that is most of the raw traffic can
    /// be a sliver of the percentage.
    var byKind: [UsageSplit] = []
    var history: [DayUsage] = []

    static let empty = PanelData()
}

/// Folds raw events into the shapes the panel reads. Pure: no I/O, no `Date.now`.
///
/// The plan called for persisted 5-minute buckets; the store already retains 30
/// days of events in memory for exactly this range, so the buckets are computed
/// on the way past instead of being stored twice.
/// ponytail: one pass per refresh over ~10k events. Persist buckets when the
/// cold-start read is fixed, not before.
enum Aggregator {
    /// 26 bars, as the design draws.
    static let bucketCount = 26
    static let bucketSeconds: TimeInterval = 300
    /// The design's three rows per split.
    static let splitRows = 3
    /// A calendar grid makes a quarter legible in the space a week's list took.
    static let historyDays = 90

    static func panel(
        events: [UsageEvent],
        /// The span the splits describe. Not always a five-hour window: a
        /// workspace on a credit budget is metered by the month, and the three
        /// columns have to cover the same period as the figure above them.
        window: DateInterval?,
        at now: Date,
        weights: TokenWeights = .default,
        historyDays: Int = historyDays,
        calendar: Calendar = .current
    ) -> PanelData {
        // Splits describe the window on screen. With no window open there is
        // nothing to attribute, and last window's breakdown would be a lie.
        let inWindow = window.map { window in
            events.filter { $0.timestamp >= window.start && $0.timestamp < window.end }
        } ?? []

        return PanelData(
            sparkline: sparkline(events: events, at: now, weights: weights),
            byModel: shares(inWindow, weights: weights) { Self.displayModel($0.model) },
            byProject: shares(inWindow, weights: weights) { $0.project ?? "—" },
            byKind: mix(inWindow, weights: weights),
            history: history(events: events, at: now, days: historyDays,
                             weights: weights, calendar: calendar)
        )
    }

    /// The window split by kind of token.
    ///
    /// Not `shares`: every event carries all four kinds at once, so there is no
    /// key to group by. `reasoning` is left out on purpose — it is a subset of
    /// `output` in both CLIs, and a row for it would count the same tokens twice.
    static func mix(_ events: [UsageEvent], weights: TokenWeights = .default) -> [UsageSplit] {
        let counts = events.reduce(TokenCounts.zero) { $0 + $1.counts }
        let rows = [
            (String(localized: "Output"), Double(counts.output) * weights.output),
            (String(localized: "Input"), Double(counts.input) * weights.input),
            (String(localized: "Cache write"), Double(counts.cacheWrite) * weights.cacheWrite),
            (String(localized: "Cache read"), Double(counts.cacheRead) * weights.cacheRead),
        ]
        let sum = rows.reduce(0) { $0 + $1.1 }
        guard sum > 0 else { return [] }
        let spent = rows.filter { $0.1 > 0 }.sorted { $0.1 > $1.1 }
        return spent.map { UsageSplit(name: $0.0, share: $0.1 / sum * 100) }
    }

    static func sparkline(
        events: [UsageEvent], at now: Date, weights: TokenWeights = .default
    ) -> [Double] {
        var buckets = [Double](repeating: 0, count: bucketCount)
        let span = Double(bucketCount) * bucketSeconds
        for event in events {
            let age = now.timeIntervalSince(event.timestamp)
            guard age >= 0, age < span else { continue }
            // Index 0 is the oldest bucket, the last is the one in progress.
            let index = bucketCount - 1 - Int(age / bucketSeconds)
            buckets[index] += event.counts.weighted(weights)
        }
        guard let peak = buckets.max(), peak > 0 else { return buckets }
        return buckets.map { $0 / peak }
    }

    /// Top rows by weighted share. The tail is dropped rather than lumped into
    /// "other": three named rows is what the design has room for.
    static func shares(
        _ events: [UsageEvent],
        weights: TokenWeights = .default,
        limit: Int = splitRows,
        by key: (UsageEvent) -> String
    ) -> [UsageSplit] {
        var totals: [String: Double] = [:]
        for event in events {
            totals[key(event), default: 0] += event.counts.weighted(weights)
        }
        let sum = totals.values.reduce(0, +)
        guard sum > 0 else { return [] }
        // Spelled out in steps rather than one chain: map, sort, prefix and map
        // together are more than the type checker will solve in reasonable time
        // on a dictionary, and it gives up rather than slowing down.
        var rows: [UsageSplit] = totals.map {
            UsageSplit(name: $0.key, share: $0.value / sum * 100)
        }
        // Name breaks the tie so equal shares don't reorder on every refresh.
        rows.sort { $0.share == $1.share ? $0.name < $1.name : $0.share > $1.share }
        return Array(rows.prefix(limit))
    }

    static func history(
        events: [UsageEvent],
        at now: Date,
        days: Int,
        weights: TokenWeights = .default,
        calendar: Calendar = .current
    ) -> [DayUsage] {
        var totals: [Date: Double] = [:]
        for event in events {
            totals[calendar.startOfDay(for: event.timestamp), default: 0]
                += event.counts.weighted(weights)
        }
        let today = calendar.startOfDay(for: now)
        // Quiet days are rows too — a gap in the strip is information.
        let span = (0..<days).reversed().compactMap {
            calendar.date(byAdding: .day, value: -$0, to: today)
        }
        let peak = span.compactMap { totals[$0] }.max() ?? 0
        return span.map { day in
            let weighted = totals[day] ?? 0
            return DayUsage(
                day: day, weighted: weighted,
                percent: peak > 0 ? weighted / peak * 100 : 0
            )
        }
    }

    /// `claude-opus-5` → `Opus 5`. Anything that isn't a Claude model is left
    /// alone: guessing at another vendor's naming is how "Gpt 5.6 Terra" happens.
    static func displayModel(_ model: String?) -> String {
        guard let model, !model.isEmpty else { return "unknown" }
        guard model.hasPrefix("claude-") else { return model }
        return model
            .dropFirst("claude-".count)
            .split(separator: "-")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }
}
