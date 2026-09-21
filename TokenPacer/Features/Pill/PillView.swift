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
    /// Which light runs the outline while a model is answering, and whether any
    /// does. One switch gates the whole group, as the board asks.
    var border: BorderEffect = .comet
    var bordersOn = true

    /// How wide the wings have to be for what is in them — the same measurement
    /// the model makes for the rect that takes clicks.
    private var wings: PillState.Wings {
        .of(
            state: state, snapshot: snapshot, mark: mark,
            badge: badge, showsPercentage: showsPercentage
        )
    }
    /// Non-nil when the last refresh failed. The figure stays; it is marked
    /// unverified rather than hidden.
    var attention: String?
    /// The same, per provider, for the card's rows.
    var errors: [SourceID: String] = [:]
    /// The card's own controls: which provider the strip carries, what each has
    /// running, and how the first of those is changed.
    /// Anything running anywhere, which is what the border answers to — not the
    /// pinned provider's own figure, the way the mark beside it does.
    var isAnyoneWorking = false
    /// And whose figure it takes its colour from: the provider that is actually
    /// running. A light in the pinned provider's green, running because Codex is
    /// nearly out, is the wrong news in the right place.
    var running: UsageSnapshot?
    /// The crossing on screen, and the provider it belongs to — which is not
    /// always the one the pill reports.
    var alert: ZoneAlert?
    var alerting: UsageSnapshot?
    /// Which provider the pinned panel is reading about, when it is not the
    /// pinned one. Held here because the control that changes it sits in the
    /// band around the notch, which this view owns, while the figures it changes
    /// are drawn by the panel below.
    @State private var viewing: SourceID?
    var pinned: SourceID?
    var jobsBySource: [SourceID: Int] = [:]
    /// Every provider's own two marks, for the rows and the panel: the pill's
    /// own chrome is already drawn in the pinned provider's.
    var zones: [SourceID: ToneScale] = [:]
    var onPin: (SourceID) -> Void = { _ in }
    /// Sessions with work in flight — anywhere on the machine, not only in this
    /// project, and across every tracked provider. Their own windows are behind something; the pill is
    /// the one thing always in sight that can say they are running at all.
    var workingSessions = 0
    /// The version a background check downloaded, when one is waiting. Last in
    /// the slot: see `PillState.Badge.update`.
    var updateVersion: String?
    /// Bring Sparkle's own window forward, which is where installing happens.
    var onInstallUpdate: () -> Void = {}

    /// One slot; the order lives on `Badge` so the wing is measured for
    /// whatever this draws.
    private var badge: PillState.Badge? {
        .of(attention: attention, workingSessions: workingSessions, updateVersion: updateVersion)
    }
    var onTogglePinned: () -> Void = {}
    var onClose: () -> Void = {}
    /// How tall the content drew. The card sizes to its rows, so only the view
    /// knows the figure the hover rect has to match.
    var onContentHeight: (CGFloat) -> Void = { _ in }
    /// Same menu the right-click opens; the hover card has a button for it.
    var onOpenSettings: () -> Void = {}
    /// Ask every provider again, from the card's own headline.
    var onRecheck: () -> Void = {}
    var isMenuOpen = false
    var menuItems: [NotchMenuItem] = []
    var onCloseMenu: () -> Void = {}
    /// The menu bar row the shell sits in, and the notch it wraps when there is
    /// one. Empty only on a screen reporting no row at all.
    var band = NotchBand()

    /// Whether this state is drawn around the notch at all. Hidden never is:
    /// "no activity" means the notch reads as stock hardware.
    private var spansNotch: Bool { !band.isEmpty && state != .hidden }

    /// The board's 26pt was clearance for the notch. With a band above carrying
    /// that, the body opens right under the hardware instead.
    private var bodyTop: CGFloat {
        spansNotch ? PillState.bandedBodyTop : PillState.boardBodyTop
    }
    @Environment(\.tone) private var toneScale

    /// The running provider's own marks and its own figure, falling back to the
    /// pinned one while nothing is running — the light is out then anyway, and a
    /// colour still has to be handed over.
    private var borderScale: ToneScale {
        running.flatMap { zones[$0.source] } ?? toneScale
    }

    private var borderPercent: Double? {
        (running ?? snapshot)?.sessionPercent
    }

    /// What the figure under the pointer means. The card is the only place with
    /// room to say it, and a system tooltip never appears here: the panel never
    /// activates, so AppKit never draws one.
    @State private var caption: String?

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
        // The board's largest state, always — never the window's current size.
        // The window tracks the state now (`NotchController.fit`), and feeding
        // that back into SwiftUI's bounds re-laid the tree out in the middle of
        // the morph: the shell jumped between sizes instead of springing. The
        // hosting view keeps this frame and `NotchClipView` holds it steady while
        // the window changes around it.
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
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { onContentHeight($0) }
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
                        cornerRadius: state.cornerRadius,
                        tone: borderScale(borderPercent),
                        light: borderScale.light(borderPercent),
                        effect: border,
                        isRunning: isAnyoneWorking
                    )
                }
            }
            .opacity(state.opacity)
            .animation(Tokens.spring, value: state)
            // Two clicks, not one. The band sits in the menu bar, which is a
            // strip people click at all day; a single click opened the whole
            // panel by accident often enough to be the thing you noticed about
            // the app. The card says so while it is open.
            //
            // And it closes the same way it opened. The panel's own controls
            // take single clicks, so a double click inside it is not aimed at
            // any of them — it is the gesture that got you here, used again.
            .onTapGesture(count: 2) { onTogglePinned() }
            // The detour dies with the panel: it used to be state inside the
            // panel's own view, which SwiftUI threw away when the panel closed.
            .onChange(of: state) { _, state in
                if state != .pinned { viewing = nil }
            }
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
            case .exhausted: exhaustedPill
            case .pinned: pinnedBand
            default: collapsed
            }
        }
        .frame(height: band.height)
        // Above the body, not merely before it. The provider list drops out of
        // this row and the body is the next sibling in the stack, so without
        // this the panel's own hero mark painted straight over the open list.
        .zIndex(1)
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
        case .hidden: Color.clear
        case .exhausted: exhaustedPill
        case .warning:
            WarningCard(
                alert: alert, snapshot: alerting ?? snapshot, mark: mark, topInset: bodyTop
            )
        case .hover:
            HoverCard(
                snapshot: snapshot, providers: providers,
                attention: attention, errors: errors,
                pinned: pinned, jobs: jobsBySource, zones: zones,
                updateVersion: updateVersion, onPin: onPin,
                barWidth: providerBarWidth,
                onExpand: onTogglePinned, onOpenSettings: onOpenSettings, onRecheck: onRecheck,
                onInstallUpdate: onInstallUpdate
            )
        case .pinned:
            PinnedPanelView(
                snapshot: snapshot, providers: providers, errors: errors, zones: zones,
                viewing: $viewing,
                mark: mark, attention: attention,
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
            // The title is the provider's name, and the name is the control: one
            // row at the top of the panel rather than a title with a row of tabs
            // under it.
            ProviderPicker(
                providers: providers,
                shown: viewing ?? snapshot?.source,
                zones: zones,
                onPick: { viewing = $0 == snapshot?.source ? nil : $0 }
            )
            if let attention {
                AttentionBadge(message: attention, size: 10)
            } else if workingSessions > 0 {
                JobBadge(count: workingSessions, scale: PillState.badgePinnedScale)
            }
            notchGap
            Button(action: onClose) {
                Image(systemName: "arrow.down.right.and.arrow.up.left")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.42))
                    .frame(width: 18, height: 14)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .hoverChip()
            .accessibilityLabel("Collapse the panel")
            .help("Collapse the panel")
        }
        .padding(.leading, 11)
        .padding(.trailing, 13)
    }

    /// Shared with the panel, which still draws this row off a notched screen.
    /// The provider the panel is reading about, which the band's own title and
    /// its badge both follow.
    private var shownSnapshot: UsageSnapshot? {
        providers.first { $0.source == viewing } ?? snapshot
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
        guard bordersOn else { return false }
        return switch state {
        case .pinned, .hidden, .ghost: false
        case .collapsed, .hover, .warning, .exhausted: true
        }
    }

    private var collapsed: some View {
        // Two wings, each taking half of what is left over. The flank is the
        // wider wing's measurement, so the narrower one has slack — and where
        // that slack goes is a decision, not a leftover.
        //
        // Both wings lean out, to the two ends of the row: the mark against the
        // left gutter, the countdown against the right. The slack — whichever
        // wing is the narrower one has some — collects beside the notch, where
        // there is nothing to read anyway.
        HStack(spacing: 0) {
            LeadingWing(
                snapshot: snapshot, mark: mark, showsPercentage: showsPercentage,
                isGhost: isGhost, headline: wings.headline, tone: tone
            )
            .padding(.leading, PillState.leadingGutter)
            .padding(.trailing, PillState.notchClearance)
            .frame(maxWidth: .infinity, alignment: .leading)

            notchGap

            TrailingWing(
                snapshot: snapshot, isGhost: isGhost, attention: attention,
                workingSessions: workingSessions, updateVersion: updateVersion, badge: badge
            )
            .padding(.leading, PillState.notchClearance)
            .padding(.trailing, PillState.trailingGutter)
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    /// What is left for a hover-card bar once the row's fixed columns are paid
    /// for. Measured here because only the shell knows how wide it is drawn.
    private var providerBarWidth: CGFloat {
        let shell = spansNotch ? state.size(around: band, wings: wings).width : state.size.width
        return max(60, shell - ScaleRow.fixedColumns - 36)
    }
}
