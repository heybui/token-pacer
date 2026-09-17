import SwiftUI

/// The tone rule with the user's own thresholds in it.
///
/// `Tokens.tone` still holds the rule; this carries the two numbers to every view
/// that applies it, so the session ring, the weekly bar, the splits and the
/// history grid can never disagree about where amber starts.
struct ToneScale: Equatable, Sendable {
    var warnAt: Double = 75
    var critAt: Double = 90

    func callAsFunction(_ percent: Double?) -> Color {
        Tokens.tone(percent ?? 0, warnAt: warnAt, critAt: critAt)
    }
}

extension EnvironmentValues {
    @Entry var tone = ToneScale()
}
