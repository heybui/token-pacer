import SwiftUI

/// The design's three groups. Read-only surfaces elsewhere; this is the only
/// place in the app that changes anything.
struct PreferencesView: View {
    @Bindable var preferences: Preferences
    var launchAtLogin: LaunchAtLogin

    @State private var launchEnabled = false

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            group("Alerts") {
                row("Warn at") {
                    ThresholdSlider(value: $preferences.warnAt, range: 50...95,
                                    tone: Tokens.amber)
                }
                row("Critical at") {
                    ThresholdSlider(value: $preferences.criticalAt, range: 60...100,
                                    tone: Tokens.red)
                }
                row("Sound on threshold") {
                    Toggle("", isOn: $preferences.soundOnThreshold).labelsHidden()
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
                row("Open panel") {
                    Text("⌘⇧B")
                        .font(Typography.mono(11.5))
                        .foregroundStyle(.white.opacity(0.7))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 5))
                }
            }

            HStack(alignment: .bottom, spacing: 16) {
                Text(footnote)
                    .font(Typography.sans(11))
                    .foregroundStyle(.white.opacity(0.4))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button("Reset") { preferences.reset() }
                    .buttonStyle(.plain)
                    .font(Typography.sans(11.5))
                    .foregroundStyle(preferences.isDefault ? .white.opacity(0.25) : Tokens.amber)
                    .disabled(preferences.isDefault)
                    .help("Back to 75% and 90%, sound on, pill hidden when dormant")
                    .fixedSize()
            }
        }
        .padding(26)
        .frame(width: 420)
        .background(Color(hex: 0x141416))
        .environment(\.colorScheme, .dark)
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

/// A slider that shows the figure it is setting; a bare handle says nothing.
private struct ThresholdSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let tone: Color

    var body: some View {
        HStack(spacing: 12) {
            Slider(value: $value, in: range, step: 1)
                .frame(width: 170)
                .tint(tone)
            Text("\(Int(value))%")
                .font(Typography.mono(11.5))
                .foregroundStyle(tone)
                .frame(width: 34, alignment: .trailing)
        }
    }
}
