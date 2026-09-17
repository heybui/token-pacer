import Foundation

/// Every string the UI shows a number in. One place, so the pill, the card and
/// the panel can never disagree about what "2h 04m" looks like.
enum Format {
    /// "2h 04m" — the design always shows both units.
    static func countdown(to date: Date?, from now: Date = Date()) -> String {
        guard let date else { return "--" }
        let minutes = max(0, Int(date.timeIntervalSince(now) / 60))
        return "\(minutes / 60)h \(String(format: "%02d", minutes % 60))m"
    }

    static func percent(_ value: Double?) -> String {
        value.map { "\(Int($0.rounded()))%" } ?? "--"
    }

    /// "Mon 09:00" — the weekly cap resets on a schedule, so name the day.
    static func weekday(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.abbreviated).hour(.twoDigits(amPM: .omitted)).minute())
    }

    /// "Sep 03" — one day of the history grid.
    static func day(_ date: Date) -> String {
        date.formatted(.dateTime.month(.abbreviated).day(.twoDigits))
    }

    /// The amount alone, at the currency's own precision. The code is shown once
    /// beside it rather than repeated on every figure, where a mono space makes
    /// "SGD  11,99" read as two separate numbers.
    static func amount(_ money: Money?) -> String {
        guard let money else { return "—" }
        return money.amount.formatted(.number.precision(.fractionLength(money.exponent)))
    }

    /// Straight-line: spend so far over the month elapsed. Says "projected"
    /// because a quiet week would make a liar of it.
    static func projection(used: Money?, now: Date = Date(), calendar: Calendar = .current) -> String {
        guard let used, used.amountMinor > 0,
              let month = calendar.range(of: .day, in: .month, for: now)
        else { return "no spend yet this month" }
        let elapsed = max(1, calendar.component(.day, from: now))
        var projected = used
        projected.amountMinor = Int(
            (Double(used.amountMinor) / Double(elapsed) * Double(month.count)).rounded()
        )
        return "projected \(amount(projected)) by month end"
    }

    /// The one thing burn has to say, and only when it is true: how long is left
    /// at this pace. Nil when the window does not run out, where a projection
    /// would only restate the countdown printed beside it.
    static func burn(_ burn: BurnRate) -> String? {
        burn.headroomMinutes.map { "~\($0) min headroom" }
    }

    /// What "Copy usage summary" puts on the clipboard: two lines, no jargon,
    /// pasteable straight into a message.
    static func usageSummary(_ snapshot: UsageSnapshot?, at now: Date = Date()) -> String {
        guard let snapshot else { return "Burn Tracker is still reading the logs." }
        let headline = snapshot.sessionPercent == nil
            ? "\(tokens(snapshot.sessionTokens)) tokens this window"
            : "\(percent(snapshot.sessionPercent)) of the 5-hour window"

        var second = ["Week \(percent(snapshot.weeklyPercent))"]
        if let burn = burn(snapshot.burn) { second.append(burn) }
        if snapshot.origin == .inferred { second.append("estimated") }

        return """
            \(snapshot.source.displayName) · \(headline), resets in \(countdown(to: snapshot.resetsAt, from: now))
            \(second.joined(separator: " · "))
            """
    }

    /// Shown instead of a percentage until a ceiling has been observed.
    static func tokens(_ count: Int) -> String {
        switch count {
        case 1_000_000...: String(format: "%.2fM", Double(count) / 1_000_000)
        case 1_000...: String(format: "%.0fK", Double(count) / 1_000)
        default: "\(count)"
        }
    }
}
