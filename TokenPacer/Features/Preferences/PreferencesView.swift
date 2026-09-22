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
    /// Built on the first open and let go when the window closes.
    @State private var diagnostics = DiagnosticsWindow()

    enum Pane: String, CaseIterable, Identifiable {
        case general, appearance
        var id: Self { self }

        /// The tab's word. Separate from `rawValue`, which is the identifier the
        /// switcher tags with and must not move when the word is translated.
        var title: LocalizedStringKey {
            switch self {
            case .general: "General"
            case .appearance: "Appearance"
            }
        }
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
            //
            // Greedy at the top end as well, so the slack in a window sized for
            // the taller pane lands *here* rather than around the whole column:
            // General has no scroll view and Appearance does, so one pane filled
            // the window and the other sat centred in it — and the switcher
            // above them, which never moves, appeared to.
            .frame(minHeight: 380, maxHeight: .infinity, alignment: .top)

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
                // Glyphs rather than words, and all three rather than two: the
                // row is 368pt wide and the words came to more than that the
                // moment a third was added. What each one is lives in its
                // tooltip, which is also what VoiceOver reads.
                iconLink(
                    "arrow.triangle.2.circlepath", help: "Check for updates",
                    enabled: updater?.canCheck ?? false
                ) { updater?.checkForUpdates() }
                iconLink("stethoscope", help: "Diagnostics") { diagnostics.show() }
                iconLink("envelope", help: "Send feedback") {
                    NSWorkspace.shared.open(AppInfo.feedbackPage)
                }
            }
            .padding(.top, 12)
        }
    }

}

/// A glyph that opens something, for the footer, where there is no room for the
/// word.
///
/// The help string is the accessibility label as well: an icon with a tooltip
/// and no label is a button VoiceOver reads out as "button".
@MainActor private func iconLink(
    _ symbol: String, help: LocalizedStringKey, enabled: Bool = true,
    action: @escaping () -> Void
) -> some View {
    Button(action: action) { Image(systemName: symbol) }
        .buttonStyle(.plain)
        .font(.system(size: 12.5))
        .foregroundStyle(enabled ? Tokens.blue.opacity(0.9) : .white.opacity(0.22))
        .disabled(!enabled)
        // The glyphs are three different widths; the target should not be, and
        // a tooltip needs somewhere for the pointer to rest still.
        .frame(width: 22, height: 20)
        .contentShape(.rect)
        .hoverChip(padding: 2, isActive: enabled)
        // Above, not below: this row sits on the bottom edge of a window that
        // does not resize, and a tip hung under it is drawn outside and clipped.
        .tooltip(help, above: true)
        .accessibilityLabel(help)
}

/// A word that opens something, in both panes' footers and beside a provider.
@MainActor private func link(
    _ title: LocalizedStringKey, enabled: Bool = true, action: @escaping () -> Void
) -> some View {
    Button(title, action: action)
        .buttonStyle(.plain)
        .font(Typography.sans(11.5))
        .foregroundStyle(enabled ? Tokens.blue.opacity(0.9) : .white.opacity(0.22))
        .disabled(!enabled)
        .fixedSize()
        .hoverChip(cornerRadius: 5, padding: 3, isActive: enabled)
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
    @State private var updatesAutomatically = true

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {

            // First: the providers are what the app is about, and each row now
            // carries the marks that provider is read by.
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
                        preferences.refreshTracked()
                        store?.recheck()
                    }
                }
            }) {
                // The radio column has no header of its own, and a circle with
                // nothing to say what it does is a mystery in a settings window.
                // Above the rows: what they are and what the handles do.
                Text("Tracked automatically. Drag to set where each one turns amber and red.")
                    .font(Typography.sans(11))
                    .foregroundStyle(.white.opacity(0.3))
                ForEach(Array(SourceID.allCases.enumerated()), id: \.element) { index, source in
                    // Tracking a provider reads what its CLI writes, so a switch
                    // on its own is a promise the app cannot keep: nothing is
                    // there until the tool is installed and signed in. The line
                    // says the requirement, the link goes to their own install
                    // page rather than this app repeating the steps.
                    // The pin used to sit on the left of this row. It is on the
                    // hover card now, beside the figures it is chosen by — a
                    // window away from them, it was a choice made blind.
                    VStack(alignment: .leading, spacing: 9) {
                        row(
                            // A product name, never translated: `LocalizedStringKey`
                            // looks it up, finds nothing, and hands back the name.
                            LocalizedStringKey(source.displayName),
                            note: note(for: source),
                            noteIsComplaint: complaint(for: source) != nil
                        ) {
                            // The green tick said "found", which the row's own
                            // note already says when it is missing. The slot is
                            // worth more as the one choice left here: whether
                            // this provider gets a row on the card at all.
                            Toggle("Show on the card", isOn: Binding(
                                get: { preferences.showsOnCard(source) },
                                set: { preferences.setShowsOnCard($0, for: source) }
                            ))
                            .labelsHidden()
                            // Nothing to show, nothing to choose.
                            .disabled(!installed.contains(source))
                            .tooltip(installed.contains(source)
                                ? "Show this provider on the card"
                                : "Install it first — there is nothing to show")
                        }
                        // Above the marks line under it, for the same reason.
                        .zIndex(1)
                        // And the marks it is read by, under the name they belong
                        // to. They had a section of their own with a provider
                        // picker in it — two places asking the same question, one
                        // of them a mode you had to be in.
                        HStack(spacing: 14) {
                            ThresholdScale(
                                warn: warnBinding(source),
                                critical: criticalBinding(source),
                                isCompact: true
                            )
                            mark("watch", preferences.zone(for: source).warnAt, Tokens.amber)
                            mark("over", preferences.zone(for: source).critAt, Tokens.red)
                            // A quiet icon rather than a line of blue text: the
                            // row already carries a name, a note, a link and two
                            // figures, and a fifth thing spelled out in words was
                            // the loudest of them. Always drawn, so the row does
                            // not resize when the marks happen to match, and dim
                            // when there is nothing to copy.
                            Button { applyMarks(of: source) } label: {
                                Image(systemName: "square.on.square")
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(.white.opacity(sharesMarks(source) ? 0.4 : 0.12))
                                    // 22×20, not 16×14: a tooltip needs a second
                                    // of stillness inside the shape, and a target
                                    // the size of the glyph is one the pointer
                                    // crosses rather than rests in.
                                    .frame(width: 22, height: 20)
                                    .contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                            .disabled(!sharesMarks(source))
                            .hoverChip(padding: 2)
                            .accessibilityLabel(Text("Use these marks for every provider"))
                            .tooltip(sharesMarks(source)
                                ? "Give every provider these marks"
                                : "Every provider already has these marks")
                        }
                        .padding(.bottom, 4)
                    }
                    // Earlier rows draw over later ones. A tooltip hangs below
                    // the control it explains, and SwiftUI draws siblings in
                    // order — so without this the row underneath is painted on
                    // top of it and the tip reads as a transparent smear.
                    .zIndex(Double(SourceID.allCases.count - index))
                }

                // Under the rows rather than above them: it explains what the
                // two handles just dragged actually do, and that is a thing you
                // look for after touching them, not before.
                Text(zoneFootnote)
                    .font(Typography.sans(11))
                    .foregroundStyle(.white.opacity(0.4))
                    .fixedSize(horizontal: false, vertical: true)

                // At the end of what it undoes. It sat in *App*, a section away
                // from the marks it puts back, where it read as a button that
                // would reset the app.
                row("Reset alert configuration") {
                    Button("Reset", action: preferences.resetZonesAndAlerts)
                        .buttonStyle(.plain)
                        .font(Typography.sans(11.5))
                        .foregroundStyle(
                            preferences.hasDefaults ? .white.opacity(0.25) : Tokens.amber
                        )
                        .disabled(preferences.hasDefaults)
                        .hoverChip(cornerRadius: 5, padding: 3, isActive: !preferences.hasDefaults)
                        .tooltip("The marks and the two alert switches, back to their defaults")
                        .fixedSize()
                }
            }

            divider

            group("Alerts") {
                row(
                    "Tell me at watch and over",
                    note: AttributedString(
                        localized: "The pill opens and waits there until you look at it"
                    )
                ) {
                    Toggle("Tell me at watch and over", isOn: $preferences.notifiesOnZone)
                        .labelsHidden()
                }
                row("Play a sound with it") {
                    Toggle("Play a sound with it", isOn: $preferences.soundOnThreshold)
                        .labelsHidden()
                        // A sound with nothing on screen to explain it is a noise.
                        .disabled(!preferences.notifiesOnZone)
                }
            }

            divider

            group("App") {
                // Hidden while the bundle carries one language: a picker with a
                // single row is not a choice, and this build ships English alone
                // until a second `.lproj` comes out of the catalog.
                if Language.isOffered {
                    row("Language", note: AttributedString(localized: "Takes effect on restart")) {
                        Picker("Language", selection: $preferences.language) {
                            ForEach(Language.available, id: \.self) { code in
                                Text(Language.name(code)).tag(code)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                }
                row("Launch at login") {
                    Toggle("Launch at login", isOn: $launchEnabled)
                        .labelsHidden()
                        .onChange(of: launchEnabled) { _, on in launchAtLogin.set(on) }
                }
                // The note never changes: the exception belongs where it can be
                // read before you go looking for it, not after you have set it.
                row("Hide when nothing is running", note: AttributedString(localized: "0 keeps it on screen")) {
                    // A duration rather than a switch: "hide it" and "leave it" are
                    // the two ends of the same question, and zero is the off end.
                    // Typed or stepped, both through the binding that clamps, so
                    // neither route can set a figure the other cannot show.
                    QuietField(minutes: quietMinutes)
                }
                row("Update automatically", note: AttributedString(localized: "Daily, in the background")) {
                    Toggle("Update automatically", isOn: $updatesAutomatically)
                        .labelsHidden()
                        .onChange(of: updatesAutomatically) { _, on in
                            updater?.updatesAutomatically = on
                        }
                        // Nil in tests and in a `swift run` build: no Sparkle, so
                        // nothing behind the switch to set.
                        .disabled(updater == nil)
                }
            }
        }
        .onAppear {
            installed = Set(SourceID.allCases.filter(\.cliIsInstalled))
            preferences.refreshTracked()
            launchEnabled = launchAtLogin.isEnabled
            updatesAutomatically = updater?.updatesAutomatically ?? true
        }
    }

    private func group(
        _ title: LocalizedStringKey, @ViewBuilder accessory: () -> some View = { EmptyView() },
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
    /// Under the rows: the two things the line above does not cover — where the
    /// colours turn up, and what the tick box is for. It used to repeat the
    /// handles, which the line above had already explained.
    private var zoneFootnote: LocalizedStringKey {
        "The same colours show on the pill and in the card. Untick a provider to leave it off the card."
    }

    /// The two bindings a provider's own scale writes through.
    private func warnBinding(_ source: SourceID) -> Binding<Double> {
        Binding(
            get: { preferences.zone(for: source).warnAt },
            set: { preferences.setZone(
                ToneScale(warnAt: $0, critAt: preferences.zone(for: source).critAt), for: source
            ) }
        )
    }

    private func criticalBinding(_ source: SourceID) -> Binding<Double> {
        Binding(
            get: { preferences.zone(for: source).critAt },
            set: { preferences.setZone(
                ToneScale(warnAt: preferences.zone(for: source).warnAt, critAt: $0), for: source
            ) }
        )
    }

    /// The row's second line: what the provider gives the pill, and where to get
    /// it when it is missing.
    private func note(for source: SourceID) -> AttributedString {
        let lead = complaint(for: source) ?? source.blurb
        let markdown = "\(lead) [\(source.installLabel)](\(source.docs.absoluteString))"
        return (try? AttributedString(markdown: markdown)) ?? AttributedString(lead)
    }

    /// Whether this provider's pair is worth offering to the others.
    private func sharesMarks(_ source: SourceID) -> Bool {
        SourceID.allCases.contains {
            preferences.tracks($0) && preferences.zone(for: $0) != preferences.zone(for: source)
        }
    }

    /// Give every provider this one's marks. The common case is one rule for the
    /// machine; keeping three sets in step by hand is the cost of allowing three.
    private func applyMarks(of source: SourceID) {
        let zone = preferences.zone(for: source)
        for other in SourceID.allCases where other != source {
            preferences.setZone(zone, for: other)
        }
    }

    /// One of the two marks, beside the track it is dragged on.
    private func mark(_ name: LocalizedStringKey, _ value: Double, _ tone: Color) -> some View {
        HStack(spacing: 4) {
            Text(name)
                .font(Typography.sans(11))
                .foregroundStyle(.white.opacity(0.35))
            Text(verbatim: "\(Int(value))")
                .font(Typography.mono(11, .semibold))
                .foregroundStyle(tone)
        }
        .fixedSize()
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
        if !installed.contains(source) { return String(localized: "Not installed on this Mac.") }
        return store?.errors[source].map { "\($0)." }
    }

    private func row(
        _ label: LocalizedStringKey, note: AttributedString? = nil, noteIsComplaint: Bool = false,
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

/// What the Providers header says when every tracked CLI is answering.
///
/// A state, not a control: there is nothing to press when nothing is wrong, and
/// a live "Check again" invited a click that could only confirm what was already
/// true.
/// What the Providers header says when every tracked CLI is answering.
///
/// A state, not a control: there is nothing to press when nothing is wrong, and
/// a live "Check again" invited a click that could only confirm what was already
/// true.
/// A provider row's own state, in the two marks this pane already speaks in.
private struct ProviderState: View {
    let isInstalled: Bool

    var body: some View {
        Image(systemName: isInstalled ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
            .font(.system(size: 12))
            .foregroundStyle(isInstalled ? Tokens.green : Tokens.amber)
            .frame(width: 20)
            .accessibilityLabel(isInstalled ? Text("Tracking") : Text("No CLI found"))
            .help(isInstalled ? "Tracking this provider" : "No CLI found on this Mac")
    }
}

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
    /// Inside a provider's row rather than alone in a section: the two figures
    /// move to the end of the track and the 0/100 ticks go, because the row
    /// above already says whose marks these are.
    var isCompact = false

    /// One point apart at the closest: a zero-width amber band is a rule with a
    /// step in it that nobody can see.
    private let minimumGap: Double = 1
    private let track: CGFloat = 8
    private let knob: CGFloat = 16

    private enum Handle { case warn, critical }
    @State private var dragging: Handle?

    var body: some View {
        VStack(alignment: .leading, spacing: isCompact ? 0 : 11) {
            if !isCompact {
                HStack(spacing: 0) {
                    legend("Watch starts at", warn, Tokens.amber)
                    Spacer(minLength: 12)
                    legend("Over starts at", critical, Tokens.red)
                }
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

            if !isCompact {
                HStack {
                    Text("0%")
                    Spacer()
                    Text("100%")
                }
                .font(Typography.mono(9.5))
                .foregroundStyle(.white.opacity(0.3))
            }
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

    private func legend(_ title: LocalizedStringKey, _ value: Double, _ tone: Color) -> some View {
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
