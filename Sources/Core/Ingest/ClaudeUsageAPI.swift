import Foundation

/// The endpoint's reply, decoded defensively.
///
/// Window keys are not fixed — `five_hour`, `seven_day`, `seven_day_opus`,
/// `seven_day_sonnet` are known, but per-model weekly windows appear as models
/// ship. Anything shaped like a window is kept under its own key, so a new one
/// needs no code change.
struct UsageLimitsResponse: Sendable, Equatable {
    struct Window: Sendable, Equatable {
        let utilization: Double
        let resetsAt: Date?
    }

    var windows: [String: Window] = [:]
    var extraUsage: ExtraUsage?

    static let sessionKey = "five_hour"
    static let weeklyKey = "seven_day"

    var session: Window? { windows[Self.sessionKey] }
    var weekly: Window? { windows[Self.weeklyKey] }

    /// Per-model weekly windows, e.g. `seven_day_opus`. Excludes the plain weekly.
    var perModelWeekly: [String: Window] {
        windows.filter { $0.key.hasPrefix(Self.weeklyKey) && $0.key != Self.weeklyKey }
    }

    /// Empty means the account is not a managed OAuth subscriber, or the token
    /// lacks `user:profile`. Not an error — just nothing to show.
    var isEmpty: Bool { windows.isEmpty && extraUsage == nil }

    func anchor(_ key: String = sessionKey, observedAt: Date) -> LimitsAnchor? {
        windows[key].map {
            LimitsAnchor(utilization: $0.utilization, observedAt: observedAt, resetsAt: $0.resetsAt)
        }
    }

    func rateLimits(observedAt: Date) -> RateLimits {
        RateLimits(
            primary: session.map {
                RateLimitWindow(usedPercent: $0.utilization, windowMinutes: 300,
                                resetsAt: $0.resetsAt ?? observedAt)
            },
            secondary: weekly.map {
                RateLimitWindow(usedPercent: $0.utilization, windowMinutes: 10080,
                                resetsAt: $0.resetsAt ?? observedAt)
            },
            planType: nil,
            observedAt: observedAt
        )
    }
}

extension UsageLimitsResponse: Decodable {
    private struct AnyKey: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    private struct RawWindow: Decodable {
        let utilization: Double?
        let resets_at: String?
    }

    private struct RawExtra: Decodable {
        let is_enabled: Bool?
        let monthly_limit: Double?
        let used_credits: Double?
        let utilization: Double?
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: AnyKey.self)
        for key in container.allKeys {
            if key.stringValue == "extra_usage" {
                if let raw = try? container.decode(RawExtra.self, forKey: key) {
                    extraUsage = ExtraUsage(
                        isEnabled: raw.is_enabled ?? false,
                        monthlyLimit: raw.monthly_limit,
                        usedCredits: raw.used_credits,
                        utilization: raw.utilization
                    )
                }
                continue
            }
            guard let raw = try? container.decode(RawWindow.self, forKey: key),
                  let utilization = raw.utilization
            else { continue }

            windows[key.stringValue] = Window(
                // Some fields come back as a 0–1 fraction rather than a percentage.
                utilization: min(100, max(0, utilization > 0 && utilization <= 1 ? utilization * 100 : utilization)),
                resetsAt: raw.resets_at.flatMap(ISO8601.parse)
            )
        }
    }
}

enum UsageAPIError: Error, Equatable {
    case noToken
    case keychainDenied
    case tokenExpired
    case unauthorized
    case forbidden
    case rateLimited(retryAfter: TimeInterval?)
    case server(status: Int)
    case malformedResponse

    /// Only a refusal that cannot change on its own stops us asking for good.
    ///
    /// A missing token, an expired one, or a denied Keychain prompt all resolve
    /// without any action from this app — the user signs in, Claude Code refreshes,
    /// the prompt is allowed on the next run. Those back off rather than disable,
    /// or the feature would never come back.
    var isFatal: Bool {
        switch self {
        case .forbidden: true
        case .noToken, .keychainDenied, .tokenExpired, .unauthorized,
             .rateLimited, .server, .malformedResponse: false
        }
    }

    var message: String {
        switch self {
        case .noToken: "sign in to Claude Code"
        case .keychainDenied: "allow Keychain access to read usage"
        case .tokenExpired: "Claude Code sign-in expired"
        case .unauthorized: "usage access denied"
        case .forbidden: "usage access forbidden"
        case .rateLimited: "usage requests throttled"
        case .server(let status): "usage endpoint error \(status)"
        case .malformedResponse: "unreadable usage response"
        }
    }
}

/// Minimal client for the endpoint that powers Claude Code's own usage panel.
struct ClaudeUsageAPI: Sendable {
    struct Reply: Sendable {
        let status: Int
        let headers: [String: String]
        let body: Data
    }

    typealias Transport = @Sendable (URLRequest) async throws -> Reply
    typealias TokenProvider = @Sendable () async throws -> String

    static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    static let betaHeader = "oauth-2025-04-20"

    var token: TokenProvider
    var transport: Transport = Self.urlSessionTransport
    var userAgent = "BurnTracker/0.1"

    func fetch() async throws -> UsageLimitsResponse {
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = 5
        request.setValue("Bearer \(try await token())", forHTTPHeaderField: "Authorization")
        request.setValue(Self.betaHeader, forHTTPHeaderField: "anthropic-beta")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        let reply = try await transport(request)

        switch reply.status {
        case 200:
            guard let decoded = try? JSONDecoder().decode(UsageLimitsResponse.self, from: reply.body)
            else { throw UsageAPIError.malformedResponse }
            return decoded
        case 401: throw UsageAPIError.unauthorized
        case 403: throw UsageAPIError.forbidden
        case 429:
            let retryAfter = reply.headers
                .first { $0.key.lowercased() == "retry-after" }
                .flatMap { TimeInterval($0.value) }
            throw UsageAPIError.rateLimited(retryAfter: retryAfter)
        default: throw UsageAPIError.server(status: reply.status)
        }
    }

    static let urlSessionTransport: Transport = { request in
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw UsageAPIError.malformedResponse }
        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            if let key = key as? String, let value = value as? String { headers[key] = value }
        }
        return Reply(status: http.statusCode, headers: headers, body: data)
    }
}
