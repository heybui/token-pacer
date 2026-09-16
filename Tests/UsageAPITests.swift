import Foundation
import Testing
@testable import BurnTracker

private let now = Date(timeIntervalSince1970: 1_789_000_000)

private func api(
    status: Int = 200, headers: [String: String] = [:], body: String = "{}"
) -> ClaudeUsageAPI {
    ClaudeUsageAPI(
        token: { "test-token" },
        transport: { _ in
            ClaudeUsageAPI.Reply(status: status, headers: headers, body: Data(body.utf8))
        }
    )
}

// MARK: - decoding

@Test func decodesTheKnownWindows() async throws {
    let body = """
    {"five_hour":{"utilization":11,"resets_at":"2026-09-16T20:00:00Z"},
     "seven_day":{"utilization":15,"resets_at":"2026-09-21T00:00:00Z"}}
    """
    let response = try await api(body: body).fetch()
    #expect(response.session?.utilization == 11)
    #expect(response.weekly?.utilization == 15)
    #expect(response.session?.resetsAt != nil)
}

/// Per-model weekly windows appear as models ship. A new one must not need a
/// code change, so anything window-shaped is kept under its own key.
@Test func keepsUnknownPerModelWindows() async throws {
    let body = """
    {"five_hour":{"utilization":11,"resets_at":null},
     "seven_day":{"utilization":15,"resets_at":null},
     "seven_day_fable":{"utilization":0,"resets_at":null},
     "seven_day_opus":{"utilization":40,"resets_at":null}}
    """
    let response = try await api(body: body).fetch()
    #expect(response.windows.count == 4)
    #expect(response.perModelWeekly.keys.sorted() == ["seven_day_fable", "seven_day_opus"])
    #expect(response.windows["seven_day_fable"]?.utilization == 0)
}

/// Verbatim from Claude Code's own cache. The figures are minor units: 1199 with
/// exponent 2 is S$11.99, not S$1199.
@Test func decodesSpendAsMinorUnitsInItsOwnCurrency() async throws {
    let body = """
    {"spend":{"used":{"amount_minor":1199,"currency":"SGD","exponent":2},
              "limit":{"amount_minor":1200,"currency":"SGD","exponent":2},
              "percent":100,"enabled":true}}
    """
    let spend = try #require(await api(body: body).fetch().spend)
    #expect(spend.used.amount == Decimal(string: "11.99"))
    #expect(spend.used.currency == "SGD")
    #expect(spend.limit?.amount == Decimal(12))
    #expect(spend.isEnabled)
}

/// The older shape says the same thing with different names — same account, same
/// response, so a client that reads only one of the two is a version behind.
@Test func fallsBackToExtraUsageWhenSpendIsAbsent() async throws {
    let body = """
    {"extra_usage":{"is_enabled":true,"monthly_limit":1200,"used_credits":1199,
                    "utilization":99.92,"currency":"SGD","decimal_places":2}}
    """
    let spend = try #require(await api(body: body).fetch().spend)
    #expect(spend.used.amount == Decimal(string: "11.99"))
    #expect(spend.used.currency == "SGD")
    #expect(spend.percent == 99.92)
}

/// Both are present on a live response; the explicit one wins.
@Test func spendWinsOverExtraUsage() async throws {
    let body = """
    {"spend":{"used":{"amount_minor":500,"currency":"USD","exponent":2},"enabled":true},
     "extra_usage":{"is_enabled":true,"used_credits":9999,"currency":"SGD","decimal_places":2}}
    """
    let spend = try #require(await api(body: body).fetch().spend)
    #expect(spend.used.amountMinor == 500)
    #expect(spend.used.currency == "USD")
}

/// A zero-exponent currency has no minor unit at all — 1199 yen is 1199 yen.
@Test func currenciesWithoutMinorUnitsAreNotDivided() async throws {
    let body = """
    {"spend":{"used":{"amount_minor":1199,"currency":"JPY","exponent":0},"enabled":true}}
    """
    let spend = try #require(await api(body: body).fetch().spend)
    #expect(spend.used.amount == Decimal(1199))
}

/// API-key users get `{}`. That is an empty result, not a failure.
@Test func anEmptyObjectIsNotAnError() async throws {
    let response = try await api(body: "{}").fetch()
    #expect(response.isEmpty)
    #expect(response.session == nil)
}

@Test func ignoresGarbageFieldsInsteadOfFailing() async throws {
    let body = """
    {"five_hour":{"utilization":11,"resets_at":null},
     "some_new_scalar":42,
     "another":{"unrelated":"shape"}}
    """
    let response = try await api(body: body).fetch()
    #expect(response.session?.utilization == 11)
    #expect(response.windows.count == 1)
}

@Test func treatsFractionsAsPercentages() async throws {
    let response = try await api(body: #"{"five_hour":{"utilization":0.42,"resets_at":null}}"#).fetch()
    #expect(response.session?.utilization == 42)
}

@Test func clampsOutOfRangeUtilization() async throws {
    let response = try await api(body: #"{"five_hour":{"utilization":140,"resets_at":null}}"#).fetch()
    #expect(response.session?.utilization == 100)
}

// MARK: - errors

/// Only a refusal that cannot change on its own disables the feature. A 401 can
/// clear the moment Claude Code refreshes the token, so it backs off instead.
@Test func onlyForbiddenStopsUsAskingForGood() async {
    await #expect(throws: UsageAPIError.forbidden) { try await api(status: 403).fetch() }
    #expect(UsageAPIError.forbidden.isFatal)

    await #expect(throws: UsageAPIError.unauthorized) { try await api(status: 401).fetch() }
    #expect(UsageAPIError.unauthorized.isFatal == false)
}

@Test func recoverableCredentialProblemsDoNotDisableLiveLimits() {
    for error in [UsageAPIError.noToken, .keychainDenied, .tokenExpired] {
        #expect(error.isFatal == false)
        #expect(!error.message.isEmpty)
    }
}

@Test func throttlingCarriesRetryAfterAndIsNotFatal() async throws {
    let client = api(status: 429, headers: ["Retry-After": "120"])
    let error = await #expect(throws: UsageAPIError.self) { try await client.fetch() }
    #expect(error == .rateLimited(retryAfter: 120))
    #expect(error?.isFatal == false)
}

@Test func serverErrorsAreWorthRetrying() async {
    let error = await #expect(throws: UsageAPIError.self) { try await api(status: 503).fetch() }
    #expect(error == .server(status: 503))
    #expect(error?.isFatal == false)
}

@Test func unreadableBodiesAreReported() async {
    let error = await #expect(throws: UsageAPIError.self) {
        try await api(body: "<html>nope</html>").fetch()
    }
    #expect(error == .malformedResponse)
}

@Test func theRequestCarriesTheDocumentedHeaders() async throws {
    let captured = Captured()
    let client = ClaudeUsageAPI(
        token: { "secret" },
        transport: { request in
            await captured.set(request)
            return ClaudeUsageAPI.Reply(status: 200, headers: [:], body: Data("{}".utf8))
        }
    )
    _ = try await client.fetch()
    let request = try #require(await captured.request)
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer secret")
    #expect(request.value(forHTTPHeaderField: "anthropic-beta") == ClaudeUsageAPI.betaHeader)
    #expect(request.url == ClaudeUsageAPI.endpoint)
    #expect(request.timeoutInterval == 5)
}

private actor Captured {
    var request: URLRequest?
    func set(_ request: URLRequest) { self.request = request }
}

// MARK: - credentials

@Test func parsesTheStoredCredentialBlob() {
    let blob = Data(#"{"claudeAiOauth":{"accessToken":"abc","expiresAt":1789003600000}}"#.utf8)
    let token = try! #require(ClaudeCredentials.parse(blob))
    #expect(token.accessToken == "abc")
    #expect(token.expiresAt == Date(timeIntervalSince1970: 1_789_003_600))
}

@Test func rejectsABlobWithoutAToken() {
    #expect(ClaudeCredentials.parse(Data(#"{"claudeAiOauth":{}}"#.utf8)) == nil)
    #expect(ClaudeCredentials.parse(Data(#"{"accessToken":"x"}"#.utf8)) == nil)
    #expect(ClaudeCredentials.parse(Data("not json".utf8)) == nil)
}

/// Expiry is checked with leeway so a token dying mid-flight is not used.
@Test func treatsNearlyExpiredTokensAsExpired() {
    let token = ClaudeCredentials.Token(accessToken: "a", expiresAt: now.addingTimeInterval(30))
    #expect(token.isExpired(at: now))
    #expect(ClaudeCredentials.Token(accessToken: "a", expiresAt: now.addingTimeInterval(600))
        .isExpired(at: now) == false)
}

@Test func aTokenWithoutAnExpiryIsAccepted() {
    #expect(ClaudeCredentials.Token(accessToken: "a", expiresAt: nil).isExpired(at: now) == false)
}
