import AppKit
import Foundation

/// `TokenPacer --probe` — read the real logs once and print what the engine makes
/// of them. The phase 1 deliverable, and the fastest way to check a parser against
/// a live machine without launching any UI.
enum Probe {
    static func run() async {
        let store = await UsageStore(
            panels: [
                .claude: ClaudeUsagePanel(read: TerminalCLI.reader(.claude)),
                .codex: CodexStatusPanel(read: TerminalCLI.reader(.codex)),
                .copilot: CopilotUsagePanel(read: TerminalCLI.reader(.copilot)),
            ]
        )
        await store.refresh()
        // The reading is launched, not awaited, so the first refresh only starts
        // the CLI. Wait for it, then refresh again to fold it into the snapshot.
        // Copilot's CLI boots for ~12s and asks GitHub for the budget after
        // that, so the slowest panel sets this, not the fastest.
        let deadline = Date().addingTimeInterval(90)
        while await store.isReadingLimits, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(200))
        }
        await store.refresh()

        for id in SourceID.allCases {
            guard let s = await store.snapshots[id] else {
                print("\(id.displayName): no data")
                continue
            }
            let percent = s.sessionPercent.map { String(format: "%.1f%%", $0) }
                ?? "— (not reported; \(s.sessionTokens) tokens logged)"
            print("""
            \(id.displayName)
              session   \(percent)
              tokens    \(s.sessionTokens)
              resets    \(s.resetsAt.map(format) ?? "—")
              weekly    \(s.weeklyPercent.map { String(format: "%.1f%%", $0) } ?? "—")
              active    \(s.isActive)   plan \(s.planType ?? "—")
              events    \(await store.eventCount(id)) in 30d, last \(s.lastActivity.map(format) ?? "—")
            """)
        }
        for (id, message) in await store.errors {
            print("error \(id.rawValue): \(message)")
        }
        await MainActor.run { screens() }
    }

    /// What the anchor reads off every attached display, and the shell each one
    /// would get. The figures differ by model, by scaling and by display, so a
    /// report of "it looks wrong on my monitor" is unanswerable without them.
    @MainActor
    static func screens() {
        let all = NSScreen.screens.map(\.metrics)
        let chosen = NotchAnchor.preferred(from: all, main: NSScreen.main?.metrics)
        for (screen, m) in zip(NSScreen.screens, all) {
            let band = NotchAnchor.band(m)
            let collapsed = PillState.collapsed.size(around: band)
            print("""
            screen    \(screen.localizedName)\(m == chosen ? "   <- the pill docks here" : "")
              frame     \(Int(m.frame.width))x\(Int(m.frame.height)) at \(Int(m.frame.minX)),\(Int(m.frame.minY)) @\(screen.backingScaleFactor)x
              safeArea  top \(m.safeAreaTop)
              aux       L \(m.auxiliaryTopLeft.map { "\(Int($0.width))" } ?? "nil") \
            R \(m.auxiliaryTopRight.map { "\(Int($0.width))" } ?? "nil")
              menuBar   \(m.menuBarHeight)
              band      \(band.isEmpty ? "none" : "notch \(Int(band.notchWidth)) wide, row \(Int(band.height)) tall")
              collapsed \(Int(collapsed.width))x\(Int(collapsed.height)) \
            (board \(Int(PillState.collapsed.size.width))x\(Int(PillState.collapsed.size.height)))
            """)
        }
    }

    private static func format(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }
}
