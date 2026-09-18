import SwiftUI

/// How many Claude Code sessions are stopped, waiting for an answer.
///
/// Not a warning: nothing is wrong, somebody is simply holding the door. Blue
/// keeps it out of the tone scale — green, amber and red are how much of the
/// window is left, and a count that borrowed one of them would read as a figure
/// about usage.
struct WaitingBadge: View {
    let count: Int
    var size: CGFloat = 11

    private var label: String {
        count == 1 ? "1 session is waiting for input" : "\(count) sessions are waiting for input"
    }

    var body: some View {
        Text(count.formatted(.number))
            .font(Typography.mono(size, .semibold))
            .foregroundStyle(Tokens.blue)
            .help(label)
            .accessibilityLabel(label)
    }
}
