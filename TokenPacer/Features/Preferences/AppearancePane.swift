import SwiftUI

/// The choice made by eye.
///
/// Twelve marks, drawn live at the size they will sit in the menu bar, against
/// the same black the shell is. A popup menu was ruled out by the board and the
/// reason is the names: "Eclipse" tells you nothing about what lands in your menu
/// bar. So the list is the thing itself, animating, and clicking a tile is the
/// setting.
struct AppearancePane: View {
    @Bindable var preferences: Preferences

    /// The reading every tile is drawn at, walked from empty to full and round
    /// again. A switch with three stops answered "does it read in each zone";
    /// this answers the question that actually decides a mark — what does it do
    /// *between* them, and is the step from one zone to the next visible at all.
    ///
    /// An object rather than `@State`, so that the only views invalidated ten
    /// times a second are the thirteen that read it. As a `@State` on the pane
    /// the whole grid was rebuilt on every step — twelve buttons, twelve labels,
    /// twelve tooltips — for 11% of a core.
    @State private var lap = Lap()

    /// The window's own state. Hidden is not closed — this app's settings window
    /// hides itself when you move on to something else — and a preview nobody is
    /// looking at is twelve drawings a second of pure waste.
    @Environment(\.controlActiveState) private var activeState

    /// Two seconds in each zone, six for the lap. Not a constant rate: the safe
    /// zone is three quarters of the scale and the over zone a tenth, and at an
    /// even speed the end — the part worth watching — would be over in half a
    /// second.
    private static let perZone = Duration.seconds(2)
    private static let steps = 20

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 4)

    var body: some View {
        // Two grids and two switches do not fit a settings window that also has
        // to leave the General pane looking full. The window keeps one height and
        // the second grid is a scroll away.
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 16) {
                    Text("Progress mark")
                        .font(Typography.mono(9.5))
                        .tracking(1.4)
                        .textCase(.uppercase)
                        .foregroundStyle(.white.opacity(0.38))
                    Spacer(minLength: 0)
                    // The figure the grid is drawing, in the zone's own colour.
                    // Without it the tiles are twelve animations of nothing in
                    // particular.
                    LapReadout(lap: lap, scale: preferences.thresholds)
                }

                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(Mark.allCases, id: \.self) { mark in
                        MarkTile(
                            mark: mark, lap: lap,
                            isSelected: mark == preferences.mark
                        ) {
                            preferences.mark = mark
                        }
                    }
                }

                // What the chosen mark encodes, which is the board's own argument for
                // having twelve of them rather than one.
                Text("\(preferences.mark.displayName) · \(preferences.mark.axis)")
                    .font(Typography.sans(11))
                    .foregroundStyle(.white.opacity(0.4))

                Divider().overlay(.white.opacity(0.08))

                // The figure is the other half of the row, and it costs about as much
                // menu bar as the mark does — so it belongs next to the choice that
                // sets the rest of the width, not in General with the thresholds.
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Percentage beside the mark")
                            .font(Typography.sans(12.5))
                            .foregroundStyle(.white.opacity(0.85))
                        Text(
                            "Off leaves the mark on its own and gives the menu bar "
                                + "back about 30pt. Every figure is still in the card."
                        )
                        .font(Typography.sans(11))
                        .foregroundStyle(.white.opacity(0.28))
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    Toggle("Percentage beside the mark", isOn: $preferences.showsPercentage).labelsHidden()
                }

                Divider().overlay(.white.opacity(0.08))

                HStack(spacing: 16) {
                    Text("Running border")
                        .font(Typography.mono(9.5))
                        .tracking(1.4)
                        .textCase(.uppercase)
                        .foregroundStyle(.white.opacity(0.38))
                    Spacer(minLength: 0)
                    // One switch gates the whole group. Off dims the grid rather than
                    // hiding it, so the twelve stay discoverable and the selection
                    // survives being turned off and on again.
                    Toggle("Running border", isOn: $preferences.bordersOn).labelsHidden()
                }

                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(BorderEffect.grid, id: \.self) { effect in
                        BorderTile(
                            effect: effect,
                            isSelected: effect == preferences.border,
                            isRunning: preferences.bordersOn
                        ) {
                            preferences.border = effect
                        }
                    }
                }
                .opacity(preferences.bordersOn ? 1 : 0.35)

                Text("\(preferences.border.displayName) · \(preferences.border.axis)")
                    .font(Typography.sans(11))
                    .foregroundStyle(.white.opacity(0.4))

                Text(
                    "The light runs the shell's outline while a model is answering, "
                        + "and takes its colour from the zone you are in. It never "
                        + "runs along the top edge: that one lies against the notch."
                )
                .font(Typography.sans(11))
                .foregroundStyle(.white.opacity(0.28))
                .fixedSize(horizontal: false, vertical: true)
                }
            .padding(.bottom, 4)
        }
        .scrollIndicators(.never)
        // The user's own thresholds, so the tiles are coloured by the rule the
        // pill will apply rather than by the default one.
        .environment(\.tone, preferences.thresholds)
        // The lap moves the figure itself; a mark easing towards each step as
        // well is sixty layout passes a second for a window full of drawings
        // that are already moving.
        .environment(\.markEasing, nil)
        .task(id: activeState) {
            guard activeState != .inactive else { return }
            await run()
        }
    }

    /// The lap, stepped rather than animated.
    ///
    /// Ten readings a second, not sixty: a mark is a drawing that changes when a
    /// figure changes, and driving twelve of them from a display link would be
    /// the same mistake this app has already paid for once. The window is only
    /// open while somebody is choosing, and at 100ms the walk is continuous to
    /// the eye.
    private func run() async {
        let scale = preferences.thresholds
        let zones = [(0.0, scale.warnAt), (scale.warnAt, scale.critAt), (scale.critAt, 100.0)]
        while !Task.isCancelled {
            for (start, end) in zones {
                for step in 0...Self.steps {
                    lap.percent = start + (end - start) * Double(step) / Double(Self.steps)
                    try? await Task.sleep(for: Self.perZone / Self.steps)
                    if Task.isCancelled { return }
                }
            }
        }
    }
}

/// Where the lap's figure lives. One object read by thirteen leaves, so a step
/// redraws the marks and the readout and nothing else.
@MainActor
@Observable
final class Lap {
    var percent: Double = 0
}

/// The figure the grid is drawing, in the zone's own colour. Without it the
/// tiles are twelve animations of nothing in particular.
private struct LapReadout: View {
    let lap: Lap
    let scale: ToneScale

    var body: some View {
        Text("\(Int(lap.percent))%")
            .font(Typography.mono(11.5))
            .foregroundStyle(scale(lap.percent))
            .monospacedDigit()
    }
}

/// One mark, drawn at menu-bar size on the shell's own black.
private struct MarkTile: View {
    let mark: Mark
    let lap: Lap
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            VStack(spacing: 6) {
                // Only the chosen one is working. A resting mark and a working
                // one differ by one moving part, and showing that part on the
                // tile you picked is both the demonstration and the answer to
                // "which of these is selected".
                LiveMark(mark: mark, lap: lap, isBurning: isSelected)
                    .frame(height: 22)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
                    .background(.black, in: .rect(cornerRadius: 8))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(
                                isSelected ? Tokens.amber : .white.opacity(0.08),
                                lineWidth: isSelected ? 1.5 : 1
                            )
                    }
                Text(mark.displayName)
                    .font(Typography.sans(10))
                    .foregroundStyle(.white.opacity(isSelected ? 0.9 : 0.45))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .buttonStyle(.plain)
        .help(mark.axis)
    }
}

/// One border, running on a shell of its own.
///
/// Green, not the lap's colour: a border takes its tone from the zone, and
/// following the preview would rebuild every layer of all twelve lights ten times
/// a second. The zone is not what is being chosen here — the motion is.
private struct BorderTile: View {
    let effect: BorderEffect
    let isSelected: Bool
    let isRunning: Bool
    let onSelect: () -> Void

    private let radius: CGFloat = 9

    var body: some View {
        Button(action: onSelect) {
            VStack(spacing: 6) {
                // A shell hanging from the top of the tile, as the board draws
                // it: the border is an outline, so it needs something to outline.
                UnevenRoundedRectangle(
                    bottomLeadingRadius: radius, bottomTrailingRadius: radius
                )
                .fill(.black)
                .overlay {
                    ChasingBorder(
                        cornerRadius: radius, tone: Tokens.green,
                        light: Tokens.lightGreen, effect: effect, isRunning: isRunning
                    )
                }
                .overlay {
                    UnevenRoundedRectangle(
                        bottomLeadingRadius: radius, bottomTrailingRadius: radius
                    )
                    .strokeBorder(
                        isSelected ? Tokens.amber : .white.opacity(0.08),
                        lineWidth: isSelected ? 1.5 : 1
                    )
                }
                .frame(height: 34)
                .padding(.top, 4)

                Text(effect.displayName)
                    .font(Typography.sans(10))
                    .foregroundStyle(.white.opacity(isSelected ? 0.9 : 0.45))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .buttonStyle(.plain)
        .help(effect.axis)
    }
}

/// The only thing in a tile that reads the lap.
private struct LiveMark: View {
    let mark: Mark
    let lap: Lap
    let isBurning: Bool

    var body: some View {
        if isBurning {
            // The working mark hosts a layer of its own, and a rasterised
            // subtree has nowhere to put one.
            MarkView(mark: mark, percent: lap.percent, isBurning: true)
        } else {
            // One rasterised layer per tile instead of a dozen small ones. The
            // lap redraws all twelve ten times a second, and flattening them
            // took that from 14% of a core to 9%.
            MarkView(mark: mark, percent: lap.percent, isBurning: false)
                .drawingGroup()
        }
    }
}
