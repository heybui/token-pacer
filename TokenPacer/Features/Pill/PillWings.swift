import SwiftUI

/// The mark and its figure, against the left gutter.
struct LeadingWing: View {
    let snapshot: UsageSnapshot?
    let mark: Mark
    let showsPercentage: Bool
    /// Weekly rather than session: the ghost is the pill dimmed onto the cap that
    /// is still moving.
    let isGhost: Bool
    /// The headline the model measured this wing for, so the drawing and the
    /// rect that takes clicks cannot disagree.
    let headline: String
    let tone: Color

    /// Nil until the first poll lands. On a cold start that reads hundreds of
    /// megabytes it is several seconds, and a fake 0% would be a lie.
    private var isLoading: Bool { snapshot == nil }

    var body: some View {
        // 12, not the row's usual 8: the bar ends in a capsule whose rounded cap
        // already eats two of those points, so at 8 the over zone sat against the
        // first digit of the percentage.
        HStack(spacing: PillState.markGap) {
            // The ring waits for a figure to mirror. Drawn while the logs are
            // still being read it is an empty track next to the word "reading",
            // and the pair does not fit a flank that holds one or the other.
            if isLoading {
                Text("reading…")
                    .font(Typography.mono(12))
                    .foregroundStyle(.white.opacity(0.4))
            } else {
                // The window alone. A second marker with no room for its number
                // is a mark nobody can read the meaning of, and the menu bar is
                // the one place where less is the whole product.
                MarkView(
                    mark: mark,
                    percent: isGhost ? snapshot?.weeklyPercent : snapshot?.sessionPercent,
                    isBurning: snapshot?.isBurning == true
                )
                if showsPercentage {
                    OdometerText(text: headline, size: 12, color: tone)
                }
            }
        }
    }
}

/// The clock, and the badge: a refresh that failed, or jobs working.
struct TrailingWing: View {
    let snapshot: UsageSnapshot?
    let isGhost: Bool
    /// Non-nil when the last refresh failed. The figure stays; it is marked
    /// unverified rather than hidden.
    let attention: String?
    let workingSessions: Int
    /// The slot's own spacing, measured by the model from the same badge.
    let badge: PillState.Badge?

    var body: some View {
        HStack(spacing: badge?.gap ?? PillState.markGap) {
            if let attention {
                AttentionBadge(message: attention, size: 10)
            } else if workingSessions > 0 {
                JobBadge(count: workingSessions)
            }
            if isGhost {
                Text("week")
                    .font(Typography.mono(11.5))
                    .foregroundStyle(.white.opacity(0.4))
            } else {
                OdometerText(
                    text: Format.countdown(to: snapshot?.resetsAt),
                    size: 11.5, color: .white.opacity(0.5), weight: .regular
                )
            }
        }
    }
}
