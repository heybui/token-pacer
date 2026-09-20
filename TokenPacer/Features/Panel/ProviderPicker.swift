import SwiftUI

/// Which provider the pinned panel is reading about: its name, and a list that
/// exists only while it is being changed.
///
/// Read-only, and deliberately: the pill's own provider is pinned from the hover
/// card, where the three are side by side. This is for reading another one's
/// history without giving up the one the menu bar is watching.
///
/// It lives in whichever row is carrying the panel's title — the band around the
/// notch, or the panel's own header off a notched screen — so there is one line
/// at the top of the panel rather than a title and a row of tabs under it.
///
/// Hand-drawn rather than a `Menu`: the panel is a non-activating `NSPanel`, and
/// an AppKit menu inside one either refuses to open or opens where nobody asked.
/// The notch's own menu is hand-drawn for the same reason.
struct ProviderPicker: View {
    let providers: [UsageSnapshot]
    let shown: SourceID?
    var zones: [SourceID: ToneScale] = [:]
    let onPick: (SourceID) -> Void

    @Environment(\.tone) private var toneScale
    @State private var isOpen = false

    private func scale(_ source: SourceID?) -> ToneScale {
        source.flatMap { zones[$0] } ?? toneScale
    }

    private var current: UsageSnapshot? {
        providers.first { $0.source == shown }
    }

    var body: some View {
        Button { isOpen.toggle() } label: {
            HStack(spacing: 6) {
                Text(shown?.wordmark ?? "")
                    .font(Typography.mono(9.5, .semibold))
                    .tracking(1.4)
                    .foregroundStyle(scale(shown)(current?.sessionPercent))
                Image(systemName: "chevron.down")
                    .font(.system(size: 7.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.35))
                    .rotationEffect(.degrees(isOpen ? 180 : 0))
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .hoverChip()
        .accessibilityLabel(Text("Provider shown in this panel"))
        .animation(.easeOut(duration: 0.12), value: isOpen)
        .overlay(alignment: .topLeading) {
            if isOpen { list.offset(y: 24) }
        }
        .zIndex(1)
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(providers, id: \.source) { provider in
                Button {
                    onPick(provider.source)
                    isOpen = false
                } label: {
                    HStack(spacing: 10) {
                        Text(provider.source.wordmark)
                            .font(Typography.mono(9.5, .semibold))
                            .tracking(1.4)
                            .foregroundStyle(
                                provider.source == shown
                                    ? scale(provider.source)(provider.sessionPercent)
                                    : .white.opacity(0.62)
                            )
                        Spacer(minLength: 8)
                        Text(Format.percent(provider.sessionPercent))
                            .font(Typography.mono(9.5))
                            .foregroundStyle(.white.opacity(0.4))
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .frame(width: 148, alignment: .leading)
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
