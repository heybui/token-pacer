import SwiftUI

/// The activity dot. Pulses while tokens are actually flowing, sits still when
/// they are not.
///
/// 2.6s per full cycle, as the design specifies — 1.3s each way with autoreverse.
/// Reduce Motion is deliberately not honoured here.
struct PulsingDot: View {
    let color: Color
    var size: CGFloat = 5
    var isPulsing: Bool

    @State private var dimmed = false

    private var pulse: Animation {
        .easeInOut(duration: 1.3).repeatForever(autoreverses: true)
    }

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .opacity(dimmed ? 0.3 : 1)
            .scaleEffect(dimmed ? 0.78 : 1)
            .onAppear { apply(isPulsing) }
            .onChange(of: isPulsing) { _, pulsing in apply(pulsing) }
    }

    private func apply(_ pulsing: Bool) {
        if pulsing {
            withAnimation(pulse) { dimmed = true }
        } else {
            // Settle back to full rather than freezing mid-fade.
            withAnimation(.easeOut(duration: 0.2)) { dimmed = false }
        }
    }
}
