import Foundation

/// One billed exchange, normalised across CLIs.
struct UsageEvent: Equatable, Sendable, Identifiable {
    /// Dedupe key. Resumed sessions replay history into a new file, so the same
    /// exchange can appear in more than one log.
    let id: String
    let source: SourceID
    let timestamp: Date
    let model: String?
    /// Last path component of the working directory.
    let project: String?
    let sessionID: String?
    let counts: TokenCounts
}

/// Rate limits a CLI states outright. Codex publishes these; Claude does not,
/// which is why `CeilingEstimator` exists.
struct RateLimitWindow: Equatable, Sendable {
    let usedPercent: Double
    let windowMinutes: Int
    let resetsAt: Date
}

struct RateLimits: Equatable, Sendable {
    /// The short window — 300 minutes, the design's "5-hour".
    let primary: RateLimitWindow?
    /// The long window — 10080 minutes, the weekly cap.
    let secondary: RateLimitWindow?
    let planType: String?
    let observedAt: Date
}

struct SourceSnapshot: Sendable {
    let source: SourceID
    let events: [UsageEvent]
    /// Non-nil only for sources that publish their own limits.
    let limits: RateLimits?
}
