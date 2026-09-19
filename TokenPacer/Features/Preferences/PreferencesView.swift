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
    /// What the pollers are finding, so a provider's row can say why it is
    /// reading nothing. Nil in tests, where there is no store to read.
    var store: UsageStore?
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
            PaneSwitcher(pane: $pane)

            Group {
                switch pane {
                case .general:
                    GeneralPane(
                        preferences: preferences, launchAtLogin: launchAtLogin,
                        store: store, updater: updater
                    )
                case .appearance:
                    AppearancePane(preferences: preferences)
                }
            }
            // A floor, not a height. The window is sized once, from the pane
            // showing when it is built — always General — and it is not
            // resizable, so a *fixed* height here is a height that has to be
            // edited every time a row is added: Copilot's provider switch was
            // the third one, and it pushed "Hide when nothing is running" straight
            // through the footer. General sizes itself now; Appearance holds two
            // grids of twelve and scrolls inside whatever that comes to.
            .frame(minHeight: 380, alignment: .top)

            footer
        }
        .padding(.horizontal, 26)
        .padding(.bottom, 26)
        // Less than the other three. The window keeps a 28pt titlebar above this
        // and the board leaves 12 under it — 26 all round put the switcher 54pt
        // down a window whose first control it is.
        .padding(.top, 12)
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
                // The name, not the word "Version". The titlebar carries the name
                // too, but this is the line that gets pasted into a bug report,
                // and "0.1.0 (186)" on its own names no app.
                Text("\(AppInfo.name) \(AppInfo.versionLine)")
                    .font(Typography.mono(10.5))
                    .foregroundStyle(.white.opacity(0.32))
                    .fixedSize()
                Spacer(minLength: 8)
                link("Check for updates", enabled: updater?.canCheck ?? false) {
                    updater?.checkForUpdates()
                }
                Text("·").foregroundStyle(.white.opacity(0.2))
                link("Send feedback") { NSWorkspace.shared.open(AppInfo.feedbackPage) }
            }
            .padding(.top, 12)
        }
    }

}

/// A word that opens something, in both panes' footers and beside a provider.
private func link(
    _ title: String, enabled: Bool = true, action: @escaping () -> Void
) -> some View {
    Button(title, action: action)
        .buttonStyle(.plain)
        .font(Typography.sans(11.5))
        .foregroundStyle(enabled ? Tokens.blue.opacity(0.9) : .white.opacity(0.22))
        .disabled(!enabled)
        .fixedSize()
}

/// The numbers and the behaviour, in the board's three groups.
///
/// *Zones* is the scale and what it means; *Alerts* is what happens when you
/// cross it; *App* is the app itself. Providers sits between them — the board
/// does not draw it, and it is the only way to stop a CLI being asked anything.
private struct GeneralPane: View {
    @Bindable var preferences: Preferences
    var launchAtLogin: LaunchAtLogin
    var store: UsageStore?
    var updater: Updater?

    /// Which CLIs are on the machine. Read when the pane opens rather than per
    /// row draw: it is a filesystem walk, and the answer only changes when the
    /// user goes and installs something — which is what "Check again" is for.
    @State private var installed: Set<SourceID> = []
    @State private var launchEnabled = false
    @State private var checksAutomatically = true

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            group("Zones") {
                ThresholdScale(warn: $preferences.warnAt, critical: $preferences.criticalAt)
                // Directly under the control it describes: a legend at the far
                // end of the window is read after the fact, if at all.
                Text(footnote)
                    .font(Typography.sans(11))
                    .foregroundStyle(.white.opacity(0.4))
                    .fixedSize(horizontal: false, vertical: true)
            }

            divider

            group("Alerts") {
                row("Notify when over", note: AttributedString("Banner once per window")) {
                    Toggle("Notify when over", isOn: $preferences.notifiesWhenOver)
                        .labelsHidden()
                }
                row("Sound when over") {
                    Toggle("Sound when over", isOn: $preferences.soundOnThreshold)
                        .labelsHidden()
                        // A sound with no banner to carry it is nothing at all.
                        .disabled(!preferences.notifiesWhenOver)
                }
            }

            divider

            // The radio column belongs to the group, so the header says what it
            // is once rather than every row carrying a label for it.
            group("Providers", accessory: {
                // The action appears only when there is something for it to fix.
                // Nothing to fix is worth saying too — silence there reads as
                // "did it even look?" — but as a state, not a button.
                if troubled.isEmpty {
                    ProvidersReady()
                } else {
                    // Installing a CLI happens outside this app, so there has to
                    // be a way to say "it is there now" that is not quitting.
                    link("Check again") {
                        installed = Set(SourceID.allCases.filter(\.cliIsInstalled))
                        store?.recheck()
                    }
                }
            }) {
                // The radio column has no header of its own, and a circle with
                // nothing to say what it does is a mystery in a settings window.
                Text("The dot picks which one the pill shows.")
                    .font(Typography.sans(11))
                    .foregroundStyle(.white.opacity(0.3))
                ForEach(SourceID.allCases, id: \.self) { source in
                    // Tracking a provider reads what its CLI writes, so a switch
                    // on its own is a promise the app cannot keep: nothing is
                    // there until the tool is installed and signed in. The line
                    // says the requirement, the link goes to their own install
                    // page rather than this app repeating the steps.
                    row(
                        source.displayName,
                        note: note(for: source),
                        noteIsComplaint: complaint(for: source) != nil,
                        leading: {
                            PillPin(
                                isPinned: preferences.pillSource == source,
                                // The pill reports a provider that is being
                                // polled, so an untracked one cannot hold the pin.
                                isEnabled: preferences.tracks(source),
                                name: source.displayName
                            ) { preferences.pillSource = source }
                        }
                    ) {
                        Toggle(source.displayName, isOn: Binding(
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

            divider

            group("App") {
                row("Launch at login") {
                    Toggle("Launch at login", isOn: $launchEnabled)
                        .labelsHidden()
                        .onChange(of: launchEnabled) { _, on in launchAtLogin.set(on) }
                }
                // The note never changes: the exception belongs where it can be
                // read before you go looking for it, not after you have set it.
                row("Hide when nothing is running", note: AttributedString("0 keeps it on screen")) {
                    // A duration rather than a switch: "hide it" and "leave it" are
                    // the two ends of the same question, and zero is the off end.
                    // Typed or stepped, both through the binding that clamps, so
                    // neither route can set a figure the other cannot show.
                    QuietField(minutes: quietMinutes)
                }
                row("Check for updates automatically", note: AttributedString("Daily, in the background")) {
                    Toggle("Check for updates automatically", isOn: $checksAutomatically)
                        .labelsHidden()
                        .onChange(of: checksAutomatically) { _, on in
                            updater?.checksAutomatically = on
                        }
                        // Nil in tests and in a `swift run` build: no Sparkle, so
                        // nothing behind the switch to set.
                        .disabled(updater == nil)
                }
                row("Restore defaults") {
                    Button("Reset", action: preferences.restoreDefaults)
                        .buttonStyle(.plain)
                        .font(Typography.sans(11.5))
                        .foregroundStyle(
                            preferences.hasDefaults ? .white.opacity(0.25) : Tokens.amber
                        )
                        .disabled(preferences.hasDefaults)
                        .help("Back to the board's own settings, both panes")
                        .fixedSize()
                }
            }
        }
        .onAppear {
            installed = Set(SourceID.allCases.filter(\.cliIsInstalled))
            launchEnabled = launchAtLogin.isEnabled
            checksAutomatically = updater?.checksAutomatically ?? true
        }
    }

    private var divider: some View {
        Rectangle().fill(.white.opacity(0.06)).frame(height: 1)
    }

    /// Clamped here rather than in `Preferences`: the stepper cannot leave the
    /// range, and a typed figure should not be able to either.
    private var quietMinutes: Binding<Int> {
        Binding(
            get: { preferences.hidesAfterQuietMinutes },
            set: { preferences.hidesAfterQuietMinutes = min(60, max(0, $0)) }
        )
    }

    /// The thresholds are the app's whole opinion, so say what they do rather
    /// than leaving two handles to be guessed at.
    private var footnote: String {
        "Safe to \(Int(preferences.warnAt))%, watch from \(Int(preferences.warnAt))%, "
            + "over from \(Int(preferences.criticalAt))% — for the session window, the "
            + "weekly cap and the history alike. The same two boundaries colour every "
            + "mark and every border in Appearance."
    }

    private func group(
        _ title: String, @ViewBuilder accessory: () -> some View = { EmptyView() },
        @ViewBuilder rows: () -> some View
    ) -> some View {
        // 16, not 12: a row with a note under it is two lines tall and the ones
        // without were reading as a block against them. The air is what tells
        // one setting from the next, whichever kind of row it is.
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Text(title)
                    .font(Typography.mono(9.5))
                    .tracking(1.4)
                    .textCase(.uppercase)
                    .foregroundStyle(.white.opacity(0.38))
                Spacer(minLength: 0)
                accessory()
            }
            rows()
        }
    }

    /// The provider's line: what it gives the pill, or — the moment tracking it
    /// turns one up — the poller's own complaint, "Claude Code CLI not found",
    /// "sign in to Codex". The link rides at the end of that same sentence,
    /// because a missing CLI is exactly when somewhere to get it is the point.
    private func note(for source: SourceID) -> AttributedString {
        let lead = complaint(for: source) ?? source.blurb
        let markdown = "\(lead) [\(source.installLabel)](\(source.docs.absoluteString))"
        return (try? AttributedString(markdown: markdown)) ?? AttributedString(lead)
    }

    /// A row is a label and its control. `note` is the board's second line — the
    /// one that says what the switch above it actually does.
    /// The providers that are switched on and cannot report. An untracked one is
    /// not a problem: nothing is being asked of it, and its row says where to get
    /// it if that is the reason it is off.
    private var troubled: [SourceID] {
        SourceID.allCases.filter { preferences.tracks($0) && complaint(for: $0) != nil }
    }

    /// Why this provider can report nothing, if it cannot: the CLI is not on
    /// the machine, or the poller found something wrong with the one that is.
    private func complaint(for source: SourceID) -> String? {
        if !installed.contains(source) { return "Not installed on this Mac." }
        return store?.errors[source].map { "\($0)." }
    }

    private func row(
        _ label: String, note: AttributedString? = nil, noteIsComplaint: Bool = false,
        @ViewBuilder leading: () -> some View = { EmptyView() },
        @ViewBuilder control: () -> some View
    ) -> some View {
        HStack(spacing: 16) {
            leading()
            VStack(alignment: .leading, spacing: 3) {
                Text(label)
                    .font(Typography.sans(12.5))
                    .foregroundStyle(.white.opacity(0.85))
                if let note {
                    Text(note)
                        .font(Typography.sans(11))
                        .foregroundStyle(noteIsComplaint ? Tokens.amber : .white.opacity(0.42))
                        // The link inside takes the tint; everything around it
                        // keeps the note's own colour.
                        .tint(Tokens.blue.opacity(0.9))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            control()
        }
        // A floor, not a height: the noted row is two lines tall. The floor is
        // what keeps a plain row from sitting tighter than a noted one.
        .frame(minHeight: 28)
    }
}

/// Which provider the menu bar itself carries.
///
/// A radio, not a switch: the strip has room for one reading, so this is a
/// choice between providers rather than a setting each of them has. The switch
/// on the other side of the row is a different question — whether the CLI is
/// asked anything at all — and the pin cannot land on one that is off.
private struct PillPin: View {
    let isPinned: Bool
    let isEnabled: Bool
    let name: String
    let onPin: () -> Void

    var body: some View {
        Button(action: onPin) {
            Image(systemName: isPinned ? "largecircle.fill.circle" : "circle")
                .font(.system(size: 13))
                .foregroundStyle(pinColour)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled || isPinned)
        .help("Show \(name) on the pill")
        .accessibilityLabel("Show \(name) on the pill")
    }

    private var pinColour: Color {
        if !isEnabled { return .white.opacity(0.12) }
        return isPinned ? Tokens.green : .white.opacity(0.3)
    }
}

/// What the Providers header says when every tracked CLI is answering.
///
/// A state, not a control: there is nothing to press when nothing is wrong, and
/// a live "Check again" invited a click that could only confirm what was already
/// true.
private struct ProvidersReady: View {
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 10))
                .foregroundStyle(Tokens.green)
            Text("All set")
                .font(Typography.sans(11.5))
                .foregroundStyle(.white.opacity(0.42))
        }
        .fixedSize()
    }
}

/// Minutes of quiet, typed or stepped.
///
/// A stepper alone is fine for 5 and useless for 45, so the figure is a field
/// you can select and overwrite; the arrows stay for the one-at-a-time case.
private struct QuietField: View {
    @Binding var minutes: Int

    var body: some View {
        HStack(spacing: 6) {
            TextField("", value: $minutes, format: .number)
                .textFieldStyle(.plain)
                .multilineTextAlignment(.trailing)
                .font(Typography.mono(11.5))
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: 22)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(.white.opacity(0.07), in: .rect(cornerRadius: 6))
            Text("min")
                .font(Typography.sans(11.5))
                .foregroundStyle(.white.opacity(0.42))
            Stepper("Minutes of quiet", value: $minutes, in: 0...60).labelsHidden()
        }
        .fixedSize()
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
                legend("Watch starts at", warn, Tokens.amber)
                Spacer(minLength: 12)
                legend("Over starts at", critical, Tokens.red)
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
                    Text("Watch starts at")
                }
                Slider(value: $critical, in: min(100, warn + minimumGap)...100, step: 1) {
                    Text("Over starts at")
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
