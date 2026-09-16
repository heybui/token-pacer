import Foundation
import Observation

@MainActor
@Observable
final class PillModel {
    var inputs = PillInputs()

    private(set) var state: PillState = .collapsed {
        didSet { if state != oldValue { onStateChange?(state) } }
    }

    /// Recomputed whenever anything feeding the decision changes.
    func update(snapshot: UsageSnapshot?, at now: Date = Date()) {
        inputs.snapshot = snapshot
        // Seeing the pill expanded counts as acknowledging the warning, so it
        // fires once per window rather than every poll.
        if inputs.pointerInside { inputs.warningAcknowledged = true }
        // A reset clears the acknowledgement: the next window warns again.
        if let percent = snapshot?.sessionPercent, percent < inputs.criticalAt {
            inputs.warningAcknowledged = false
        }
        state = PillStateResolver.resolve(inputs, at: now)
    }

    /// Clicking the pill pins the panel; ✕ and Esc let it go. Seeing the panel
    /// acknowledges a warning, exactly as hovering does.
    func setPinned(_ pinned: Bool, at now: Date = Date()) {
        inputs.isPinned = pinned
        if pinned { inputs.warningAcknowledged = true }
        update(snapshot: inputs.snapshot, at: now)
    }

    func togglePinned(at now: Date = Date()) { setPinned(!inputs.isPinned, at: now) }

    func setPointerInside(_ inside: Bool, at now: Date = Date()) {
        inputs.pointerInside = inside
        update(snapshot: inputs.snapshot, at: now)
    }
    /// False on external displays and pre-notch Macs — the pill docks to the menu
    /// bar there instead of hiding behind hardware.
    var hasNotch: Bool = true

    @ObservationIgnored var onStateChange: ((PillState) -> Void)?
}
