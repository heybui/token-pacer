import Foundation

/// Reads Codex's limits out of `codex app-server`, the CLI's own JSON-RPC face.
///
/// This replaces driving the `/status` TUI through a pseudo-terminal, which was
/// a picture of the same fact: the CLI fetched the figures, drew them in a box,
/// and this app read the box back with regexes against whole percentages,
/// dateless local reset stamps and a layout that moved between releases.
/// `account/rateLimits/read` states every one of them as a number — the reset is
/// a Unix stamp, the percentage is a double, the window declares its own length
/// — and the read takes about a second rather than forty-five, needs no trusted
/// project to start in, and has no composer a stray keystroke can be typed into.
///
/// What it is *for* has not changed. Codex writes the same windows into its
/// rollout logs, so this is not how the figure is normally learned; it is how
/// the figure stays true when the work happened somewhere that writes no log
/// here — the desktop app, the web app, a cloud task. `PanelPoller` keeps it to
/// that job. What the logs never carry at all is the credit budget, and that
/// only arrives this way.
struct CodexUsagePanel: UsagePanel {
    var read: PanelReader

    func fetch(now: Date = Date.now) async throws -> RateLimits {
        let text = try await read()
        guard let limits = Self.parse(text, now: now) else {
            throw PanelText.looksLikeSignIn(text) ? PanelError.notSignedIn : PanelError.unreadable
        }
        return limits
    }

    // MARK: - Parsing

    /// A credit budget names no window length of its own. It states a cap and
    /// the moment that cap refills, and that moment is monthly.
    static let monthlyWindowMinutes = 43_200

    /// Nil when the reply carried no window and no budget — an error object
    /// where a result should be, or a release that moved the field. An account
    /// that can be read always has one of the two, so their absence is a
    /// failure rather than an empty reading.
    static func parse(_ raw: String, now: Date) -> RateLimits? {
        guard let message = try? JSONDecoder().decode(Message.self, from: Data(raw.utf8)),
              let snapshot = message.result?.rateLimits
        else { return nil }

        let budget = snapshot.individualLimit
        // An account metered in credits reports no five-hour window at all: the
        // budget is the only limit it has, so it is the headline. A plan
        // account states both and the windows win.
        let primary = snapshot.primary?.normalised ?? budget?.window
        guard primary != nil || snapshot.secondary != nil else { return nil }

        return RateLimits(
            primary: primary,
            secondary: snapshot.secondary?.normalised,
            // `plus`, `pro`, `business` — the wire spells the plan lowercase and
            // every surface that shows it wants the name.
            planType: snapshot.planType?.capitalized,
            observedAt: now,
            spend: budget?.spend
        )
    }

    /// One `account/rateLimits/read` reply, result envelope and all.
    ///
    /// The fields this app has no row for — `credits.balance`, `limitId`,
    /// `rateLimitsByLimitId`, `rateLimitResetCredits` — are simply not decoded.
    private struct Message: Decodable {
        let result: Result?

        struct Result: Decodable {
            let rateLimits: Snapshot?
        }

        struct Snapshot: Decodable {
            let primary: Window?
            let secondary: Window?
            let planType: String?
            /// The account's own spend cap, when it has one.
            let individualLimit: Budget?
        }

        struct Window: Decodable {
            let usedPercent: Double?
            let windowDurationMins: Int?
            let resetsAt: Double?

            init(from decoder: any Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                usedPercent = c.number(.usedPercent)
                windowDurationMins = c.number(.windowDurationMins).map { Int($0) }
                resetsAt = c.number(.resetsAt)
            }

            private enum CodingKeys: String, CodingKey { case usedPercent, windowDurationMins, resetsAt }

            var normalised: RateLimitWindow? {
                guard let used = usedPercent, let minutes = windowDurationMins, let resets = resetsAt
                else { return nil }
                return RateLimitWindow(
                    usedPercent: min(100, max(0, used)),
                    windowMinutes: minutes,
                    resetsAt: Date(timeIntervalSince1970: resets)
                )
            }
        }

        /// A monthly credit budget: whole credits used out of whole credits
        /// granted, which is what `/status` printed as `1,181 of 40,000 credits
        /// used`. Carried as `Spend` because it is that same shape — an amount,
        /// the budget it comes out of, and how far through it that is.
        struct Budget: Decodable {
            let limit: Double?
            let used: Double?
            let remainingPercent: Double?
            let resetsAt: Double?

            init(from decoder: any Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                limit = c.number(.limit)
                used = c.number(.used)
                remainingPercent = c.number(.remainingPercent)
                resetsAt = c.number(.resetsAt)
            }

            private enum CodingKeys: String, CodingKey { case limit, used, remainingPercent, resetsAt }

            /// What the account has drawn from its budget: the amount, the cap,
            /// and how far through it that is.
            ///
            /// Each side can be derived from the other, and which one wins is
            /// not the same answer for both. `used` wins for the **amount**.
            /// The wire's own `remainingPercent` wins for the **percentage**,
            /// because that is the figure Codex itself reports: a ratio worked
            /// out here would disagree with the CLI at a tone threshold, and
            /// being right about 89.6 against a source that says 90 is not
            /// worth showing a different colour for.
            ///
            /// The `/status` parser this replaced preferred the ratio, and was
            /// right to: the panel printed the percentage as a rounded whole
            /// number, so the pair was strictly finer. That was an artefact of
            /// rendering a screen. Over RPC the field is a `Double` and there
            /// is no rounding left to beat.
            private var drawn: (used: Double, limit: Double, usedPercent: Double)? {
                guard let limit, limit > 0 else { return nil }
                // Clamped before it is trusted either way round: a percentage
                // past either end puts a negative amount of credits on screen.
                let remaining = remainingPercent.map { min(100, max(0, $0)) }
                let used = max(0, used ?? remaining.map { limit * (100 - $0) / 100 } ?? 0)
                return (
                    used, limit,
                    remaining.map { 100 - $0 } ?? min(100, max(0, used / limit * 100))
                )
            }

            var spend: Spend? {
                guard let drawn else { return nil }
                return Spend(
                    used: credits(drawn.used),
                    limit: credits(drawn.limit),
                    percent: drawn.usedPercent,
                    isEnabled: true
                )
            }

            /// The budget as the window it stands in for, for an account that
            /// has no other.
            ///
            /// Thirty days is an approximation — a calendar month is 28 to 31,
            /// and the reply states no length at all. It is claimed anyway
            /// because the span is load-bearing: `SnapshotBuilder` measures the
            /// panel's splits back from the reset by exactly this, and without
            /// it they fall back to a five-hour window the account does not
            /// have and read "no open window" for days.
            var window: RateLimitWindow? {
                guard let drawn, let resetsAt, resetsAt > 0 else { return nil }
                return RateLimitWindow(
                    usedPercent: drawn.usedPercent,
                    windowMinutes: monthlyWindowMinutes,
                    resetsAt: Date(timeIntervalSince1970: resetsAt)
                )
            }

            private func credits(_ amount: Double) -> Money {
                Money(amountMinor: Int(amount.rounded()), currency: Money.credits, exponent: 0)
            }
        }
    }
}

private extension KeyedDecodingContainer {
    /// A number, or a number spelled as a string. Codex sends a business
    /// budget's `limit` and `used` as `"40000"` and `"1195.64"` beside plain
    /// numbers in the same object, and one strict `Double` that meets a string
    /// fails the whole reply. A field that is neither reads as absent.
    func number(_ key: Key) -> Double? {
        if let value = try? decodeIfPresent(Double.self, forKey: key) { return value }
        return (try? decodeIfPresent(String.self, forKey: key))?.flatMap(Double.init)
    }
}
