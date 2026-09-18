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
    /// The menu bar row the shell sits in, and the notch it wraps when there is
    /// one. Empty only on a screen reporting no row at all.
    var band = NotchBand()

    /// Whether this state is drawn around the notch at all. Dormant never is:
    /// "no activity" means the notch reads as stock hardware.
    private var spansNotch: Bool { !band.isEmpty && state != .dormant }

    /// The board's 26pt was clearance for the notch. With a band above carrying
    /// that, the body opens right under the hardware instead.
    private var bodyTop: CGFloat {
        spansNotch ? PillState.bandedBodyTop : PillState.boardBodyTop
    }
    /// Nil until the first poll lands. On a cold start that reads hundreds of
    /// megabytes it is several seconds, and a fake 0% would be a lie.
    var isLoading: Bool { snapshot == nil }

    @Environment(\.tone) private var toneScale

    private var tone: Color {
        guard let percent = snapshot?.sessionPercent else { return .white.opacity(0.5) }
        return toneScale(percent)
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
                    .padding(.top, PillState.menuGap)
            }
        }
        .animation(.easeOut(duration: 0.16), value: isMenuOpen)
        .frame(
            width: PillState.hostSize(around: band).width,
            height: PillState.hostSize(around: band).height,
            alignment: .top
        )
    }

    private var shell: some View {
        let shellSize = state.size(around: band)
        return ZStack(alignment: .bottom) {
            // Revealed, not cross-faded, and above all not rebuilt. The shell's
            // frame springs open and the whole thing is clipped to that shape,
            // so content that stays put is uncovered as the box grows — one
            // object expanding.
            //
            // No `.id(state)` here. Keying the content on the state gave it a
            // fresh identity on every change, so SwiftUI tore the subtree down
            // and built a new one — and every rebuilt child then replayed its
            // own entrance: `OdometerText` fades in over 0.34s, `UsageRing` and
            // `CapBar` sweep their value up from zero. The band row is the same
            // row in all three states, so the ring and the countdown blanked for
            // a few frames and faded back in while the box grew. Without the id
            // that row is never removed; only the body below it swaps, and it
            // swaps instantly.
            content
                // Top-aligned: a flank-filling state is shorter than its shell by
                // the overhang, and that slack belongs below the band, not split
                // either side of it.
                .frame(width: shellSize.width, height: shellSize.height, alignment: .top)
                .transition(.identity)
        }
            .frame(width: shellSize.width, height: shellSize.height, alignment: .bottom)
            .clipShape(shape)
            // The shadow is cast by the shape itself, never by the composited
            // content. Flattening the content works only while SwiftUI can
            // rasterise all of it — the panel's ScrollView is AppKit-backed and
            // cannot be, so the group falls back to a layer shadow on its
            // bounding box and the square corners show through.
            .background {
                // Not applied at all when the state does not cast one, rather
                // than applied clear: a `.shadow` is an offscreen pass whether or
                // not anything comes out of it.
                if state.castsShadow {
                    shape
                        .fill(.black)
                        .shadow(
                            color: .black.opacity(0.66),
                            radius: PillState.shadowRadius, y: PillState.shadowOffsetY
                        )
                } else {
                    shape.fill(.black)
                }
            }
            .overlay { shape.strokeBorder(state == .collapsed ? Tokens.shellRingIdle : Tokens.shellRingOpen, lineWidth: 1) }
            .overlay {
                // Not on the pinned panel: a 752×540 sheet with a light running
                // round it is a screensaver, and the panel is for reading.
                if chasesBorder {
                    ChasingBorder(
                        cornerRadius: state.cornerRadius, tone: tone,
                        isRunning: snapshot?.isBurning == true
                    )
                }
            }
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

    /// The band that spans the hardware, and the body that hangs below it.
    ///
    /// Every state shows the same figures in the flanks, because the strips
    /// either side of the notch are the one part of the shell that does not
    /// change size. States that fit there have no body at all.
    @ViewBuilder
    private var content: some View {
        if spansNotch {
            // The shell's width, never the board's: the band fixed the width at
            // the flanks, and a body still cut to 404 overflowed it by 18pt each
            // side — clipped by the shell, so the first and last characters of
            // every line were simply gone.
            let shell = state.size(around: band)
            VStack(spacing: 0) {
                notchBand
                if !state.fillsFlanks {
                    stateBody.frame(width: shell.width, height: shell.height - band.height)
                }
            }
        } else {
            stateBody.frame(width: state.size.width, height: state.size.height)
        }
    }

    private var notchBand: some View {
        Group {
            switch state {
            case .paused: pausedPill
            case .exhausted: exhaustedPill
            default: collapsed
            }
        }
        .frame(height: band.height)
    }

    /// The hardware's own footprint, held open in the middle of the band.
    /// Content is laid out either side of it, never across it. Off a notched
    /// screen it collapses to the gap the board drew.
    @ViewBuilder
    private var notchGap: some View {
        Spacer(minLength: spansNotch ? 0 : 12)
        if spansNotch {
            Color.clear.frame(width: band.notchWidth)
            Spacer(minLength: 0)
        }
    }

    /// What the state draws below the band — or, off a notched screen, the whole
    /// shell.
    @ViewBuilder
    private var stateBody: some View {
        switch state {
        case .dormant: Color.clear
        case .paused: pausedPill
        case .exhausted: exhaustedPill
        case .warning: warningCard
        case .hover: hoverCard
        case .pinned:
            PinnedPanelView(
                snapshot: snapshot, bySource: bySource, attention: attention,
                topInset: bodyTop, onClose: onClose
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
            notchGap
        }
        .padding(.horizontal, 11)
    }

    /// At 100% there is nothing to report but the wait.
    private var exhaustedPill: some View {
        HStack(spacing: 10) {
            Circle().fill(Tokens.red).frame(width: 6, height: 6)
            OdometerText(text: Format.countdown(to: snapshot?.resetsAt), size: 12, color: Tokens.red)
            notchGap
        }
        .padding(.horizontal, 16)
    }

    /// Ghost is the collapsed pill dimmed, showing the weekly cap rather than a
    /// session that is no longer burning.
    private var isGhost: Bool { state == .ghost }

    /// Collapsed and expanded, never pinned — and never while the notch is
    /// pretending to be stock hardware.
    private var chasesBorder: Bool {
        switch state {
        case .pinned, .dormant, .ghost, .paused: false
        case .collapsed, .hover, .warning, .exhausted: true
        }
    }

    private var collapsed: some View {
        HStack(spacing: 8) {
            // The ring waits for a figure to mirror. Drawn while the logs are
            // still being read it is an empty track next to the word "reading",
            // and the pair does not fit a flank that holds one or the other.
            if isLoading {
                Text("reading…")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.4))
            } else {
                UsageRing(
                    percent: isGhost ? snapshot?.weeklyPercent : snapshot?.sessionPercent,
                    tone: tone, size: 17, lineWidth: 3,
                    isBurning: snapshot?.isBurning == true
                )
                OdometerText(text: headline, size: 12, color: tone)
            }

            notchGap

            if let attention {
                AttentionBadge(message: attention, size: 10)
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
            UsageRing(
                percent: snapshot?.sessionPercent, tone: Tokens.red, size: 48, lineWidth: 6,
                isBurning: snapshot?.isBurning == true
            )
            VStack(alignment: .leading, spacing: 4) {
                OdometerText(text: headline, size: 26, color: Tokens.red)
                Text(warningLine)
                    .font(Typography.sans(12.5))
                    .foregroundStyle(.white.opacity(0.66))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.top, bodyTop)
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
            // Off a notched screen the card carries its own ring and countdown.
            // On one the band above already has both, and a second copy 15pt
            // below the first is just the same number twice.
            if !spansNotch {
                UsageRing(
                    percent: snapshot?.sessionPercent, tone: tone,
                    size: 46, lineWidth: 6,
                    label: isLoading ? nil : headline,
                    isBurning: snapshot?.isBurning == true
                )
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text(statusLine)
                        .font(Typography.sans(13, .semibold))
                        .foregroundStyle(.white)
                    Spacer(minLength: 14)
                    if !spansNotch {
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
                    tone: toneScale(snapshot?.weeklyPercent),
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
        .padding(.top, bodyTop)
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
        if percent >= toneScale.critAt { return "Wrap up soon" }
        return percent >= toneScale.warnAt ? "Running hot" : "Plenty of room"
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
        if let burn = Format.burn(snapshot.burn) { parts.append(burn) }
        parts.append(origin)
        return parts.joined(separator: " · ")
    }
}
