import SwiftUI

/// How many Claude Code background jobs are working right now.
///
/// Not a warning: nothing is wrong, work is simply happening out of sight. Blue
/// keeps it out of the tone scale — green, amber and red are how much of the
/// window is left, and a count that borrowed one of them would read as a figure
/// about usage.
struct JobBadge: View {
    let count: Int
    var size: CGFloat = 11

    private var label: String {
        count == 1 ? "1 background job is working" : "\(count) background jobs are working"
    }

    var body: some View {
        Text(count.formatted(.number))
            .font(Typography.mono(size, .semibold))
            .foregroundStyle(Tokens.blue)
            .help(label)
            .accessibilityLabel(label)
    }
}
