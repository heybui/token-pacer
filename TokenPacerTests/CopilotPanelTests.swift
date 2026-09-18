import Foundation
import Testing
@testable import TokenPacer

/// Verbatim from a live `/usage` run on GitHub Copilot CLI 1.0.86 — the bar
/// wedged between the label and the number, and a cursor jump where the space
/// before `7,074` should be.
private let panel = """
   Changes    \u{1B}[32m+0\u{1B}[m \u{1B}[31m-0\r
\u{1B}[3C\u{1B}[mAI Credits 0 (24s)\r
   Plan\u{1B}[7C\u{1B}[34m■■■■■■■■\u{1B}[m■■■■■■■■■■■■ 39% used\u{1B}[31;15H7,074 / 18,000 AIC
"""

private let now = Date()
private let calendar = Calendar.current

@Test func thePlanRowIsReadAsUsedOfBudget() throws {
    let limits = try #require(CopilotUsagePanel.parse(panel, now: now))
    #expect(limits.primary?.usedPercent == 39)
    #expect(limits.primary?.windowMinutes == CopilotUsagePanel.planWindowMinutes)
    #expect(limits.spend?.used == Money(amountMinor: 7074, currency: "AIC", exponent: 0))
    #expect(limits.spend?.limit == Money(amountMinor: 18000, currency: "AIC", exponent: 0))
}

/// The one thing that makes Copilot a different shape: a budget, and no window
/// under it. A figure invented for `secondary` would read as a weekly cap.
@Test func copilotHasNoSecondWindow() throws {
    let limits = try #require(CopilotUsagePanel.parse(panel, now: now))
    #expect(limits.secondary == nil)
}

/// `AI Credits 0 (24s)` is what this conversation has spent, not what the plan
/// has. Only the row after `Plan` counts.
@Test func theSessionFigureIsNotMistakenForTheBudget() {
    #expect(CopilotUsagePanel.parse(
        "   Changes +0 -0\r\n AI Credits 0 (24s)\r\n", now: now
    ) == nil)
}

/// Nothing in the panel says which day the budget renews on, so the reset is the
/// month boundary — an approximation the parser owns rather than one the pill
/// invents from a window length.
@Test func theResetIsTheStartOfNextMonth() throws {
    let limits = try #require(CopilotUsagePanel.parse(panel, now: now))
    let reset = try #require(limits.primary?.resetsAt)

    #expect(reset > now)
    #expect(calendar.component(.day, from: reset) == 1)
    #expect(calendar.component(.hour, from: reset) == 0)
    let months = calendar.dateComponents([.month], from: now, to: reset).month ?? -1
    #expect(months <= 1)
}

@Test func aSignInPromptIsToldApartFromAnUnreadableCopilotPanel() async {
    let signIn = CopilotUsagePanel { "Not signed in. Run copilot login to continue" }
    await #expect(throws: PanelError.notSignedIn) { try await signIn.fetch(now: now) }

    let garbage = CopilotUsagePanel { "\u{1B}[2Jnothing here" }
    await #expect(throws: PanelError.unreadable) { try await garbage.fetch(now: now) }
}

/// `CLAUDE_CONFIG_DIR`, `CODEX_HOME` and `COPILOT_HOME` all move an agent's
/// store, and a tracker that reads the default anyway reports an idle machine.
@Test func anAgentHomeFollowsItsOwnEnvironmentVariable() {
    let home = FileManager.default.homeDirectoryForCurrentUser
    // Whatever this machine is set to, the defaults are what the names say.
    if ProcessInfo.processInfo.environment["COPILOT_HOME"] == nil {
        #expect(AgentHome.copilot == home.appending(path: ".copilot"))
    }
    if ProcessInfo.processInfo.environment["CODEX_HOME"] == nil {
        #expect(AgentHome.codex == home.appending(path: ".codex"))
    }
    // Claude's trust file is offered from the configuration home first and from
    // beside it second, because a default install keeps it in `$HOME`.
    #expect(AgentHome.claudeConfigFiles.count == 2)
    #expect(AgentHome.claudeConfigFiles.allSatisfy { $0.lastPathComponent == ".claude.json" })
}
