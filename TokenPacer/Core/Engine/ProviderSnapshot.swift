import Foundation

/// Everything one provider is handed to build its row from.
///
/// `stated` and `panel` are kept apart rather than resolved by the caller: which
/// of the two wins, and which fields each is allowed to contribute, is the one
/// thing the three providers genuinely disagree about.
struct SnapshotInput {
    var source: SourceID
    /// What this provider's own logs said about its limits. Nil for every
    /// provider whose logs say nothing, which is all of them but Codex.
    var stated: RateLimits?
    /// What the CLI's own usage panel said, already rolled past its reset when
    /// the window it described has closed.
    var panel: RateLimits?
    var events: [UsageEvent]
    var working = 0
    var now: Date
    var weights: TokenWeights = .default
    var panelMovedAt: Date?
    var panelData: PanelData?
    var windows: [SessionWindow]?
}

/// One provider's own path from what it knows to the row the UI draws.
///
/// The output is a `UsageSnapshot` for all three and has to stay that way: the
/// UI binds to one shape and can never be asked which provider it is drawing.
/// What differs is everything upstream of it — whether the source states limits
/// of its own, how those combine with the panel's reading, and which fields
/// each side is allowed to contribute.
///
/// That last part is why this exists at all. The rule used to be one line shared
/// by all three — take whichever reading is newer, whole — and it was right for
/// the two providers that state nothing and wrong for the one that does, in
/// three separate ways at once. A policy that belongs to one provider now lives
/// with that provider, where a change to it cannot reach the other two.
protocol ProviderSnapshot {
    /// Which limits this provider's row is drawn from.
    static func limits(_ input: SnapshotInput) -> RateLimits?

    /// The span the detail panel's splits describe, given the provider's own
    /// window and the one its logs imply.
    ///
    /// Its own when it has one. What to do when it does not is the part that is
    /// not shared: a provider with a five-hour window can fall back to the one
    /// the logs draw, and a provider without one has nothing to fall back to.
    static func panelWindow(
        provider: RateLimitWindow?, logged: SessionWindow?
    ) -> DateInterval?
}

extension ProviderSnapshot {
    /// Nothing in the logs, so the panel is the whole truth.
    static func limits(_ input: SnapshotInput) -> RateLimits? { input.panel }

    /// A five-hour window is the shape most providers have, so the logs can
    /// stand in for one that could not be read.
    static func panelWindow(
        provider: RateLimitWindow?, logged: SessionWindow?
    ) -> DateInterval? {
        SnapshotBuilder.defaultSplitSpan(provider, logged)
    }

    /// The assembly every provider shares today. It is called rather than
    /// inherited, so a provider whose shape stops fitting it can stop calling it
    /// without asking the other two to agree.
    static func build(_ input: SnapshotInput) -> UsageSnapshot {
        SnapshotBuilder.build(
            source: input.source,
            limits: limits(input),
            events: input.events,
            working: input.working,
            at: input.now,
            weights: input.weights,
            panelMovedAt: input.panelMovedAt,
            panel: input.panelData,
            windows: input.windows,
            splitSpan: panelWindow
        )
    }
}

/// Claude Code writes no limits into its logs. `/usage` is the only place the
/// figure exists, and it states both windows.
enum ClaudeSnapshot: ProviderSnapshot {}

/// Copilot writes none either, and has one window rather than two: a plan budget
/// spent down over a billing month, with no five-hour window behind it.
enum CopilotSnapshot: ProviderSnapshot {
    /// No plan budget read means no window at all, rather than the log's five
    /// hours.
    ///
    /// The shared fallback exists so a provider whose panel could not be read
    /// still attributes the window its logs draw. Copilot has no five-hour
    /// window to draw — the whole row is a month — so falling back to one
    /// described a period this provider does not have, under a headline that
    /// had gone blank at the same moment and could not contradict it.
    static func panelWindow(
        provider: RateLimitWindow?, logged: SessionWindow?
    ) -> DateInterval? {
        provider?.span
    }
}

enum CodexSnapshot: ProviderSnapshot {
    /// Codex is the only provider that states its limits in its own rollout
    /// logs, and a line just read is worth exactly what a CLI run would have
    /// cost to fetch — so it wins while it is fresh. It is not a whole reading
    /// though, and taking it whole broke three things at once:
    ///
    /// - It never carries `spend`. `CodexSource` has no field for it, so an
    ///   account on a credit budget lost its spend row to the next turn it ran
    ///   and got it back only in the gaps between turns — that is, everywhere
    ///   except while the figure was moving.
    /// - An account metered in credits states no window at all. That empty
    ///   reading, merely by being newer, replaced a good panel one and put the
    ///   row back to "—" seconds after it was read.
    /// - It is stamped when the line was written, so it never lost to the panel
    ///   reading rolled past its own reset. The roll-forward that makes a closed
    ///   window read 0% has therefore never run for Codex at all.
    ///
    /// So the two are merged rather than chosen between.
    static func limits(_ input: SnapshotInput) -> RateLimits? {
        guard let stated = input.stated, stated.describesALiveWindow(at: input.now)
        else { return input.panel }
        guard let panel = input.panel else { return stated }

        var winner = stated.observedAt > panel.observedAt ? stated : panel
        // Only the panel ever states it, so it survives whichever side wins.
        winner.spend = winner.spend ?? panel.spend
        return winner
    }
}

extension SnapshotBuilder {
    /// The row, built by the provider whose row it is.
    static func build(for source: SourceID, _ input: SnapshotInput) -> UsageSnapshot {
        switch source {
        case .claude: ClaudeSnapshot.build(input)
        case .codex: CodexSnapshot.build(input)
        case .copilot: CopilotSnapshot.build(input)
        }
    }
}

extension RateLimits {
    /// Whether this reading still describes a window that is open.
    ///
    /// A reading with no window at all is an account that states none — a credit
    /// budget has nothing shorter than a month to declare — and one whose
    /// windows have all passed describes a window that no longer exists. Neither
    /// is a reading worth preferring over one that does.
    func describesALiveWindow(at now: Date) -> Bool {
        [primary, secondary].compactMap(\.self).contains { $0.resetsAt > now }
    }
}
