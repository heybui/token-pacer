import Foundation

/// One line on the shared scale: what it is, where it is, and when it resets.
///
/// A provider's window and the weekly cap are the same shape of fact, so they are
/// the same row. The columns are fixed and the bar takes what is left, so every
/// row lines up down the card however wide the shell is — which is the whole
/// point of putting them on one scale.
struct ScaleLine: Identifiable {
    let id: String
    let label: String
    /// The provider's name in full. The row has room for a wordmark; the
    /// tooltips have room to say which product it is.
    var name: String = ""
    let percent: Double?
    let resetsAt: Date?
    /// The provider's weekly cap, drawn hollow on the same track.
    var weekPercent: Double?
    var isBurning = false
}
