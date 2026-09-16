import Foundation

/// Everything that decides which of the eight shells is on screen.
struct PillInputs: Equatable, Sendable {
    var snapshot: UsageSnapshot?
    var pointerInside = false
    var isPinned = false
    /// Tracking switched off from the menu. Survives relaunch.
    var isPaused = false
    /// The warning fires once per window, then never again until it resets.
    var warningAcknowledged = false
    var criticalAt: Double = 90
    /// Off keeps the collapsed pill on screen through a quiet spell rather than
    /// withdrawing to the 3pt sliver.
    var hideWhenDormant = true
}

/// One function, no scattered booleans. The design's eight states are mutually
/// exclusive, so deciding them in one place is what keeps them that way.
enum PillStateResolver {
    /// Silence for this long reads as "no Claude activity" and the pill withdraws.
    static let dormantAfter: TimeInterval = 10 * 60

    static func resolve(
        _ inputs: PillInputs,
        at now: Date,
        dormantAfter: TimeInterval = dormantAfter
    ) -> PillState {
        // Off is off: no figures, no alerts, and hovering does not reveal any.
        if inputs.isPaused { return .paused }
        if inputs.isPinned { return .pinned }

        if inputs.hideWhenDormant, isDormant(inputs, at: now, dormantAfter: dormantAfter) {
            // Hovering dead space reveals the ghost — the only way to reach the
            // menu while dormant.
            return inputs.pointerInside ? .ghost : .dormant
        }

        // Hovering counts as seeing the warning, so it never fires again this
        // window. Checked before `.exhausted` so a hover always opens the card.
        if inputs.pointerInside { return .hover }

        if let percent = inputs.snapshot?.sessionPercent {
            if percent >= 100 { return .exhausted }
            if percent >= inputs.criticalAt && !inputs.warningAcknowledged { return .warning }
        }
        return .collapsed
    }

    private static func isDormant(
        _ inputs: PillInputs, at now: Date, dormantAfter: TimeInterval
    ) -> Bool {
        guard let snapshot = inputs.snapshot else { return true }
        guard let lastActivity = snapshot.lastActivity else { return true }
        return now.timeIntervalSince(lastActivity) > dormantAfter
    }
}
