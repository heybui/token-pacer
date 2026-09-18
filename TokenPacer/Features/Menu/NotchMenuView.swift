import SwiftUI

struct NotchMenuItem: Identifiable {
    let title: String
    var key: String = ""
    /// Items whose feature has not shipped are shown greyed rather than hidden,
    /// so the menu doesn't change shape between releases.
    var isEnabled: Bool = true
    var action: () -> Void = {}

    var id: String { title }
}

/// The design's own menu, not `NSMenu`: 212pt, dark, drawn under the shell and
/// sharing its corner language. A system menu here would look borrowed.
struct NotchMenuView: View {
    let items: [NotchMenuItem]
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(items) { item in
                MenuRow(item: item, onDismiss: onDismiss)
            }
        }
        .padding(PillState.menuPadding)
        .frame(width: PillState.menuWidth)
        .background(Tokens.menuSurface, in: RoundedRectangle(cornerRadius: 9))
        .overlay {
            RoundedRectangle(cornerRadius: 9).strokeBorder(.white.opacity(0.12), lineWidth: 0.5)
        }
        .compositingGroup()
        .shadow(color: .black.opacity(0.5), radius: 20, y: 16)
        .transition(.opacity.combined(with: .offset(y: -6)))
    }
}

private struct MenuRow: View {
    let item: NotchMenuItem
    let onDismiss: () -> Void
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 10) {
            Text(item.title)
            Spacer(minLength: 0)
            if !item.key.isEmpty {
                Text(item.key)
                    .font(Typography.mono(11))
                    .foregroundStyle(.white.opacity(0.4))
            }
        }
        .font(Typography.sans(12.5))
        .foregroundStyle(.white.opacity(item.isEnabled ? 0.9 : 0.35))
        .padding(.horizontal, 9)
        .frame(height: PillState.menuRowHeight)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(.white.opacity(isHovering && item.isEnabled ? 0.12 : 0))
        )
        .contentShape(.rect)
        .onHover { isHovering = $0 }
        .onTapGesture {
            guard item.isEnabled else { return }
            item.action()
            onDismiss()
        }
    }
}
