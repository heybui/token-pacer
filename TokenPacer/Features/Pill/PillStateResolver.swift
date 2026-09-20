import Foundation

/// Everything that decides which of the eight shells is on screen.
struct PillInputs: Equatable, Sendable {
    var snapshot: UsageSnapshot?
    var pointerInside = false
    var isPinned = false
    /// A provider has crossed one of the two marks and nobody has looked yet.
    /// Whichever provider it was: the pill is one surface for the whole machine.
    var alert: ZoneAlert?
    /// The ghost is held this long after the pointer leaves, so crossing the
    /// notch on the way somewhere else does not snap it away mid-glance.
    var ghostHeldUntil: Date?
    /// How long a quiet spell has to run before the pill withdraws to the 3pt
    /// sliver. Zero never withdraws: the pill stays on screen through any amount
    /// of silence.
    var hidesAfterQuietMinutes = 5
    /// The newest activity across every tracked provider, which is what quiet is
    /// measured against. The pinned provider's own is not enough: a pill pinned
    /// to an idle one would withdraw while another was mid-turn.
    var lastActivity: Date?
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

/// One function, no scattered booleans. The design's seven states are mutually
/// exclusive, so deciding them in one place is what keeps them that way.
enum PillStateResolver {
    /// How long the ghost lingers once the pointer has gone.
    static let ghostFade: TimeInterval = 0.4

    static func resolve(_ inputs: PillInputs, at now: Date) -> PillState {
        // Off is off: no figures, no alerts, and hovering does not reveal any.
        if inputs.isPinned { return .pinned }

        if inputs.hidesAfterQuietMinutes > 0, nothingRunning(inputs, at: now) {
            // Dormant is about leaving the notch alone, not about putting the
            // figures out of reach: a pointer on dead space is someone asking,
            // and the last reading is still the answer. So it opens the same
            // card it opens at any other time.
            if inputs.pointerInside { return .hover }
            // The ghost is what is left of it on the way out: "fades out ~400ms
            // after the pointer leaves the notch", so crossing the notch on the
            // way somewhere else does not snap it away mid-glance.
            if let held = inputs.ghostHeldUntil, now < held { return .ghost }
            return .hidden
        }

        // Hovering is how a crossing is acknowledged, so it is checked first:
        // a pointer on the notch always opens the card, whatever is being said.
        if inputs.pointerInside { return .hover }

        // Held until somebody looks. The store clears it on hover and raises
        // each mark once per window, so this cannot nag.
        if inputs.alert != nil { return .warning }
        if let percent = inputs.snapshot?.sessionPercent, percent >= 100 { return .exhausted }
        return .collapsed
    }

    private static func nothingRunning(_ inputs: PillInputs, at now: Date) -> Bool {
        // Whichever is newer: the figure the store hands down covers every
        // tracked provider, and the pinned one's own covers a caller that has
        // not set it.
        let newest = [inputs.lastActivity, inputs.snapshot?.lastActivity].compactMap(\.self).max()
        guard let newest else { return true }
        return now.timeIntervalSince(newest) > Double(inputs.hidesAfterQuietMinutes) * 60
    }
}
