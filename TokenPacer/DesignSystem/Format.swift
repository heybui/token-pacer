import Foundation

/// Every string the UI shows a number in. One place, so the pill, the card and
/// the panel can never disagree about what "2h 04m" looks like.
enum Format {
    /// "2h 04m" — the design always shows both units. Past a day it switches to
    /// "4d 11h": a weekly window has 150 hours in it, and nobody reads that as a
    /// duration.
    static func countdown(to date: Date?, from now: Date = Date.now) -> String {
        guard let date else { return "--" }
        let minutes = max(0, Int(date.timeIntervalSince(now) / 60))
        let hours = minutes / 60
        if hours >= 24 {
            return String(
                localized: "\(hours / 24)d \(hours % 24)h",
                comment: "Countdown past a day. Two unit letters only: monospaced column, no room."
            )
        }
        return String(
            localized: "\(hours)h \((minutes % 60).formatted(.number.precision(.integerLength(2))))m",
            comment: "Countdown under a day. Keep the two-digit minute padding: monospaced column."
        )
    }

    /// The window a figure belongs to, as the captions name it: "this 5-hour
    /// window", "this week", "this month".
    ///
    /// The app used to write "5-hour" into the copy as a constant, because every
    /// account had one. A workspace metered in credits has a month where a plan
    /// has five hours, and a caption that insists otherwise is simply wrong
    /// about the number it is pointing at.
    static func windowName(_ minutes: Int?) -> String {
        switch minutes {
        case 300: String(localized: "5-hour window")
        case 1_440: String(localized: "day")
        case 10_080: String(localized: "week")
        case 43_200: String(localized: "month")
        case 525_600: String(localized: "year")
        default: String(localized: "window")
        }
    }

    /// The same window as a column tag, where a sentence does not fit: the
    /// panel's headline and the row labels that sit above a figure.
    static func windowTag(_ minutes: Int?) -> String {
        switch minutes {
        case 300: String(localized: "5-HOUR")
        case 1_440: String(localized: "DAILY")
        case 10_080: String(localized: "WEEKLY")
        case 43_200: String(localized: "MONTHLY")
        case 525_600: String(localized: "ANNUAL")
        default: String(localized: "WINDOW")
        }
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
    static func projection(used: Money?, now: Date = Date.now, calendar: Calendar = .current) -> String {
        guard let used, used.amountMinor > 0,
              let month = calendar.range(of: .day, in: .month, for: now)
        else { return String(localized: "no spend yet this month") }
        let elapsed = max(1, calendar.component(.day, from: now))
        var projected = used
        projected.amountMinor = Int(
            (Double(used.amountMinor) / Double(elapsed) * Double(month.count)).rounded()
        )
        return String(
            localized: "projected \(amount(projected)) by month end",
            comment: "Straight-line forecast of this month's extra spend."
        )
    }

    /// Volume, for `--probe` and the splits — never as a headline, which is a
    /// percentage in every case.
    static func tokens(_ count: Int) -> String {
        switch count {
        case 1_000_000...: String(format: "%.2fM", Double(count) / 1_000_000)
        case 1_000...: String(format: "%.0fK", Double(count) / 1_000)
        default: "\(count)"
        }
    }
}
