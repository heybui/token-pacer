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
    /// The ghost is held this long after the pointer leaves, so crossing the
    /// notch on the way somewhere else does not snap it away mid-glance.
    var ghostHeldUntil: Date?
    /// Off keeps the collapsed pill on screen through a quiet spell rather than
    /// withdrawing to the 3pt sliver.
    var hideWhenNothingRuns = true
    /// What the right wing carries at its end, when anything does — a source
    /// complaining, or a count of sessions waiting for an answer. Geometry only;
    /// what either one says lives on the store.
    var badge: PillState.Badge?
    /// Which mark the wings carry, which is most of how wide they are.
    var mark: Mark = .capsuleBar
    /// Whether the figure is carried beside it. Geometry as much as taste: the
    /// headline is a third of the leading wing.
    var showsPercentage = true
}

/// One function, no scattered booleans. The design's eight states are mutually
/// exclusive, so deciding them in one place is what keeps them that way.
enum PillStateResolver {
    /// Silence for this long reads as "no Claude activity" and the pill withdraws.
    static let hiddenAfter: TimeInterval = 10 * 60
    /// How long the ghost lingers once the pointer has gone.
    static let ghostFade: TimeInterval = 0.4

    static func resolve(
        _ inputs: PillInputs,
        at now: Date,
        hiddenAfter: TimeInterval = hiddenAfter
    ) -> PillState {
        // Off is off: no figures, no alerts, and hovering does not reveal any.
        if inputs.isPaused { return .paused }
        if inputs.isPinned { return .pinned }

        if inputs.hideWhenNothingRuns, nothingRunning(inputs, at: now, hiddenAfter: hiddenAfter) {
            // Hovering dead space reveals the ghost — the only way to reach the
            // menu while hidden. "Fades out ~400ms after the pointer leaves."
            if inputs.pointerInside { return .ghost }
            if let held = inputs.ghostHeldUntil, now < held { return .ghost }
            return .hidden
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

    private static func nothingRunning(
        _ inputs: PillInputs, at now: Date, hiddenAfter: TimeInterval
    ) -> Bool {
        guard let snapshot = inputs.snapshot else { return true }
        guard let lastActivity = snapshot.lastActivity else { return true }
        return now.timeIntervalSince(lastActivity) > hiddenAfter
    }
}
