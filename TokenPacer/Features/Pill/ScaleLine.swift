import Foundation

/// One line on the shared scale: what it is, where it is, and when it resets.
///
/// A provider's window and the weekly cap are the same shape of fact, so they are
/// the same row. The columns are fixed and the bar takes what is left, so every
/// row lines up down the card however wide the shell is — which is the whole
/// point of putting them on one scale.
struct ScaleLine: Identifiable {
    let id: String
    /// Whose row this is. The marks are per provider, so the colours are too.
    var source: SourceID = .claude
    let label: String
    /// The provider's name in full. The row has room for a wordmark; the
    /// tooltips have room to say which product it is.
    var name: String = ""
    let percent: Double?
    let resetsAt: Date?
    /// How long each of the two windows runs, for the captions that name them.
    /// A row is not always a five-hour window and a week.
    var windowMinutes: Int?
    var weekWindowMinutes: Int?
    /// The provider's longer cap, drawn hollow on the same track.
    var weekPercent: Double?
    var isBurning = false
    /// Whether the menu bar is carrying this provider, and how many sessions it
    /// has answering right now.
    var isPinned = false
    var jobs = 0
    /// Why this provider's figures cannot be trusted, when they cannot — the
    /// poller's own words. The row keeps whatever it last knew and says this
    /// underneath, because a blank row tells the user less than a stale one.
    var attention: String?
}
