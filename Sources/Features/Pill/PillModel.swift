import Observation

@MainActor
@Observable
final class PillModel {
    var state: PillState = .collapsed {
        didSet { if state != oldValue { onStateChange?(state) } }
    }
    /// False on external displays and pre-notch Macs — the pill docks to the menu
    /// bar there instead of hiding behind hardware.
    var hasNotch: Bool = true

    @ObservationIgnored var onStateChange: ((PillState) -> Void)?
}
