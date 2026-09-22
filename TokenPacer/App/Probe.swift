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
                .codex: CodexUsagePanel(read: CodexAppServer.reader()),
                .copilot: CopilotUsagePanel(read: CopilotAppServer.reader()),
            ]
        )
        await store.refresh()
        // The reading is launched, not awaited, so the first refresh only starts
        // the CLI. Wait for it, then refresh again to fold it into the snapshot.
        // Copilot's CLI boots for ~12s and asks GitHub for the budget after
        // that, so the slowest panel sets this, not the fastest.
        let deadline = Date.now.addingTimeInterval(90)
        while await store.isReadingLimits, Date.now < deadline {
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

    /// `TokenPacer --raw` — what each provider actually said, verbatim.
    ///
    /// `--probe` prints what the parsers made of those replies, which is the
    /// wrong half when a parser is the thing in doubt: limits that come back in
    /// a shape this app has no field for read as no data at all, and say
    /// nothing about which field moved. Codex and Copilot answer in JSON;
    /// Claude's is a screen render, ANSI and all, which is the same evidence
    /// `TOKENPACER_PANEL_DUMP` writes to a file during a normal run.
    ///
    /// All three at once, because Claude's CLI takes the better part of a
    /// minute to draw its panel and there is no reason to spend that twice.
    static func raw() async { print(await rawReport()) }

    /// The same report as text, for the window that shows it.
    ///
    /// Which build it came from goes at the top: a reply pasted into an issue
    /// says nothing about which parser read it, and that is the half being
    /// doubted.
    static func rawReport() async -> String {
        async let claude = text(from: TerminalCLI.reader(.claude))
        async let codex = text(from: CodexAppServer.reader())
        async let copilot = text(from: CopilotAppServer.reader())

        let sections = await [
            (SourceID.claude, claude), (.codex, codex), (.copilot, copilot),
        ].map { "--- \($0.displayName)\n\(printable($1))\n" }

        return redacted(
            "\(AppInfo.name) \(AppInfo.versionLine)\n\n" + sections.joined(separator: "\n")
        )
    }

    /// What the report is not allowed to carry out of the machine.
    ///
    /// Codex names the account id on every read, and any path through `$HOME`
    /// spells out the login name. The report exists to be pasted into an issue,
    /// so both go before it can reach a clipboard rather than being something
    /// the person pasting has to remember to check.
    private static func redacted(_ report: String) -> String {
        report
            .replacingOccurrences(
                of: #""accountId":"[^"]*""#, with: #""accountId":"…""#,
                options: .regularExpression
            )
            // And the account this Mac is logged into: a path is a name.
            .replacing(FileManager.default.homeDirectoryForCurrentUser.path(), with: "~/")
    }

    /// A terminal render cannot be echoed back into a terminal.
    ///
    /// Claude's reply is a screen, and a screen is escape sequences: an OSC
    /// title, an alternate buffer, a hidden cursor. Printed verbatim the shell
    /// they ran this in *executes* them and is left sitting in whatever state
    /// the last one asked for, which is the bug report that arrives as "the
    /// terminal went weird". `normalize` is also exactly the string the parsers
    /// see, so it is the render's useful half either way. JSON carries no
    /// escapes and is left alone.
    private static func printable(_ reply: String) -> String {
        reply.contains("\u{1B}") ? panel(in: PanelText.normalize(reply)) : reply
    }

    /// The figures out of the screen they were drawn on.
    ///
    /// A render is everything the CLI had on display, and the figures are a
    /// band in the middle of it. Above them is the banner — the directory the
    /// CLI was started in, the branch, the project's own slash commands, every
    /// skill and MCP server installed. Below them is the attribution
    /// breakdown, which names the skills and servers the work actually went
    /// through. Neither says anything about why a number failed to parse, and
    /// both are a description of what somebody is working on, in a file whose
    /// whole purpose is to be sent to someone else.
    ///
    /// So the band is cut out: from the first figure the parser reads to the
    /// heading after the last one. When the first marker is missing the panel
    /// never drew at all, which is the failure worth reporting — the tail goes
    /// out whole rather than nothing.
    private static func panel(in text: String) -> String {
        guard let first = text.range(of: "Current session")
            ?? text.range(of: "Currentsession")
        else { return String(text.suffix(1_500)) }

        // Spaces in a render are cursor jumps as often as characters, so every
        // marker is offered with and without them.
        let body = text[first.lowerBound...]
        let breakdown = ["Last 24h", "Last24h", "24h", "Skills%", "Skills %", "MCPservers"]
            .compactMap { body.range(of: $0)?.lowerBound }
            .min()
        return String(body[..<(breakdown ?? body.endIndex)])
    }

    /// A failed read is evidence too — the error belongs under its own heading
    /// rather than ending the run and taking the other two with it.
    private static func text(from read: PanelReader) async -> String {
        do { return try await read() } catch { return "unreadable: \(error)" }
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
