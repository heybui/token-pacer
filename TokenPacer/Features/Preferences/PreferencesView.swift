import AppKit
import SwiftUI

/// Two panes, as the board draws them: everything numeric and behavioural in
/// General, the two choices made by eye in Appearance.
///
/// A window with tabs rather than one long scroll, because the second pane is a
/// grid of twenty-four live drawings and nothing above it should be scrolled
/// past to reach it.
struct PreferencesView: View {
    @Bindable var preferences: Preferences
    var launchAtLogin: LaunchAtLogin
    /// Nil in tests and in a `swift run` build, where constructing one would
    /// start Sparkle's scheduler. The footer's row greys out with it.
    var updater: Updater?

    @State private var pane: Pane = .general

    enum Pane: String, CaseIterable, Identifiable {
        case general = "General", appearance = "Appearance"
        var id: Self { self }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Picker("", selection: $pane) {
                ForEach(Pane.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Group {
                switch pane {
                case .general:
                    GeneralPane(preferences: preferences, launchAtLogin: launchAtLogin)
                case .appearance:
                    AppearancePane(preferences: preferences)
                }
            }
            // A floor, not a height. The window is sized once, from the pane
            // showing when it is built — always General — and it is not
            // resizable, so a *fixed* height here is a height that has to be
            // edited every time a row is added: Copilot's provider switch was
            // the third one, and it pushed "Hide pill when dormant" straight
            // through the footer. General sizes itself now; Appearance holds two
            // grids of twelve and scrolls inside whatever that comes to.
            .frame(minHeight: 380, alignment: .top)

            footer
        }
        .padding(26)
        .frame(width: 420)
        .background(Color(hex: 0x141416))
        .environment(\.colorScheme, .dark)
    }
}

private extension PreferencesView {
    /// The one place in the app that says which version you are running.
    ///
    /// There is no Dock icon, no menu bar and no About box to put it in, and a
    /// bug report that names no build is a bug report about every build.
    var footer: some View {
        VStack(spacing: 0) {
            Divider().overlay(.white.opacity(0.06))
            HStack(spacing: 10) {
                // Not the app's name as well: the window's title bar already
                // carries that, and the row only just fits as it is.
                Text("Version \(AppInfo.versionLine)")
                    .font(Typography.mono(10.5))
                    .foregroundStyle(.white.opacity(0.32))
                    .fixedSize()
                Spacer(minLength: 8)
                link("Check for updates", enabled: updater?.canCheck ?? false) {
                    updater?.checkForUpdates()
                }
                Text("·").foregroundStyle(.white.opacity(0.2))
                link("Send feedback") { NSWorkspace.shared.open(AppInfo.landingPage) }
            }
            .padding(.top, 12)
        }
    }

    func link(
        _ title: String, enabled: Bool = true, action: @escaping () -> Void
    ) -> some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .font(Typography.sans(11.5))
            .foregroundStyle(enabled ? Tokens.blue.opacity(0.9) : .white.opacity(0.22))
            .disabled(!enabled)
            .fixedSize()
    }
}

/// The numbers and the behaviour.
private struct GeneralPane: View {
    @Bindable var preferences: Preferences
    var launchAtLogin: LaunchAtLogin

    @State private var launchEnabled = false

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            group("Alerts") {
                ThresholdScale(warn: $preferences.warnAt, critical: $preferences.criticalAt)
                // Directly under the control it describes: a legend at the far
                // end of the window is read after the fact, if at all.
                HStack(alignment: .bottom, spacing: 16) {
                    Text(footnote)
                        .font(Typography.sans(11))
                        .foregroundStyle(.white.opacity(0.4))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button("Reset") { preferences.resetThresholds() }
                        .buttonStyle(.plain)
                        .font(Typography.sans(11.5))
                        .foregroundStyle(
                            preferences.hasDefaultThresholds ? .white.opacity(0.25) : Tokens.amber
                        )
                        .disabled(preferences.hasDefaultThresholds)
                        .help("Back to 75% and 90%")
                        .fixedSize()
                }
                row("Sound on threshold") {
                    Toggle("", isOn: $preferences.soundOnThreshold).labelsHidden()
                }
            }

            group("Providers") {
                ForEach(SourceID.allCases, id: \.self) { source in
                    row(source.displayName) {
                        Toggle("", isOn: Binding(
                            get: { preferences.tracks(source) },
                            set: { preferences.set(tracking: $0, for: source) }
                        ))
                        .labelsHidden()
                        // The last one on cannot be turned off: an app tracking
                        // nothing has no reason to be on screen.
                        .disabled(preferences.trackedSources == [source])
                    }
                }
            }

            group("General") {
                row("Launch at login") {
                    Toggle("", isOn: $launchEnabled)
                        .labelsHidden()
                        .onChange(of: launchEnabled) { _, on in launchAtLogin.set(on) }
                }
                row("Hide pill when dormant") {
                    Toggle("", isOn: $preferences.hideWhenDormant).labelsHidden()
                }
            }

        }
        .onAppear { launchEnabled = launchAtLogin.isEnabled }
    }

    /// The thresholds are the app's whole opinion, so say what they do rather
    /// than leaving two sliders to be guessed at.
    private var footnote: String {
        "Amber from \(Int(preferences.warnAt))%, red from \(Int(preferences.criticalAt))% — "
            + "for the session ring, the weekly cap and the history alike. "
            + "The warning card opens itself once per window at the critical mark."
    }

    private func group(
        _ title: String, @ViewBuilder rows: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(Typography.mono(9.5))
                .tracking(1.4)
                .textCase(.uppercase)
                .foregroundStyle(.white.opacity(0.38))
            rows()
        }
    }

    private func row(_ label: String, @ViewBuilder control: () -> some View) -> some View {
        HStack(spacing: 16) {
            Text(label)
                .font(Typography.sans(12.5))
                .foregroundStyle(.white.opacity(0.85))
            Spacer(minLength: 0)
            control()
        }
        .frame(height: 24)
    }
}

/// Both thresholds on the one scale they actually divide.
///
/// Two separate sliders made the user hold the rule in their head and could be
/// set to contradict each other. One 0–100 track, coloured green/amber/red by the
/// handles themselves, *is* the rule — and warn simply cannot pass critical,
/// because the drag clamps rather than the settings correcting it afterwards.
private struct ThresholdScale: View {
    @Binding var warn: Double
    @Binding var critical: Double

    /// One point apart at the closest: a zero-width amber band is a rule with a
    /// step in it that nobody can see.
    private let minimumGap: Double = 1
    private let track: CGFloat = 8
    private let knob: CGFloat = 16

    private enum Handle { case warn, critical }
    @State private var dragging: Handle?

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 0) {
                legend("Warn", warn, Tokens.amber)
                Spacer(minLength: 12)
                legend("Critical", critical, Tokens.red)
            }

            GeometryReader { geometry in
                let width = geometry.size.width

                ZStack(alignment: .leading) {
                    HStack(spacing: 0) {
                        Tokens.green.frame(width: x(warn, in: width))
                        Tokens.amber.frame(width: x(critical - warn, in: width))
                        Tokens.red
                    }
                    .frame(height: track)
                    .clipShape(.capsule)

                    handle(at: warn, in: width)
                    handle(at: critical, in: width)
                }
                .frame(height: knob, alignment: .center)
                .contentShape(.rect)
                .gesture(drag(in: width))
            }
            .frame(height: knob)

            HStack {
                Text("0%")
                Spacer()
                Text("100%")
            }
            .font(Typography.mono(9.5))
            .foregroundStyle(.white.opacity(0.3))
        }
        // VoiceOver gets two ordinary sliders; the painted track is for the eye.
        .accessibilityRepresentation {
            VStack {
                Slider(value: $warn, in: 0...max(0, critical - minimumGap), step: 1) {
                    Text("Warn at")
                }
                Slider(value: $critical, in: min(100, warn + minimumGap)...100, step: 1) {
                    Text("Critical at")
                }
            }
        }
    }

    private func legend(_ title: String, _ value: Double, _ tone: Color) -> some View {
        HStack(spacing: 7) {
            Text(title)
                .font(Typography.sans(12.5))
                .foregroundStyle(.white.opacity(0.85))
            Text("\(Int(value))%")
                .font(Typography.mono(11.5))
                .foregroundStyle(tone)
        }
    }

    private func handle(at value: Double, in width: CGFloat) -> some View {
        Circle()
            .fill(.white)
            .overlay { Circle().strokeBorder(.black.opacity(0.25), lineWidth: 0.5) }
            .frame(width: knob, height: knob)
            .shadow(color: .black.opacity(0.4), radius: 3, y: 1)
            .offset(x: x(value, in: width) - knob / 2)
    }

    private func x(_ value: Double, in width: CGFloat) -> CGFloat {
        width * min(1, max(0, value / 100))
    }

    /// Whichever handle is nearer takes the drag, so the whole track is a target
    /// rather than two 16pt circles.
    private func drag(in width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { gesture in
                let percent = min(100, max(0, Double(gesture.location.x / width) * 100)).rounded()
                let handle = dragging
                    ?? (abs(percent - warn) <= abs(percent - critical) ? .warn : .critical)
                dragging = handle

                switch handle {
                case .warn: warn = min(percent, critical - minimumGap)
                case .critical: critical = max(percent, warn + minimumGap)
                }
            }
            .onEnded { _ in dragging = nil }
    }
}
