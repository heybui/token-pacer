import SwiftUI

struct PillView: View {
    let state: PillState
    let snapshot: UsageSnapshot?
    /// Non-nil when the last refresh failed. The figure stays; it is marked
    /// unverified rather than hidden.
    var attention: String?
    /// Cross-source split, drawn only by the pinned panel.
    var bySource: [UsageSplit] = []
    var onTogglePinned: () -> Void = {}
    var onClose: () -> Void = {}
    var isMenuOpen = false
    var menuItems: [NotchMenuItem] = []
    var onCloseMenu: () -> Void = {}
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
        if isGhost { return Format.percent(snapshot.weeklyPercent) }
        return snapshot.sessionPercent == nil
            ? Format.tokens(snapshot.sessionTokens)
            : Format.percent(snapshot.sessionPercent)
    }

    var body: some View {
        VStack(spacing: 0) {
            shell
            if isMenuOpen {
                NotchMenuView(items: menuItems, onDismiss: onCloseMenu)
                    .padding(.top, PillModel.menuGap)
            }
            Spacer(minLength: 0)
        }
        .frame(width: PillState.hostSize.width, height: PillState.hostSize.height)
        .animation(.easeOut(duration: 0.16), value: isMenuOpen)
    }

    private var shell: some View {
        content
            .frame(width: state.size.width, height: state.size.height)
            .clipShape(shape)
            // The shadow is cast by the shape itself, never by the composited
            // content. Flattening the content works only while SwiftUI can
            // rasterise all of it — the panel's ScrollView is AppKit-backed and
            // cannot be, so the group falls back to a layer shadow on its
            // bounding box and the square corners show through.
            .background {
                shape
                    .fill(.black)
                    .shadow(
                        color: .black.opacity(0.66),
                        radius: PillState.shadowRadius, y: PillState.shadowOffsetY
                    )
            }
            .overlay { shape.strokeBorder(state == .collapsed ? Tokens.shellRingIdle : Tokens.shellRingOpen, lineWidth: 1) }
            .opacity(state.opacity)
            .animation(Tokens.spring, value: state)
            // The panel has its own controls; a tap anywhere inside it would
            // fight them. Only the small states pin.
            .onTapGesture { if state != .pinned { onTogglePinned() } }
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
        case .dormant: Color.clear
        case .paused: pausedPill
        case .exhausted: exhaustedPill
        case .warning: warningCard
        case .hover: hoverCard
        case .pinned:
            PinnedPanelView(
                snapshot: snapshot, bySource: bySource, attention: attention, onClose: onClose
            )
        default: collapsed
        }
    }

    /// Grey, no numbers: tracking is off, which is not the same as idle.
    private var pausedPill: some View {
        HStack(spacing: 8) {
            HStack(spacing: 3) {
                ForEach(0..<2, id: \.self) { _ in
                    Capsule().fill(.white.opacity(0.45)).frame(width: 3, height: 11)
                }
            }
            Text("paused")
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(.white.opacity(0.45))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 11)
    }

    /// At 100% there is nothing to report but the wait.
    private var exhaustedPill: some View {
        HStack(spacing: 10) {
            Circle().fill(Tokens.red).frame(width: 6, height: 6)
            OdometerText(text: Format.countdown(to: snapshot?.resetsAt), size: 12, color: Tokens.red)
        }
        .padding(.horizontal, 16)
    }

    /// Ghost is the collapsed pill dimmed, showing the weekly cap rather than a
    /// session that is no longer burning.
    private var isGhost: Bool { state == .ghost }

    private var collapsed: some View {
        HStack(spacing: 8) {
            UsageRing(
                percent: isGhost ? snapshot?.weeklyPercent : snapshot?.sessionPercent,
                tone: tone, size: 17, lineWidth: 3
            )
            if isLoading {
                Text("reading logs")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.4))
            } else {
                OdometerText(text: headline, size: 12, color: tone)
            }

            Spacer(minLength: 12)

            if let attention {
                AttentionBadge(message: attention, size: 10)
            } else if !isGhost {
                // Always present; it pulses only while the logs are growing.
                PulsingDot(color: tone, isPulsing: snapshot?.isBurning == true)
            }
            if isGhost {
                Text("week")
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.4))
            } else {
                OdometerText(
                    text: Format.countdown(to: snapshot?.resetsAt),
                    size: 11.5, color: .white.opacity(0.5), weight: .regular
                )
            }
        }
        .padding(.leading, 11)
        .padding(.trailing, 13)
    }

    /// Fires once when the window crosses critical: the figure big enough to read
    /// from across the desk, and the one number that matters — how long is left.
    ///
    /// No dismiss button by design: mousing over it acknowledges, and it never
    /// re-fires for this window.
    private var warningCard: some View {
        HStack(spacing: 16) {
            UsageRing(percent: snapshot?.sessionPercent, tone: Tokens.red, size: 48, lineWidth: 6)
            VStack(alignment: .leading, spacing: 4) {
                OdometerText(text: headline, size: 26, color: Tokens.red)
                Text(warningLine)
                    .font(Typography.sans(12.5))
                    .foregroundStyle(.white.opacity(0.66))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 26)
        .padding(.horizontal, 20)
        .padding(.bottom, 16)
    }

    /// Headroom when it can be measured, the reset when it can't — never both,
    /// and never a bare "wrap up soon" with no figure behind it.
    private var warningLine: String {
        if let headroom = snapshot?.burn.headroomMinutes {
            return "~\(headroom) min left · wrap up soon"
        }
        return "\(Format.countdown(to: snapshot?.resetsAt)) to reset · wrap up soon"
    }

    private var hoverCard: some View {
        HStack(spacing: 15) {
            UsageRing(
                percent: snapshot?.sessionPercent, tone: tone,
                size: 46, lineWidth: 6,
                label: isLoading ? nil : headline
            )
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text(statusLine)
                        .font(Typography.sans(13, .semibold))
                        .foregroundStyle(.white)
                    Spacer(minLength: 14)
                    HStack(spacing: 7) {
                        // Carried over from the collapsed pill: the countdown keeps
                        // its activity dot when the shell grows.
                        PulsingDot(color: tone, isPulsing: snapshot?.isBurning == true)
                        HStack(spacing: 4) {
                            OdometerText(
                                text: Format.countdown(to: snapshot?.resetsAt),
                                size: 11.5, color: .white.opacity(0.5), weight: .regular
                            )
                            Text("left")
                                .font(Typography.mono(11.5))
                                .foregroundStyle(.white.opacity(0.5))
                        }
                    }
                }

                CapBar(
                    percent: snapshot?.weeklyPercent,
                    tone: Tokens.tone(snapshot?.weeklyPercent ?? 0),
                    height: 4
                )

                HStack(spacing: 6) {
                    if let attention {
                        AttentionBadge(message: attention, size: 10)
                    }
                    Text(detailLine)
                        .font(Typography.mono(10.5))
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

    /// "reported" alone would imply the figure was just read. Between anchors it
    /// is that reading carried forward by local token flow, so say how old it is.
    private func reportedLabel(_ snapshot: UsageSnapshot) -> String {
        guard let confirmedAt = snapshot.confirmedAt else { return "reported" }
        let minutes = Int(Date().timeIntervalSince(confirmedAt) / 60)
        return minutes < 1 ? "reported" : "reported \(minutes)m ago"
    }

    private var statusLine: String {
        guard let percent = snapshot?.sessionPercent else { return "Measuring" }
        return percent >= 90 ? "Wrap up soon" : percent >= 75 ? "Running hot" : "Plenty of room"
    }

    private var detailLine: String {
        if let attention { return attention }
        guard let snapshot else { return "reading logs…" }

        let origin = switch snapshot.origin {
        case .authoritative: reportedLabel(snapshot)
        case .inferred: "estimated"
        case .unknown: "no ceiling yet"
        }
        var parts = ["Week \(Format.percent(snapshot.weeklyPercent))"]
        if let rate = snapshot.burn.percentPerHour, rate > 0 {
            parts.append("\(Int(rate.rounded()))%/hr")
        }
        if let headroom = snapshot.burn.headroomMinutes {
            parts.append("~\(headroom) min headroom")
        }
        parts.append(origin)
        return parts.joined(separator: " · ")
    }
}
