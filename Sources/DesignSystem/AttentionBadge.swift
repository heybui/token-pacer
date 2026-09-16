import SwiftUI

/// Shown when the live number could not be confirmed — a failed usage request,
/// an unreadable log directory.
///
/// It never replaces the figure. The pill keeps showing the last good value and
/// flags that it is unverified, because a blank pill tells the user less than a
/// stale one does.
struct AttentionBadge: View {
    let message: String
    var size: CGFloat = 11

    var body: some View {
        Image(systemName: "exclamationmark.triangle.fill")
            .font(.system(size: size))
            .foregroundStyle(Tokens.amber)
            .help(message)
            .accessibilityLabel("Usage data unconfirmed: \(message)")
    }
}
