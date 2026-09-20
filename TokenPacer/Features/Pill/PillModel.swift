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

    /// What the wings hold right now. The view draws from the same figures, so
    /// the rect that takes clicks is the rect that was drawn.
    var wings: PillState.Wings {
        .of(
            state: state, snapshot: inputs.snapshot, mark: inputs.mark,
            badge: inputs.badge, showsPercentage: inputs.showsPercentage
        )
    }

    /// How tall the shell actually drew, for the states that size to their
    /// content. `PillState.size` is a floor for those — the card's rows are a
    /// list — and the hover rect is built from this, so a card taller than the
    /// floor no longer hangs outside the area that keeps it open.
    var contentHeight: CGFloat = 0 {
        didSet { if contentHeight != oldValue, state.fitsContent { publishChrome() } }
    }

    /// Shell plus menu: what the host must let clicks through to.
    var liveSize: CGSize {
        var shell = state.size(around: band, wings: wings)
        if state.fitsContent { shell.height = max(shell.height, contentHeight) }
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
    @ObservationIgnored private var ghostWithdrawal: Task<Void, Never>?

    /// Recomputed whenever anything feeding the decision changes.
    func update(snapshot: UsageSnapshot?, at now: Date = Date.now) {
        inputs.snapshot = snapshot
        if let preferences {
            inputs.hidesAfterQuietMinutes = preferences.hidesAfterQuietMinutes
        }
        state = PillStateResolver.resolve(inputs, at: now)
    }

    /// Clicking the pill pins the panel; collapse and Esc let it go. Seeing it
    /// acknowledges a warning, exactly as hovering does.
    func setPinned(_ pinned: Bool, at now: Date = Date.now) {
        inputs.isPinned = pinned
        if pinned { inputs.alert = nil }
        update(snapshot: inputs.snapshot, at: now)
    }

    func togglePinned(at now: Date = Date.now) { setPinned(!inputs.isPinned, at: now) }

    /// Right-click opens it in every state, the panel included — reaching
    /// Preferences should not cost you the panel you just opened.
    func toggleMenu() { isMenuOpen.toggle() }

    func closeMenu() { isMenuOpen = false }

    func setPointerInside(_ inside: Bool, at now: Date = Date.now) {
        inputs.pointerInside = inside
        if inside {
            inputs.ghostHeldUntil = nil
        } else {
            // Leaving takes the menu with it. The menu sits inside the live area,
            // so hovering it still counts as inside and it does not close
            // underneath you.
            isMenuOpen = false
            // Always, not only when a ghost was showing: hovering a dormant pill
            // opens the card now, so the state on the way out is `.hover` and the
            // fade would never have been scheduled. The hold is read only by the
            // dormant branch, so it costs a busy pill nothing.
            holdGhost(from: now)
        }
        update(snapshot: inputs.snapshot, at: now)
    }

    /// The 5s poll would not notice a 400ms boundary, so the withdrawal is what
    /// wakes the state back up.
    private func holdGhost(from now: Date) {
        inputs.ghostHeldUntil = now.addingTimeInterval(PillStateResolver.ghostFade)
        ghostWithdrawal?.cancel()
        ghostWithdrawal = Task { [weak self] in
            try? await Task.sleep(for: .seconds(PillStateResolver.ghostFade))
            guard !Task.isCancelled, let self else { return }
            update(snapshot: inputs.snapshot)
        }
    }
    /// The band on the screen the pill is docked to — the menu bar row, with a
    /// notch across it on a screen that has one. Empty only where no row is
    /// reported, and there the shell is the size the board drew.
    var band = NotchBand() { didSet { publishChrome() } }

    /// Called whenever the host's geometry or keyboard needs change.
    @ObservationIgnored var onChromeChange: ((CGSize, Bool) -> Void)?

    private func publishChrome() { onChromeChange?(liveSize, wantsKeyboard) }
}
