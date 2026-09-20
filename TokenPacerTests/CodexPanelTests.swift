import Foundation
import Testing
@testable import TokenPacer

/// Verbatim from a live `/status` run on Codex 0.155, box frame and all — down
/// to the bar being wedged between the label and the number, and the dim/bright
/// escapes that split `100% left` away from the `(resets …)` beside it.
private let panel = """
\u{1B}[2m│  Account:              someone@example.com (Plus)          │\u{1B}[0m\r
\u{1B}[2m│  5h limit:             \u{1B}[22m[████████████████████] 100% left\u{1B}[2m (resets 03:59 on 19 Sep)    │\u{1B}[0m\r
\u{1B}[2m│  Weekly limit:         \u{1B}[22m[█████████░░░░░░░░░░░] 43% left\u{1B}[2m (resets 15:23 on 19 Sep)     │\u{1B}[0m\r
"""

/// The same screen with the cursor jumps that stood in for its spaces gone.
private let welded = """
Account:someone@example.com(Plus) 5hlimit: 88%left(resets03:59on19Sep) Weeklylimit: 43%left(resets15:23)
"""

private let now = Date()
private let calendar = Calendar.current

@Test func whatIsLeftIsReadAsWhatIsUsed() throws {
    let limits = try #require(CodexStatusPanel.parse(panel, now: now))
    #expect(limits.primary?.usedPercent == 0)             // 100% left
    #expect(limits.primary?.windowMinutes == 300)
    #expect(limits.secondary?.usedPercent == 57)          // 43% left
    #expect(limits.secondary?.windowMinutes == 10_080)
}

@Test func thePlanIsTakenFromTheAccountRowAndTheAddressIsNot() throws {
    let limits = try #require(CodexStatusPanel.parse(panel, now: now))
    #expect(limits.planType == "Plus")
}

@Test func aCodexRenderWithItsSpacesEatenStillParses() throws {
    let limits = try #require(CodexStatusPanel.parse(welded, now: now))
    #expect(limits.primary?.usedPercent == 12)
    #expect(limits.secondary?.usedPercent == 57)
    #expect(limits.planType == "Plus")
}

/// `03:59 on 19 Sep`: local, 24-hour, no year — the next such moment.
@Test func aDatedResetLandsOnTheNextOne() throws {
    let limits = try #require(CodexStatusPanel.parse(panel, now: now))
    let reset = try #require(limits.primary?.resetsAt)

    #expect(reset > now)
    #expect(calendar.component(.day, from: reset) == 19)
    #expect(calendar.component(.month, from: reset) == 9)
    #expect(calendar.component(.hour, from: reset) == 3)
    #expect(calendar.component(.minute, from: reset) == 59)
}

/// A reset inside the day is printed without one.
@Test func aDatelessResetRollsByDayNotByYear() throws {
    let limits = try #require(CodexStatusPanel.parse(welded, now: now))
    let weekly = try #require(limits.secondary?.resetsAt)

    #expect(weekly > now)
    #expect(weekly < now.addingTimeInterval(25 * 3600))
    #expect(calendar.component(.hour, from: weekly) == 15)
    #expect(calendar.component(.minute, from: weekly) == 23)
}

/// The TUI draws `5h 100% left · weekly 43%` in its status line before anything
/// is asked of it, and the user can switch what it carries. Only the panel's own
/// `5h limit:` row counts.
@Test func theStatusLineSummaryIsNotMistakenForThePanel() {
    #expect(CodexStatusPanel.parse(
        "gpt-5.6-terra high · ~/code/thing · main · 5h 100% left · weekly 43…", now: now
    ) == nil)
}

/// A row that cannot be read is not an empty reading: every signed-in account
/// has a 5-hour window.
@Test func anUnreadablePanelIsToldApartFromASignInPrompt() async {
    let signIn = CodexStatusPanel { "Not signed in. Run codex login to continue" }
    await #expect(throws: PanelError.notSignedIn) { try await signIn.fetch(now: now) }

    let garbage = CodexStatusPanel { "\u{1B}[2Jnothing here" }
    await #expect(throws: PanelError.unreadable) { try await garbage.fetch(now: now) }
}

/// A reading that came from a rollout log beats one from a panel run a minute
/// earlier, and loses to one a minute later. Codex writes both.
@MainActor
@Test func theNewerOfTwoReadingsWins() {
    let old = RateLimits(primary: nil, secondary: nil, planType: "old",
                         observedAt: now.addingTimeInterval(-60))
    let new = RateLimits(primary: nil, secondary: nil, planType: "new", observedAt: now)

    #expect(UsageStore.newer(old, new)?.planType == "new")
    #expect(UsageStore.newer(new, old)?.planType == "new")
    #expect(UsageStore.newer(nil, old)?.planType == "old")
    #expect(UsageStore.newer(nil, nil) == nil)
}

/// An Enterprise workspace metered in credits, verbatim from a customer's own
/// `/status` on the same 0.155.1: no `5h limit:` row exists to find, because a
/// credit budget is the only limit the account has.
private let creditPanel = """
\u{1B}[2m│  Account:              someone@example.com (Enterprise)   │\u{1B}[0m\r
\u{1B}[2m│  Collaboration mode:   Default                            │\u{1B}[0m\r
\u{1B}[2m│  Credits:              Available                          │\u{1B}[0m\r
\u{1B}[2m│  Monthly credit limit: \u{1B}[22m[███████████████████░] 97% left\u{1B}[2m (resets 07:00 on 1 Oct)  │\u{1B}[0m\r
\u{1B}[2m│                        1,181 of 40,000 credits used       │\u{1B}[0m\r
\u{1B}[2m│  Thread usage:         0 credits · ~$0.00                  │\u{1B}[0m\r
"""

@Test func aCreditBudgetIsReadAsTheAccountsOnlyWindow() throws {
    let limits = try #require(CodexStatusPanel.parse(creditPanel, now: now))

    // The ratio, not the rounded `97% left`: 1,181 of 40,000 is 2.95%, and the
    // whole-percent figure beside it is 400 credits coarser.
    let used = try #require(limits.primary?.usedPercent)
    #expect(abs(used - 2.9525) < 0.0001)
    #expect(limits.primary?.windowMinutes == CodexStatusPanel.monthlyWindowMinutes)
    #expect(limits.secondary == nil)
    #expect(limits.planType == "Enterprise")
}

@Test func theCreditBudgetItselfIsCarriedAsSpend() throws {
    let spend = try #require(CodexStatusPanel.parse(creditPanel, now: now)?.spend)

    #expect(spend.used.amountMinor == 1_181)
    #expect(spend.limit?.amountMinor == 40_000)
    #expect(spend.used.isCredits)
    #expect(spend.used.exponent == 0)
    // `Thread usage: 0 credits` sits right underneath and is this session's
    // share, not a budget. Taking it would zero the figure on every read.
    #expect(spend.used.amountMinor != 0)
}

/// `resets 07:00 on 1 Oct`, a month out rather than hours.
@Test func aMonthlyCreditResetLandsOnTheFirst() throws {
    let reset = try #require(CodexStatusPanel.parse(creditPanel, now: now)?.primary?.resetsAt)

    #expect(reset > now)
    #expect(calendar.component(.day, from: reset) == 1)
    #expect(calendar.component(.month, from: reset) == 10)
    #expect(calendar.component(.hour, from: reset) == 7)
}

/// A workspace that has both: the credit line belongs to the credit row alone,
/// and the 5-hour row keeps its own figure however close together they render.
@Test func aCreditLineIsNotReadAsTheRowAboveIt() throws {
    let mixed = """
    5h limit: [████] 94% left (resets 07:51) \
    Weekly limit: [███] 80% left (resets 15:23) \
    Monthly credit limit: [███] 97% left (resets 07:00 on 1 Oct) 1,181 of 40,000 credits used
    """
    let limits = try #require(CodexStatusPanel.parse(mixed, now: now))

    #expect(limits.primary?.usedPercent == 6)
    #expect(limits.primary?.windowMinutes == 300)
    #expect(limits.secondary?.usedPercent == 20)
    #expect(limits.spend?.used.amountMinor == 1_181)
}
