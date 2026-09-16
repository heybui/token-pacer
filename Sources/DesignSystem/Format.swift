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

    /// Weekday over a week, where every name is distinct; the date itself over a
    /// month, where seven repeating weekday names would tell you nothing.
    static func historyLabel(_ day: Date, compact: Bool) -> String {
        compact
            ? day.formatted(.dateTime.weekday(.abbreviated))
            : day.formatted(.dateTime.month(.abbreviated).day(.twoDigits))
    }

    /// The design's ten-block bar, drawn in monospace text rather than geometry.
    static func blocks(_ percent: Double, count: Int = 10) -> String {
        let filled = min(count, max(0, Int((percent / 100 * Double(count)).rounded())))
        return String(repeating: "█", count: filled)
            + String(repeating: "░", count: count - filled)
    }

    static func dollars(_ value: Double?) -> String {
        value.map { "$\(Int($0.rounded()))" } ?? "—"
    }

    /// Straight-line: spend so far over the month elapsed. Says "projected"
    /// because a quiet week would make a liar of it.
    static func projection(used: Double?, now: Date = Date(), calendar: Calendar = .current) -> String {
        guard let used, used > 0,
              let month = calendar.range(of: .day, in: .month, for: now)
        else { return "no spend yet this month" }
        let elapsed = max(1, calendar.component(.day, from: now))
        let projected = used / Double(elapsed) * Double(month.count)
        return "projected \(dollars(projected)) by month end"
    }

    /// What "Copy usage summary" puts on the clipboard: two lines, no jargon,
    /// pasteable straight into a message.
    static func usageSummary(_ snapshot: UsageSnapshot?, at now: Date = Date()) -> String {
        guard let snapshot else { return "Burn Tracker is still reading the logs." }
        let headline = snapshot.sessionPercent == nil
            ? "\(tokens(snapshot.sessionTokens)) tokens this window"
            : "\(percent(snapshot.sessionPercent)) of the 5-hour window"

        var second = ["Week \(percent(snapshot.weeklyPercent))"]
        if let rate = snapshot.burn.percentPerHour, rate > 0 {
            second.append("\(Int(rate.rounded()))%/hr")
        }
        if let headroom = snapshot.burn.headroomMinutes {
            second.append("~\(headroom) min headroom")
        }
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
