import Foundation

/// One 5-hour billing block.
struct SessionWindow: Equatable, Sendable {
    let start: Date
    let end: Date
    var counts: TokenCounts
    var weighted: Double
    var lastActivity: Date

    func isActive(at now: Date) -> Bool { now >= start && now < end }
}

/// Groups events into the 5-hour blocks the CLIs bill against.
///
/// The rule follows ccusage: a block opens on the first event after a gap of at
/// least one window length, and its start is floored to the hour — which is why
/// a block can end sooner than 5 hours after its first event.
enum WindowCalculator {
    static let fiveHours: TimeInterval = 5 * 3600

    static func windows(
        from events: [UsageEvent],
        length: TimeInterval = fiveHours,
        weights: TokenWeights = .default,
        calendar: Calendar = .current
    ) -> [SessionWindow] {
        var windows: [SessionWindow] = []

        for event in events.sorted(by: { $0.timestamp < $1.timestamp }) {
            let fitsCurrent = windows.last.map { current in
                event.timestamp < current.end
                    && event.timestamp.timeIntervalSince(current.lastActivity) < length
            } ?? false

            if fitsCurrent {
                windows[windows.count - 1].counts += event.counts
                windows[windows.count - 1].weighted += event.counts.weighted(weights)
                windows[windows.count - 1].lastActivity = event.timestamp
            } else {
                let start = floorToHour(event.timestamp, calendar: calendar)
                windows.append(SessionWindow(
                    start: start,
                    end: start.addingTimeInterval(length),
                    counts: event.counts,
                    weighted: event.counts.weighted(weights),
                    lastActivity: event.timestamp
                ))
            }
        }
        return windows
    }

    static func floorToHour(_ date: Date, calendar: Calendar = .current) -> Date {
        calendar.date(from: calendar.dateComponents([.year, .month, .day, .hour], from: date)) ?? date
    }

    /// The block currently burning, if any.
    static func current(in windows: [SessionWindow], at now: Date) -> SessionWindow? {
        windows.last.flatMap { $0.isActive(at: now) ? $0 : nil }
    }
}
