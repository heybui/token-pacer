import Foundation
import Testing
@testable import TokenPacer

/// Shaped after a live `account.getQuota` reply from GitHub Copilot CLI 1.0.86,
/// with the figures moved off zero. An account metered in AI credits carries its
/// allowance on `chat`; `premium_interactions` is present and flagged as having
/// no quota at all.
private func reply(
    used: Double = 45, entitlement: Double = 200, remaining: Double = 77.5,
    resetDate: String = "2026-09-21T08:06:24.358Z"
) -> String {
    """
    {"jsonrpc":"2.0","id":2,"result":{"quotaSnapshots":{
      "chat":{"isUnlimitedEntitlement":false,"entitlementRequests":\(entitlement),
        "usedRequests":\(used),"usageAllowedWithExhaustedQuota":false,"overage":0,
        "overageAllowedWithExhaustedQuota":false,"remainingPercentage":\(remaining),
        "resetDate":"\(resetDate)","hasQuota":true,"tokenBasedBilling":true},
      "completions":{"isUnlimitedEntitlement":true,"entitlementRequests":-1,
        "usedRequests":0,"remainingPercentage":100,"hasQuota":true,
        "resetDate":"\(resetDate)","tokenBasedBilling":true},
      "premium_interactions":{"isUnlimitedEntitlement":false,"entitlementRequests":0,
        "usedRequests":0,"remainingPercentage":0,"resetDate":"\(resetDate)",
        "hasQuota":false,"tokenBasedBilling":true}}}}
    """
}

private let now = Date()
private let calendar = Calendar.current

@Test func theMeteredQuotaIsReadAsUsedOfEntitlement() throws {
    let limits = try #require(CopilotUsagePanel.parse(reply(), now: now))
    #expect(limits.primary?.usedPercent == 22.5)
    #expect(limits.primary?.windowMinutes == CopilotUsagePanel.planWindowMinutes)
    #expect(limits.spend?.used == Money(amountMinor: 45, currency: "AIC", exponent: 0))
    #expect(limits.spend?.limit == Money(amountMinor: 200, currency: "AIC", exponent: 0))
    // The reply states the share itself, so the bar fills from that rather than
    // from the pair's own division.
    #expect(limits.spend?.percent == 22.5)
}

/// `premium_interactions` comes first when it is the metered one, and is stepped
/// over when it says `hasQuota: false` — as it does on a credit-billed account,
/// where reading it would report a plan 0 requests wide.
@Test func anUnmeteredQuotaIsNotMistakenForTheBudget() throws {
    let premium = """
    {"result":{"quotaSnapshots":{
      "chat":{"isUnlimitedEntitlement":true,"entitlementRequests":-1,"usedRequests":0,
        "remainingPercentage":100,"hasQuota":true,"tokenBasedBilling":false},
      "premium_interactions":{"isUnlimitedEntitlement":false,"entitlementRequests":300,
        "usedRequests":90,"remainingPercentage":70,"hasQuota":true,
        "tokenBasedBilling":false}}}}
    """
    let limits = try #require(CopilotUsagePanel.parse(premium, now: now))
    #expect(limits.primary?.usedPercent == 30)
    // Requests, not credits: only a token-billed account is metered in AIC.
    #expect(limits.spend?.used == Money(amountMinor: 90, currency: "REQUESTS", exponent: 0))
}

/// Verbatim from a live business seat: 18,000 premium requests granted, 7,686
/// spent — and `hasQuota: false` on the only quota that has a budget at all.
/// The flag is not what makes a quota metered, and reading it that way left this
/// account with nothing to show but "could not read Copilot's usage panel".
@Test func aGrantedEntitlementIsReadEvenWhenTheQuotaFlagSaysOtherwise() throws {
    let business = """
    {"jsonrpc":"2.0","id":2,"result":{"quotaSnapshots":{
      "chat":{"isUnlimitedEntitlement":true,"entitlementRequests":0,"usedRequests":0,
        "remainingPercentage":100,"hasQuota":true,"tokenBasedBilling":true},
      "completions":{"isUnlimitedEntitlement":true,"entitlementRequests":0,"usedRequests":0,
        "remainingPercentage":100,"hasQuota":true,"tokenBasedBilling":true},
      "premium_interactions":{"isUnlimitedEntitlement":false,"entitlementRequests":18000,
        "usedRequests":7686,"remainingPercentage":57.3,"hasQuota":false,
        "tokenBasedBilling":true}}}}
    """
    let limits = try #require(CopilotUsagePanel.parse(business, now: now))
    #expect(limits.primary?.usedPercent == 42.7)
    #expect(limits.spend?.used == Money(amountMinor: 7686, currency: "AIC", exponent: 0))
    #expect(limits.spend?.limit == Money(amountMinor: 18000, currency: "AIC", exponent: 0))
}

/// An account with nothing metered has no figure to show, and an unlimited
/// entitlement is not a budget a bar can fill.
@Test func anAccountWithNoMeteredQuotaIsNotAReading() {
    let unlimited = """
    {"result":{"quotaSnapshots":{
      "chat":{"isUnlimitedEntitlement":true,"entitlementRequests":-1,"usedRequests":0,
        "remainingPercentage":100,"hasQuota":true},
      "premium_interactions":{"isUnlimitedEntitlement":false,"entitlementRequests":0,
        "usedRequests":0,"remainingPercentage":0,"hasQuota":false}}}}
    """
    #expect(CopilotUsagePanel.parse(unlimited, now: now) == nil)
}

/// The one thing that makes Copilot a different shape: a budget, and no window
/// under it. A figure invented for `secondary` would read as a weekly cap.
@Test func copilotHasNoSecondWindow() throws {
    let limits = try #require(CopilotUsagePanel.parse(reply(), now: now))
    #expect(limits.secondary == nil)
}

/// `resetDate` is the moment the quota was read — it came back within a second
/// of `now` on every live reply — so a stamp that is not ahead of us is not a
/// reset, and the month boundary stands in for it.
@Test func aResetInThePastFallsBackToTheMonthBoundary() throws {
    let limits = try #require(CopilotUsagePanel.parse(
        reply(resetDate: now.addingTimeInterval(-60).formatted(.iso8601)), now: now
    ))
    let reset = try #require(limits.primary?.resetsAt)

    #expect(reset > now)
    #expect(calendar.component(.day, from: reset) == 1)
    #expect(calendar.component(.hour, from: reset) == 0)
    let months = calendar.dateComponents([.month], from: now, to: reset).month ?? -1
    #expect(months <= 1)
}

/// The day that field starts pointing forward, it wins: it is the account's own
/// billing anniversary, which nothing else here knows.
@Test func aResetInTheFutureIsBelieved() throws {
    let stated = now.addingTimeInterval(3 * 24 * 3600)
    let limits = try #require(CopilotUsagePanel.parse(
        reply(resetDate: stated.formatted(.iso8601)), now: now
    ))
    let reset = try #require(limits.primary?.resetsAt)
    #expect(abs(reset.timeIntervalSince(stated)) < 1)
}

@Test func aSignInPromptIsToldApartFromAnUnreadableCopilotReply() async {
    let signIn = CopilotUsagePanel {
        #"{"jsonrpc":"2.0","id":2,"error":{"code":-32001,"message":"Not signed in"}}"#
    }
    await #expect(throws: PanelError.notSignedIn) { try await signIn.fetch(now: now) }

    let garbage = CopilotUsagePanel { #"{"jsonrpc":"2.0","id":2,"result":{}}"# }
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
