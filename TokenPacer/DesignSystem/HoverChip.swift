import SwiftUI

/// The lift every pressable thing in the panels wears under the pointer.
///
/// A dark panel with flat icons gives nothing away about what can be pressed:
/// the gear, the close cross and the refresh looked exactly like the figures
/// beside them. One modifier, so a new control cannot arrive without it and the
/// twelve that exist cannot drift apart.
struct HoverChip: ViewModifier {
    var cornerRadius: CGFloat = 6
    /// How far the shape is pushed out past the content it sits behind.
    var padding: CGFloat = 4
    /// False for a control that is disabled. `.disabled()` stops the click but
    /// not the pointer, so without this a greyed-out button still lit up under
    /// it and invited the press it was going to ignore.
    var isActive = true

    @State private var isHovering = false

    func body(content: Content) -> some View {
        content
            // Enough to read at a glance on a black panel: a 42%-white glyph
            // lifted by a quarter was a change you had to be looking for.
            .brightness(isHovering ? 0.45 : 0)
            .background {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(.white.opacity(isHovering ? 0.16 : 0))
                    .padding(-padding)
            }
            .animation(.easeOut(duration: 0.12), value: isHovering)
            .onHover { isHovering = $0 && isActive }
    }
}

extension View {
    func hoverChip(
        cornerRadius: CGFloat = 6, padding: CGFloat = 4, isActive: Bool = true
    ) -> some View {
        modifier(HoverChip(cornerRadius: cornerRadius, padding: padding, isActive: isActive))
    }
}
