import SwiftUI

/// The donut that mirrors the percentage. Butt caps, not round: the design's ring
/// is a filled arc, not a progress bar bent into a circle.
struct UsageRing: View {
    let percent: Double?
    let tone: Color
    var size: CGFloat
    var lineWidth: CGFloat
    /// Sits in the ring's hole. The design carries it on every ring big enough to
    /// hold it — the 17px pill ring is not, so its figure sits alongside instead.
    var label: String?
    var labelSize: CGFloat = 11

    /// "On reset the ring fills green and pops once." A reset is the only thing
    /// that takes the figure sharply *down* — usage never falls on its own — so
    /// the drop is the trigger, and a threshold keeps a percentage point of
    /// jitter from setting it off.
    private static let resetDrop: Double = 15
    @State private var resets = 0

    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.14), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: (percent ?? 0) / 100)
                .stroke(tone, style: StrokeStyle(lineWidth: lineWidth, lineCap: .butt))
                .rotationEffect(.degrees(-90))
            if let label {
                OdometerText(text: label, size: labelSize, color: tone)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)   // "8.00M" is wider than "45%"
                    .frame(width: size - lineWidth * 2 - 4)
            }
        }
        .frame(width: size, height: size)
        .animation(.easeOut(duration: 0.6), value: percent ?? -1)
        // The design's ringPop: 700ms, overshooting to 1.13 at 42%.
        .keyframeAnimator(initialValue: 1.0, trigger: resets) { view, scale in
            view.scaleEffect(scale)
        } keyframes: { _ in
            CubicKeyframe(1.13, duration: 0.29)
            CubicKeyframe(1.0, duration: 0.41)
        }
        .onChange(of: percent ?? 0) { was, now in
            if was - now >= Self.resetDrop { resets += 1 }
        }
    }
}
