import SwiftUI

struct PillView: View {
    let state: PillState
    let snapshot: UsageSnapshot?
    /// Non-nil when the last refresh failed. The figure stays; it is marked
    /// unverified rather than hidden.
    var attention: String?
    /// Nil until the first poll lands. On a cold start that reads hundreds of
    /// megabytes it is several seconds, and a fake 0% would be a lie.
    var isLoading: Bool { snapshot == nil }

    private var tone: Color {
        guard let percent = snapshot?.sessionPercent else { return .white.opacity(0.5) }
        return Tokens.tone(percent)
    }

    /// Percentage when one can be trusted, raw tokens when it can't.
    private var headline: String {
        guard let snapshot else { return "--" }
        return snapshot.sessionPercent == nil
            ? Format.tokens(snapshot.sessionTokens)
            : Format.percent(snapshot.sessionPercent)
    }

    var body: some View {
        VStack(spacing: 0) {
            shell
            Spacer(minLength: 0)
        }
        .frame(width: PillState.hostSize.width, height: PillState.hostSize.height)
    }

    private var shell: some View {
        content
            .frame(width: state.size.width, height: state.size.height)
            .background(.black, in: shape)
            .overlay { shape.strokeBorder(state == .collapsed ? Tokens.shellRingIdle : Tokens.shellRingOpen, lineWidth: 1) }
            .clipShape(shape)
            // Without this the shadow is cast from the unclipped rectangular
            // bounds, so the square corners show through where the rounded ones
            // cut away. Flattening first makes the shadow follow the real shape.
            .compositingGroup()
            .shadow(color: .black.opacity(0.66), radius: 31, y: 22)
            .opacity(state.opacity)
            .animation(Tokens.spring, value: state)
    }

    private var shape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            bottomLeadingRadius: state.cornerRadius,
            bottomTrailingRadius: state.cornerRadius
        )
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .hover, .warning: hoverCard
        default: collapsed
        }
    }

    private var collapsed: some View {
        HStack(spacing: 8) {
            UsageRing(percent: snapshot?.sessionPercent, tone: tone, size: 17, lineWidth: 3)
            Text(isLoading ? "reading logs" : headline)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(isLoading ? .white.opacity(0.4) : tone)

            Spacer(minLength: 12)

            if let attention {
                AttentionBadge(message: attention, size: 10)
            } else if let snapshot, snapshot.isActive {
                Circle().fill(tone).frame(width: 5, height: 5)
            }
            Text(Format.countdown(to: snapshot?.resetsAt))
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(.white.opacity(0.5))
        }
        .padding(.leading, 11)
        .padding(.trailing, 13)
    }

    private var hoverCard: some View {
        HStack(spacing: 15) {
            UsageRing(
                percent: snapshot?.sessionPercent, tone: tone,
                size: 46, lineWidth: 6,
                label: isLoading ? nil : headline
            )
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(statusLine)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                    Spacer(minLength: 14)
                    Text("\(Format.countdown(to: snapshot?.resetsAt)) left")
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.5))
                }
                HStack(spacing: 6) {
                    if let attention {
                        AttentionBadge(message: attention, size: 10)
                    }
                    Text(detailLine)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(attention == nil ? .white.opacity(0.42) : Tokens.amber.opacity(0.9))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
        }
        .padding(.top, 26)
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
    }

    private var statusLine: String {
        guard let percent = snapshot?.sessionPercent else { return "Measuring" }
        return percent >= 90 ? "Wrap up soon" : percent >= 75 ? "Running hot" : "Plenty of room"
    }

    private var detailLine: String {
        if let attention { return attention }
        guard let snapshot else { return "reading logs…" }
        let origin = switch snapshot.origin {
        case .authoritative: "reported"
        case .inferred: "estimated"
        case .unknown: "no ceiling yet"
        }
        let headroom = snapshot.burn.headroomMinutes.map { " · ~\($0) min headroom" } ?? ""
        return "\(snapshot.source.displayName) · \(origin)\(headroom)"
    }
}
