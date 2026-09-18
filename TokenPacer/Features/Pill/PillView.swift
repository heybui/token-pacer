import SwiftUI

struct PillView: View {
    let state: PillState
    let snapshot: UsageSnapshot?
    /// Every source the store has a reading for, in a stable order. The band
    /// shows the active one; the hover card compares them all.
    var providers: [UsageSnapshot] = []
    /// The mark the user chose. One value reaches the band and every card row, so
    /// they cannot end up drawing progress two different ways.
    var mark: Mark = .capsuleBar
    /// Whether the figure rides beside the mark out here. The card spells every
    /// figure out either way.
    var showsPercentage = true

    /// How wide the wings have to be for what is in them — the same measurement
    /// the model makes for the rect that takes clicks.
    private var wings: PillState.Wings {
        .of(
            state: state, snapshot: snapshot, mark: mark,
            hasBadge: attention != nil, showsPercentage: showsPercentage
        )
    }
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
        let shellSize = state.size(around: band, wings: wings)
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
            let shell = state.size(around: band, wings: wings)
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
        // Two wings, each taking half of what is left over, each leaning towards
        // the hardware. The slack lands on the outside — the flank is measured
        // from the wider wing, so the narrower one has room to spare, and pooled
        // beside the notch it left the mark pressed against the shell's own
        // rounded corner with a hand's width of nothing next to the camera.
        HStack(spacing: 0) {
            leadingWing
                .padding(.leading, PillState.leadingGutter)
                .padding(.trailing, PillState.notchClearance)
                .frame(maxWidth: .infinity, alignment: .trailing)

            notchGap

            trailingWing
                .padding(.leading, PillState.notchClearance)
                .padding(.trailing, PillState.trailingGutter)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The mark and its figure.
    private var leadingWing: some View {
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
                    OdometerText(text: wings.headline, size: 12, color: tone)
                }
            }
        }
    }

    /// The clock, and the badge when a refresh has failed.
    private var trailingWing: some View {
        HStack(spacing: PillState.markGap) {
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
        // 11 between lines. Each row is a whole reading — a provider, where it
        // stands, its week, its reset — and at 6 they stacked into a block the eye
        // had to take apart. The card sizes to its content, so the air costs
        // nothing but the height it is worth.
        VStack(alignment: .leading, spacing: 11) {
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
        // The band above is already a full menu-bar row of clearance, so the card
        // needs a line of air under it, not a margin. It was reading as a third
        // empty.
        .padding(.top, 4)
        .padding(.horizontal, 18)
        .padding(.bottom, 10)
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
        let shell = spansNotch ? state.size(around: band, wings: wings).width : state.size.width
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

    /// Each column is its widest content and no more, and the numeric ones are
    /// trailing so what slack is left falls between the columns rather than
    /// inside them. Left-aligned and oversized, every number sat at the far side
    /// of its own gap and the row read as four islands.
    static let wordmarkWidth: CGFloat = 48    // "COPILOT" at 9.5pt mono
    static let percentWidth: CGFloat = 28     // "100%"
    static let weekWidth: CGFloat = 28        // "100%"
    static let resetWidth: CGFloat = 42       // "12d 07h"
    /// 14, not the 8 the rest of the app uses between neighbours. These columns
    /// are not neighbours — each is a different kind of fact about the same line,
    /// and at 8 the bar ran into its own percentage and the three figures read as
    /// one string. The bar pays for it, which is the right pocket: it is the only
    /// column that can be any length at all.
    static let spacing: CGFloat = 14
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

            // The capsule bar whatever the menu bar is wearing. These rows are a
            // comparison — four readings down a column, on one domain — and that
            // is the job position on a line does better than any of the other
            // eleven. It is also the only mark that can take the width the card
            // has to give it. The choice in Preferences dresses the menu bar,
            // where space is the constraint; here it is not.
            CapsuleBar(
                percent: line.percent,
                weekPercent: line.weekPercent,
                width: barWidth,
                isBurning: line.isBurning
            )

            OdometerText(text: Format.percent(line.percent), size: 11, color: tone(line.percent))
                .frame(width: Self.percentWidth, alignment: .trailing)

            // The dot's own figure. Without it the second marker is a position
            // with no number, which is half a reading.
            Text(line.weekPercent == nil ? "" : Format.percent(line.weekPercent))
                .font(Typography.mono(9.5))
                .foregroundStyle(.white.opacity(0.5))
                .frame(width: Self.weekWidth, alignment: .trailing)

            Text(Format.countdown(to: line.resetsAt))
                .font(Typography.mono(9.5))
                .foregroundStyle(.white.opacity(0.42))
                .frame(width: Self.resetWidth, alignment: .trailing)
        }
    }
}
