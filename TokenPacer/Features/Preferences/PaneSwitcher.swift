import SwiftUI

/// The board's own General / Appearance switcher.
///
/// Not `.pickerStyle(.segmented)`: the system control is a light grey bar that
/// stretches to whatever width it is given, and against a #141416 window it read
/// as the brightest thing on screen. The board draws a sunken track just wide
/// enough for the two words, centred, with the chosen pane raised out of it.
struct PaneSwitcher: View {
    @Binding var pane: PreferencesView.Pane

    var body: some View {
        HStack(spacing: 2) {
            ForEach(PreferencesView.Pane.allCases) { option in
                PaneTab(option: option, isSelected: option == pane) { pane = option }
            }
        }
        .padding(2)
        .background(Tokens.switcherTrack, in: .rect(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(.white.opacity(0.05), lineWidth: 1)
        }
        // Applied after the track is drawn, so the track keeps its content width
        // and this only centres it in the row.
        .frame(maxWidth: .infinity)
        .animation(.easeOut(duration: 0.15), value: pane)
        // One control to VoiceOver and to Voice Control, not two buttons that
        // happen to sit next to each other.
        .accessibilityRepresentation {
            Picker("Pane", selection: $pane) {
                ForEach(PreferencesView.Pane.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
        }
    }
}

private struct PaneTab: View {
    let option: PreferencesView.Pane
    let isSelected: Bool
    let select: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: select) {
            Text(option.title)
                .font(Typography.sans(11.5, isSelected ? .medium : .regular))
                .foregroundStyle(.white.opacity(isSelected ? 1 : 0.52))
                .padding(.vertical, 5)
                .padding(.horizontal, 16)
                // One shape that fades, not an `if` that swaps two subtrees: the
                // raised tab keeps its identity as the selection moves, so the
                // two tabs cross-fade instead of both being rebuilt.
                .background {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Tokens.switcherSelected)
                        .shadow(color: .black.opacity(0.4), radius: 1, y: 1)
                        .opacity(isSelected ? 1 : 0)
                }
                // The tab you are *not* on is the one worth answering to: the
                // raised one already looks pressed, and lifting it again under
                // the pointer reads as a second selection.
                .background {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(.white.opacity(isHovering && !isSelected ? 0.07 : 0))
                }
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .onHover { isHovering = $0 }
    }
}
