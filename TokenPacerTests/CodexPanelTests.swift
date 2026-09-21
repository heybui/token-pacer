import Foundation
import Testing
@testable import TokenPacer

/// Verbatim from a live `account/rateLimits/read` on codex-cli 0.155.1, result
/// envelope and all — including the fields this app has no row for.
private let reply = """
{"id":2,"result":{"ordinaryUsageAllowed":true,"rateLimits":{"limitId":"codex","limitName":null,\
"normalModelSlug":null,"primary":{"usedPercent":12,"windowDurationMins":300,"resetsAt":1789981987},\
"secondary":{"usedPercent":4,"windowDurationMins":10080,"resetsAt":1790428515},\
"credits":{"hasCredits":false,"unlimited":false,"balance":"0"},"individualLimit":null,\
"spendControlReached":false,"planType":"plus","rateLimitReachedType":null},\
"accountId":"37b528a2-2ca6-4f16-985a-83e24114661e","rateLimitUpsell":null}}
"""

/// How the server answers when nobody is signed in.
private let unauthenticated = """
{"error":{"code":-32600,"message":"codex account authentication required to read rate limits"},"id":2}
"""

private let now = Date()

@Test func bothWindowsComeBackAsStatedNumbers() throws {
    let limits = try #require(CodexUsagePanel.parse(reply, now: now))

    #expect(limits.primary?.usedPercent == 12)
    #expect(limits.primary?.windowMinutes == 300)
    #expect(limits.primary?.resetsAt == Date(timeIntervalSince1970: 1_789_981_987))
    #expect(limits.secondary?.usedPercent == 4)
    #expect(limits.secondary?.windowMinutes == 10_080)
    #expect(limits.spend == nil)
}

/// The wire spells it lowercase; every surface that shows a plan wants the name.
@Test func thePlanIsCapitalisedAndTheAccountIdIsIgnored() throws {
    #expect(try #require(CodexUsagePanel.parse(reply, now: now)).planType == "Plus")
}

/// A reading is the moment it was taken, not a stamp the reply carries — the
/// windows' own resets are the only times in it.
@Test func theReadingIsStampedWhenItWasTaken() throws {
    #expect(try #require(CodexUsagePanel.parse(reply, now: now)).observedAt == now)
}

@Test func anAuthErrorIsToldApartFromAReplyThatCannotBeRead() async {
    let signIn = CodexUsagePanel { unauthenticated }
    await #expect(throws: PanelError.notSignedIn) { try await signIn.fetch(now: now) }

    let garbage = CodexUsagePanel { #"{"id":2,"result":{"ordinaryUsageAllowed":true}}"# }
    await #expect(throws: PanelError.unreadable) { try await garbage.fetch(now: now) }

    let notJSON = CodexUsagePanel { "codex: command not found" }
    await #expect(throws: PanelError.unreadable) { try await notJSON.fetch(now: now) }
}

/// A workspace metered in credits: no five-hour window exists, because a credit
/// budget is the only limit the account has.
private let creditReply = """
{"id":2,"result":{"rateLimits":{"limitId":"codex","primary":null,"secondary":null,\
"credits":{"hasCredits":true,"unlimited":false,"balance":"0"},\
"individualLimit":{"limit":40000,"used":1181,"remainingPercent":97,"resetsAt":1790428515},\
"planType":"enterprise"}}}
"""

@Test func aCreditBudgetStandsInForTheWindowTheAccountDoesNotHave() throws {
    let limits = try #require(CodexUsagePanel.parse(creditReply, now: now))

    #expect(limits.primary?.usedPercent == 3)
    #expect(limits.primary?.windowMinutes == CodexUsagePanel.monthlyWindowMinutes)
    #expect(limits.primary?.resetsAt == Date(timeIntervalSince1970: 1_790_428_515))
    #expect(limits.secondary == nil)
    #expect(limits.planType == "Enterprise")
}

@Test func theCreditBudgetItselfIsCarriedAsSpend() throws {
    let spend = try #require(CodexUsagePanel.parse(creditReply, now: now)?.spend)

    #expect(spend.used.amountMinor == 1_181)
    #expect(spend.limit?.amountMinor == 40_000)
    #expect(spend.share == 3)
    #expect(spend.used.isCredits)
    #expect(spend.used.exponent == 0)
    #expect(spend.isEnabled)
}

/// Codex reports both sides of the ratio and they need not agree: 1,181 of
/// 40,000 is 2.95%, while the reply says 3% is gone. The *amount* comes from
/// `used` and the *percentage* from `remainingPercent`, so the row reads the
/// same figure the CLI does — worth more than a precision nobody can act on,
/// and it keeps a tone threshold on the same side as the source.
@Test func theServersOwnPercentageWinsOverTheRatio() throws {
    let limits = try #require(CodexUsagePanel.parse("""
    {"id":2,"result":{"rateLimits":{"individualLimit":\
    {"limit":40000,"used":35000,"remainingPercent":10,"resetsAt":1790428515}}}}
    """, now: now))

    // 35,000 of 40,000 is 87.5%; the server says 10% is left, so 90. The two
    // land either side of `critAt`, which is `pct >= 90`: the ratio would draw
    // this budget amber while Codex itself calls it red.
    #expect(limits.primary?.usedPercent == 90)
    #expect(limits.spend?.share == 90)
    #expect(limits.spend?.used.amountMinor == 35_000)
}

/// A percentage past either end would put a negative amount of credits on
/// screen.
@Test func aPercentageOutsideItsRangeIsClamped() throws {
    let spend = try #require(CodexUsagePanel.parse("""
    {"id":2,"result":{"rateLimits":{"individualLimit":\
    {"limit":1000,"used":null,"remainingPercent":140,"resetsAt":1790428515}}}}
    """, now: now)?.spend)

    #expect(spend.used.amountMinor == 0)
    #expect(spend.share == 0)
}

/// A cap that states only how much is left still says how much is gone.
@Test func aBudgetWithoutAUsedFigureIsDerivedFromWhatIsLeft() throws {
    let spend = try #require(CodexUsagePanel.parse("""
    {"id":2,"result":{"rateLimits":{"individualLimit":\
    {"limit":1000,"used":null,"remainingPercent":25,"resetsAt":1790428515}}}}
    """, now: now)?.spend)

    #expect(spend.used.amountMinor == 750)
    #expect(spend.share == 75)
}

/// A plan account with a spend cap keeps its windows; the cap is spend, not the
/// headline.
@Test func aStatedWindowBeatsABudgetThatIsAlsoPresent() throws {
    let limits = try #require(CodexUsagePanel.parse("""
    {"id":2,"result":{"rateLimits":{"primary":\
    {"usedPercent":6,"windowDurationMins":300,"resetsAt":1789981987},\
    "individualLimit":{"limit":40000,"used":1181,"remainingPercent":97,"resetsAt":1790428515},\
    "planType":"business"}}}
    """, now: now))

    #expect(limits.primary?.windowMinutes == 300)
    #expect(limits.primary?.usedPercent == 6)
    #expect(limits.spend?.used.amountMinor == 1_181)
}

/// A zero cap caps nothing, and dividing by it is how a budget row reads `NaN%`.
@Test func anEmptyBudgetIsNoBudget() throws {
    #expect(CodexUsagePanel.parse("""
    {"id":2,"result":{"rateLimits":{"individualLimit":\
    {"limit":0,"used":0,"remainingPercent":100,"resetsAt":1790428515},"planType":"plus"}}}
    """, now: now) == nil)
}

/// A reading that came from a rollout log beats one from an RPC read a minute
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
