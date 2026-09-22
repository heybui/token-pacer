import SwiftUI

/// The app's own tooltip, drawn the moment the pointer arrives.
///
/// AppKit's only appears while the app is frontmost, and this one is an
/// accessory: its windows can be open, clicked and hovered with the app in the
/// background — which is exactly when somebody wonders what a two-glyph icon
/// does. It also waits a second before it shows, and a pointer resting on a
/// 22pt target does not wait.
struct Tooltip: ViewModifier {
    let text: LocalizedStringKey
    /// Which side of the control it hangs off, so a tip near the window's edge
    /// does not have to be read half off it.
    var edge: HorizontalAlignment = .trailing
    /// Above instead of below, for a control on the bottom edge of a window
    /// that does not resize: under it, the tip is drawn outside the window and
    /// clipped to nothing.
    var above = false

    @State private var isShowing = false

    func body(content: Content) -> some View {
        content
            .onHover { isShowing = $0 }
            .overlay(alignment: placement) {
                if isShowing {
                    Text(text)
                        .font(Typography.sans(11))
                        .foregroundStyle(.white.opacity(0.85))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 6)
                        .background(Tokens.tooltipFill, in: .rect(cornerRadius: 7))
                        .overlay {
                            RoundedRectangle(cornerRadius: 7)
                                .strokeBorder(.white.opacity(0.12), lineWidth: 1)
                        }
                        .fixedSize()
                        // Clear of the control: over the top of it and the tip
                        // covers the thing being pointed at.
                        .offset(y: above ? -30 : 30)
                        // It is something to read, never something to hit: left
                        // hittable it would take the pointer off the control and
                        // hide itself.
                        .allowsHitTesting(false)
                        .transition(.opacity)
                        .zIndex(1)
                }
            }
            .animation(.easeOut(duration: 0.1), value: isShowing)
    }

    private var placement: Alignment {
        switch (above, edge == .trailing) {
        case (false, true): .bottomTrailing
        case (false, false): .bottomLeading
        case (true, true): .topTrailing
        case (true, false): .topLeading
        }
    }
}

extension View {
    func tooltip(
        _ text: LocalizedStringKey, edge: HorizontalAlignment = .trailing, above: Bool = false
    ) -> some View {
        modifier(Tooltip(text: text, edge: edge, above: above))
    }
}
