import Foundation

/// `BurnTracker --probe` — read the real logs once and print what the engine makes
/// of them. The phase 1 deliverable, and the fastest way to check a parser against
/// a live machine without launching any UI.
enum Probe {
    static func run() async {
        let store = await UsageStore()
        await store.refresh()

        for id in SourceID.allCases {
            guard let s = await store.snapshots[id] else {
                print("\(id.displayName): no data")
                continue
            }
            let percent = s.sessionPercent.map { String(format: "%.1f%%", $0) }
                ?? "— (\(s.sessionTokens) tokens, ceiling not yet observed)"
            let ceiling = await store.ceilings[id] ?? .unknown
            print("""
            \(id.displayName)
              session   \(percent)   [\(s.origin)]
              tokens    \(s.sessionTokens)
              resets    \(s.resetsAt.map(format) ?? "—")
              weekly    \(s.weeklyPercent.map { String(format: "%.1f%%", $0) } ?? "—")
              burn      \(Int(s.burn.weightedPerHour)) weighted/hr\
            \(s.burn.headroomMinutes.map { ", ~\($0) min headroom" } ?? "")
              active    \(s.isActive)   plan \(s.planType ?? "—")
              events    \(await store.eventCount(id)) in 30d, last \(s.lastActivity.map(format) ?? "—")
              ceiling   \(ceiling.weightedTokens.map { String(format: "%.0f", $0) } ?? "unknown") weighted over \(ceiling.observedWindows) completed windows
            """)
        }
        for (id, message) in await store.errors {
            print("error \(id.rawValue): \(message)")
        }
    }

    private static func format(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }
}
