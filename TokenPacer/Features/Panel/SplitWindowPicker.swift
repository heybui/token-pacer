import SwiftUI

/// Which limit the three splits describe: the headline's window or the longer
/// cap beside it.
///
/// Hand-drawn for the reason `ProviderPicker` is: the panel is a
/// non-activating `NSPanel`, and an AppKit menu inside one either refuses to
/// open or opens where nobody asked.
struct SplitWindowPicker: View {
    let selection: SplitWindow
    /// The two windows' own minutes, so each is named as the panel names it
    /// elsewhere: `5-HOUR`, `WEEKLY`, `MONTHLY`.
    let sessionMinutes: Int?
    let weeklyMinutes: Int?
    let onPick: (SplitWindow) -> Void

    @State private var isOpen = false

    private func name(_ window: SplitWindow) -> String {
        Format.windowTag(window == .session ? sessionMinutes : weeklyMinutes)
    }

    var body: some View {
        Button { isOpen.toggle() } label: {
            HStack(spacing: 6) {
                Text(verbatim: name(selection))
                    .font(Typography.mono(9.5, .semibold))
                    .tracking(1.4)
                    .foregroundStyle(.white.opacity(0.62))
                Image(systemName: "chevron.down")
                    .font(.system(size: 7.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.35))
                    .rotationEffect(.degrees(isOpen ? 180 : 0))
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .hoverChip()
        .accessibilityLabel(Text("Window the splits describe"))
        .animation(.easeOut(duration: 0.12), value: isOpen)
        .overlay(alignment: .topTrailing) {
            if isOpen { list.offset(y: 24) }
        }
        .zIndex(1)
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(SplitWindow.allCases, id: \.self) { window in
                Button {
                    onPick(window)
                    isOpen = false
                } label: {
                    Text(verbatim: name(window))
                        .font(Typography.mono(9.5, .semibold))
                        .tracking(1.4)
                        .foregroundStyle(.white.opacity(window == selection ? 0.9 : 0.5))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 6)
                        .frame(width: 110, alignment: .leading)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .hoverChip(cornerRadius: 6, padding: 0)
            }
        }
        .padding(4)
        .background(Tokens.tooltipFill, in: .rect(cornerRadius: 9))
        .overlay {
            RoundedRectangle(cornerRadius: 9).strokeBorder(.white.opacity(0.12), lineWidth: 1)
        }
        .transition(.opacity)
    }
}
