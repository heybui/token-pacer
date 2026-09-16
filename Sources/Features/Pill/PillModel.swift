import Foundation
import Observation

@MainActor
@Observable
final class PillModel {
    var inputs = PillInputs()

    private(set) var state: PillState = .collapsed { didSet { publishChrome() } }

    /// The design's menu is drawn below the shell, inside the same host, so the
    /// clickable area has to grow to cover it.
    private(set) var isMenuOpen = false { didSet { publishChrome() } }
    /// Set once by the view that owns the item list; the host needs the figure
    /// before the menu has drawn.
    var menuHeight: CGFloat = 0

    /// Shell plus menu: what the host must let clicks through to.
    var liveSize: CGSize {
        let shell = state.size
        guard isMenuOpen else { return shell }
        return CGSize(
            width: max(shell.width, PillState.menuWidth),
            height: shell.height + PillState.menuGap + menuHeight
        )
    }

    /// Esc closes both, and neither can hear it without the keyboard.
    var wantsKeyboard: Bool { state == .pinned || isMenuOpen }

    /// The user's thresholds, when there are any. Read at every decision rather
    /// than copied, so a slider takes effect on the next tick.
    @ObservationIgnored var preferences: Preferences?

    /// Recomputed whenever anything feeding the decision changes.
    func update(snapshot: UsageSnapshot?, at now: Date = Date()) {
        inputs.snapshot = snapshot
        if let preferences {
            inputs.criticalAt = preferences.criticalAt
            inputs.hideWhenDormant = preferences.hideWhenDormant
        }
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

    /// Right-click opens it in every state, the panel included — pausing or
    /// copying should not cost you the panel you just opened.
    func toggleMenu() { isMenuOpen.toggle() }

    func closeMenu() { isMenuOpen = false }

    func setPaused(_ paused: Bool, at now: Date = Date()) {
        inputs.isPaused = paused
        update(snapshot: inputs.snapshot, at: now)
    }

    func setPointerInside(_ inside: Bool, at now: Date = Date()) {
        inputs.pointerInside = inside
        // Leaving takes the menu with it. The menu sits inside the live area, so
        // hovering it still counts as inside and it does not close underneath you.
        if !inside { isMenuOpen = false }
        update(snapshot: inputs.snapshot, at: now)
    }
    /// False on external displays and pre-notch Macs — the pill docks to the menu
    /// bar there instead of hiding behind hardware.
    var hasNotch: Bool = true

    /// Called whenever the host's geometry or keyboard needs change.
    @ObservationIgnored var onChromeChange: ((CGSize, Bool) -> Void)?

    private func publishChrome() { onChromeChange?(liveSize, wantsKeyboard) }
}
