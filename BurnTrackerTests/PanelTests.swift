import Foundation
import Testing
@testable import BurnTracker

/// Verbatim shape of a real `/usage` render, down to the parts that make it hard:
/// bar glyphs wedged between a label and its number, labels running straight into
/// the next figure with no space, and reset times written for people.
private let panel = """
\u{1B}[2J\u{1B}[H  Settings  Status   Config   Usage   Stats\u{1B}[0m
Current session\u{1B}[38;5;2m██\u{1B}[0m                    4%usedResets 2:50pm (Asia/Saigon)
Current week (all models)█████████            18%usedResets Sep 22 at 1am (Asia/Saigon)
Current week (Fable)                           0% usedResets Sep 22 at 1am (Asia/Saigon)
Usage credits█████████████████████████████▉99%usedS$11.99 / S$12.00 spent · Resets Oct 1 (Asia/Saigon)
"""

/// Mid-September, before every reset the panel above names.
private let now = ISO8601DateFormatter().date(from: "2026-09-17T10:30:00+07:00")!
private let saigon = TimeZone(identifier: "Asia/Saigon")!

/// Captured from a live run. The CLI positions the cursor instead of emitting
/// padding, so once the escapes are gone the words are welded together — and the
/// same render mixes welded and spaced text. This is the shape that matters.
private let welded = """
Total~786tok/turn Currentsession 7%used Resets2:50pm(Asia/Saigon) Currentweek(allmodels) 19%used ResetsSep22at1am(Asia/Saigon) +50%weeklylimitspromoended now+25%permanently Refreshing… Esctocancel Current week (Fable) 0% used ResetsSep22at1am(Asia/Saigon) Usagecredits 99%used S$11.99/S$12.00spent ResetsOct1(Asia/Saigon) Esctocancel
"""

@Test func aRenderWithItsSpacesEatenStillParses() throws {
    let limits = try #require(ClaudeUsagePanel.parse(welded, now: now))
    #expect(limits.primary?.usedPercent == 7)
    #expect(limits.secondary?.usedPercent == 19)          // not the Fable 0%
    #expect(limits.spend?.used == Money(amountMinor: 1199, currency: "SGD", exponent: 2))

    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = saigon
    let weekly = try #require(limits.secondary?.resetsAt)
    #expect(calendar.component(.day, from: weekly) == 22)
    #expect(calendar.component(.hour, from: weekly) == 1)
}

@Test func theSessionWindowIsReadOffThePanel() throws {
    let limits = try #require(ClaudeUsagePanel.parse(panel, now: now))
    let primary = try #require(limits.primary)
    #expect(primary.usedPercent == 4)
    #expect(primary.windowMinutes == 300)
}

@Test func theWeeklyWindowIsTheAllModelsOneNotTheFirstMatch() throws {
    let limits = try #require(ClaudeUsagePanel.parse(panel, now: now))
    #expect(limits.secondary?.usedPercent == 18)
    #expect(limits.secondary?.windowMinutes == 10_080)
}

/// `2:50pm` with no date: the next such moment, which today still is.
@Test func aTimeOnlyResetLandsOnTheNextOne() throws {
    let limits = try #require(ClaudeUsagePanel.parse(panel, now: now))
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = saigon
    let reset = try #require(limits.primary?.resetsAt)

    #expect(reset > now)
    #expect(calendar.component(.hour, from: reset) == 14)
    #expect(calendar.component(.minute, from: reset) == 50)
    #expect(calendar.isDate(reset, inSameDayAs: now))
}

/// The same figure read after it has passed belongs to tomorrow, not to a reset
/// eighteen hours in the past.
@Test func aTimeOnlyResetRollsToTomorrowOnceItHasPassed() throws {
    let evening = now.addingTimeInterval(9 * 3600)       // 19:30 Saigon
    let limits = try #require(ClaudeUsagePanel.parse(panel, now: evening))
    let reset = try #require(limits.primary?.resetsAt)
    #expect(reset > evening)
    #expect(reset.timeIntervalSince(evening) < 24 * 3600)
}

@Test func aDatedResetTakesTheYearFromNow() throws {
    let limits = try #require(ClaudeUsagePanel.parse(panel, now: now))
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = saigon
    let reset = try #require(limits.secondary?.resetsAt)

    #expect(calendar.component(.year, from: reset) == 2026)
    #expect(calendar.component(.month, from: reset) == 9)
    #expect(calendar.component(.day, from: reset) == 22)
    #expect(calendar.component(.hour, from: reset) == 1)
}

@Test func spendIsReadInMinorUnitsOfItsOwnCurrency() throws {
    let limits = try #require(ClaudeUsagePanel.parse(panel, now: now))
    let spend = try #require(limits.spend)
    // The label runs into the figure — `99%usedS$11.99` — so this is the case
    // that a whitespace-delimited match gets wrong.
    #expect(spend.used == Money(amountMinor: 1199, currency: "SGD", exponent: 2))
    #expect(spend.limit == Money(amountMinor: 1200, currency: "SGD", exponent: 2))
    #expect(spend.percent == 99)
}

@Test func moneyKeepsAnUnknownSymbolRatherThanGuessing() {
    #expect(ClaudeUsagePanel.money("₽1,250") == Money(amountMinor: 1250, currency: "₽", exponent: 0))
    #expect(ClaudeUsagePanel.money("$1,234.50")
        == Money(amountMinor: 123_450, currency: "USD", exponent: 2))
}

/// The panel repaints when the refresh lands. The later paint is the fresh one.
@Test func aRepaintedPanelReportsTheLaterFigure() throws {
    let refreshed = panel + "\n" + panel.replacingOccurrences(of: "4%used", with: "7%used")
    let limits = try #require(ClaudeUsagePanel.parse(refreshed, now: now))
    #expect(limits.primary?.usedPercent == 7)
}

/// The escape classes are spelled for ICU, not for Swift: a raw string leaves
/// `\u{1B}` as six literal characters, and a regex that silently matches nothing
/// leaves every escape sequence in the text for the next pattern to trip over.
@Test func escapeSequencesAndBarGlyphsAreStripped() {
    let normalized = ClaudeUsagePanel.normalize(panel)
    #expect(normalized.contains("\u{1B}") == false)
    #expect(normalized.contains("[38;5;2m") == false)
    #expect(normalized.contains("█") == false)
    #expect(normalized.contains("Current session 4%usedResets 2:50pm (Asia/Saigon)"))
}

@Test func aPanelWithNoSessionWindowIsNotAReading() {
    #expect(ClaudeUsagePanel.parse("Settings Status Config Usage Stats", now: now) == nil)
}

@Test func aSignInPromptIsToldApartFromAnUnreadablePanel() async {
    let signIn = ClaudeUsagePanel { "Please run /login to continue" }
    await #expect(throws: PanelError.notSignedIn) { try await signIn.fetch(now: now) }

    let garbage = ClaudeUsagePanel { "\u{1B}[2Jnothing here" }
    await #expect(throws: PanelError.unreadable) { try await garbage.fetch(now: now) }
}

@Test func onlyAMissingCliStopsUsAskingForGood() {
    #expect(PanelError.cliNotFound.isFatal)
    #expect(PanelError.noTrustedDirectory.isFatal)
    for recoverable in [PanelError.timedOut, .notSignedIn, .unreadable, .spawnFailed(code: 2)] {
        #expect(recoverable.isFatal == false)
    }
}
