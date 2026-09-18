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

    /// Volume, where a percentage is not the question: the tokens a window has
    /// taken, before any reading lands.
    static func tokens(_ count: Int) -> String {
        switch count {
        case 1_000_000...: String(format: "%.2fM", Double(count) / 1_000_000)
        case 1_000...: String(format: "%.0fK", Double(count) / 1_000)
        default: "\(count)"
        }
    }
}
