import SwiftUI

struct PillView: View {
    let state: PillState
    let snapshot: UsageSnapshot?
    /// Every source the store has a reading for, in a stable order. The band
    /// shows the active one; the hover card compares them all.
    var providers: [UsageSnapshot] = []
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

    /// A percentage in every case, or the dashes that stand for one.
    ///
    /// Raw tokens used to stand in when no percentage could be had. They read as
    /// a figure of the same kind — a big number where a small one usually is —
    /// and they are on a scale nothing else on screen shares. `--` says the one
    /// true thing instead: this provider has not reported.
    private var headline: String {
        guard let snapshot else { return "--" }
        return Format.percent(isGhost ? snapshot.weeklyPercent : snapshot.sessionPercent)
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
        // Nil hands the height back to the content. Everything else keeps the
        // board's figure, which for a fixed layout is the point of having one.
        let fixedHeight: CGFloat? = state.fitsContent ? nil : shellSize.height
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
                .frame(width: shellSize.width, height: fixedHeight, alignment: .top)
                .transition(.identity)
        }
            .frame(width: shellSize.width, height: fixedHeight, alignment: .bottom)
            .clipShape(shape)
            // The shadow is cast by the shape itself, never by the composited
            // content. Flattening the content works only while SwiftUI can
            // rasterise all of it — the panel's ScrollView is AppKit-backed and
            // cannot be, so the group falls back to a layer shadow on its
            // bounding box and the square corners show through.
            .background {
                ZStack {
                    // Not applied at all when the state does not cast one, rather
                    // than applied clear: a `.shadow` is an offscreen pass whether
                    // or not anything comes out of it.
                    if state.castsShadow {
                        shape
                            .fill(.black)
                            .shadow(
                                color: .black.opacity(0.66),
                                radius: PillState.shadowRadius, y: PillState.shadowOffsetY
                            )
                    }
                    // Never inside that branch. An `if/else` gives the two arms
                    // separate identities, so opening the shell cross-faded one
                    // black into the other — both halfway through at the midpoint,
                    // leaving it a quarter see-through for the length of the
                    // spring. The fill is one view that never leaves; only the
                    // shadow behind it comes and goes.
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
                    stateBody.frame(
                        width: shell.width,
                        height: state.fitsContent ? nil : shell.height - band.height
                    )
                }
            }
        } else {
            stateBody.frame(
                width: state.size.width,
                height: state.fitsContent ? nil : state.size.height
            )
        }
    }

    private var notchBand: some View {
        Group {
            switch state {
            case .paused: pausedPill
            case .exhausted: exhaustedPill
            case .pinned: pinnedBand
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
                topInset: bodyTop, showsHeader: !spansNotch, onClose: onClose
            )
        default: collapsed
        }
    }

    /// The panel's own header, moved up into the band.
    ///
    /// The flanks carried the ring, the percentage and the countdown, and the
    /// panel's first row repeats all three at four times the size 20pt below —
    /// the same figures twice, with the label and the close button pushed down a
    /// row for it. The band holds the label and the button instead, and the panel
    /// starts at its ring.
    private var pinnedBand: some View {
        HStack(spacing: 7) {
            Text(Self.pinnedLabel(for: snapshot))
                .font(Typography.mono(9.5))
                .tracking(1.4)
                .foregroundStyle(.white.opacity(0.38))
            if let attention {
                AttentionBadge(message: attention, size: 10)
            }
            notchGap
            Button(action: onClose) {
                Text("✕")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.42))
                    .padding(.horizontal, 4)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, 11)
        .padding(.trailing, 13)
    }

    /// Shared with the panel, which still draws this row off a notched screen.
    static func pinnedLabel(for snapshot: UsageSnapshot?) -> String {
        guard let snapshot else { return "READING LOGS · PINNED" }
        return snapshot.isActive ? "SESSION ACTIVE · PINNED" : "WINDOW EMPTY · PINNED"
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
                .font(Typography.mono(11.5))
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
        // 12, not the row's usual 8: the bar ends in a capsule whose rounded cap
        // already eats two of those points, so at 8 the over zone sat against the
        // first digit of the percentage.
        HStack(spacing: 12) {
            // The ring waits for a figure to mirror. Drawn while the logs are
            // still being read it is an empty track next to the word "reading",
            // and the pair does not fit a flank that holds one or the other.
            if isLoading {
                Text("reading…")
                    .font(Typography.mono(12))
                    .foregroundStyle(.white.opacity(0.4))
            } else {
                // The board's default mark. The ring said how far along; this says
                // that and where the boundaries are, which is the question the
                // pill exists to answer at a glance.
                CapsuleBar(
                    percent: isGhost ? snapshot?.weeklyPercent : snapshot?.sessionPercent,
                    // Ghost is already showing the week; a hollow marker on top of
                    // it would be the same figure twice.
                    weekPercent: isGhost ? nil : snapshot?.weeklyPercent,
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
                    .font(Typography.mono(11.5))
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

    /// The reset, never a projection of when the window runs dry: that needed a
    /// conversion from tokens to points that no provider publishes.
    private var warningLine: String {
        "\(Format.countdown(to: snapshot?.resetsAt)) to reset · wrap up soon"
    }

    /// One row per provider, on the same scale.
    ///
    /// The band above already carries the active source; this is where the others
    /// become comparable — same capsules, same domain, each ending in its own
    /// reset, because 81% of a five-hour window and 81% of a week are not the same
    /// problem. A provider that reports nothing keeps its row and shows `--`:
    /// absent is a state worth seeing, and it is not the same as zero.
    private var hoverCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Kept even when the rows below say the same thing in figures. With
            // one provider tracked the card would otherwise be a single line, and
            // "Plenty of room" is the sentence the pill exists to say.
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(statusLine)
                    .font(Typography.sans(13, .semibold))
                    .foregroundStyle(.white)
                Spacer(minLength: 8)
                if let attention {
                    AttentionBadge(message: attention, size: 10)
                } else if let snapshot, snapshot.sessionPercent != nil {
                    // How old the figure is. Between readings the pill is showing
                    // the last one unmoved, and saying so is the difference
                    // between a stale number and a lying one.
                    Text(reportedLabel(snapshot))
                        .font(Typography.mono(9.5))
                        .foregroundStyle(.white.opacity(0.34))
                }
            }

            ForEach(scaleLines) { line in
                ScaleRow(line: line, barWidth: providerBarWidth)
            }
        }
        .padding(.top, bodyTop)
        .padding(.horizontal, 18)
        .padding(.bottom, 12)
    }

    /// Every window worth a row, in the order they belong to each other.
    ///
    /// The weekly cap is a provider's, not the app's: Claude states one and so
    /// does Codex, and they run out on different days. So the week follows its own
    /// provider rather than sitting once at the bottom, where it silently belonged
    /// to whichever source happened to be active.
    private var scaleLines: [ScaleLine] {
        providers.map { provider in
            ScaleLine(
                id: provider.source.rawValue,
                label: provider.source.wordmark,
                percent: provider.sessionPercent,
                resetsAt: provider.resetsAt,
                weekPercent: provider.weeklyPercent,
                isBurning: provider.isBurning
            )
        }
    }

    /// What is left for the bar once the row's fixed columns are paid for.
    private var providerBarWidth: CGFloat {
        let shell = spansNotch ? state.size(around: band).width : state.size.width
        return max(60, shell - ScaleRow.fixedColumns - 36)
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

}

/// One line on the shared scale: what it is, where it is, and when it resets.
///
/// A provider's window and the weekly cap are the same shape of fact, so they are
/// the same row. The columns are fixed and the bar takes what is left, so every
/// row lines up down the card however wide the shell is — which is the whole
/// point of putting them on one scale.
struct ScaleLine: Identifiable {
    let id: String
    let label: String
    let percent: Double?
    let resetsAt: Date?
    /// The provider's weekly cap, drawn hollow on the same track.
    var weekPercent: Double?
    var isBurning = false
}

private struct ScaleRow: View {
    let line: ScaleLine
    let barWidth: CGFloat

    static let wordmarkWidth: CGFloat = 54
    static let percentWidth: CGFloat = 40
    static let weekWidth: CGFloat = 34
    static let resetWidth: CGFloat = 52
    static let spacing: CGFloat = 8
    static var fixedColumns: CGFloat {
        wordmarkWidth + percentWidth + weekWidth + resetWidth + spacing * 4
    }

    @Environment(\.tone) private var tone

    var body: some View {
        HStack(spacing: Self.spacing) {
            Text(line.label)
                .font(Typography.mono(9.5, .semibold))
                .tracking(0.95)
                .foregroundStyle(.white.opacity(0.62))
                .frame(width: Self.wordmarkWidth, alignment: .leading)

            CapsuleBar(
                percent: line.percent,
                weekPercent: line.weekPercent,
                width: barWidth,
                isBurning: line.isBurning
            )

            OdometerText(text: Format.percent(line.percent), size: 11, color: tone(line.percent))
                .frame(width: Self.percentWidth, alignment: .leading)

            // The dot's own figure. Without it the second marker is a position
            // with no number, which is half a reading.
            Text(line.weekPercent == nil ? "" : Format.percent(line.weekPercent))
                .font(Typography.mono(9.5))
                .foregroundStyle(.white.opacity(0.5))
                .frame(width: Self.weekWidth, alignment: .leading)

            Text(Format.countdown(to: line.resetsAt))
                .font(Typography.mono(9.5))
                .foregroundStyle(.white.opacity(0.42))
                .frame(width: Self.resetWidth, alignment: .trailing)
        }
    }
}
