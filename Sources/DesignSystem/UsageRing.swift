import SwiftUI

/// The donut that mirrors the percentage. Butt caps, not round: the design's ring
/// is a filled arc, not a progress bar bent into a circle.
struct UsageRing: View {
    let percent: Double?
    let tone: Color
    var size: CGFloat
    var lineWidth: CGFloat
    /// Sits in the ring's hole. The design carries it on every ring big enough to
    /// hold it — the 17px pill ring is not, so its figure sits alongside instead.
    var label: String?
    var labelSize: CGFloat = 11

    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.14), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: (percent ?? 0) / 100)
                .stroke(tone, style: StrokeStyle(lineWidth: lineWidth, lineCap: .butt))
                .rotationEffect(.degrees(-90))
            if let label {
                OdometerText(text: label, size: labelSize, color: tone)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)   // "8.00M" is wider than "45%"
                    .frame(width: size - lineWidth * 2 - 4)
            }
        }
        .frame(width: size, height: size)
        .animation(.easeOut(duration: 0.6), value: percent ?? -1)
    }
}

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

    /// Weekday for the 7-day strip, countdown-style for the 30-day one, where
    /// seven repeating weekday names would tell you nothing.
    static func historyLabel(_ day: Date, compact: Bool, from now: Date = Date(),
                             calendar: Calendar = .current) -> String {
        if compact { return day.formatted(.dateTime.weekday(.abbreviated)) }
        let days = calendar.dateComponents(
            [.day], from: calendar.startOfDay(for: day), to: calendar.startOfDay(for: now)
        ).day ?? 0
        return days == 0 ? "today" : "D-\(String(format: "%02d", days))"
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

    /// Shown instead of a percentage until a ceiling has been observed.
    static func tokens(_ count: Int) -> String {
        switch count {
        case 1_000_000...: String(format: "%.2fM", Double(count) / 1_000_000)
        case 1_000...: String(format: "%.0fK", Double(count) / 1_000)
        default: "\(count)"
        }
    }
}
