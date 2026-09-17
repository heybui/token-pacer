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
    /// Tokens are flowing right now. The ring breathes while they are.
    ///
    /// It has to read at 0%, where there is no arc yet — a fresh window is
    /// exactly when you look — so the breath is carried by the track. This
    /// replaced a separate activity dot; it keeps the dot's 2.6s cycle, 1.3s
    /// each way, because that pairing was set on the board.
    ///
    /// The arc used to take a glow on top, as an animated `.shadow`. A shadow is
    /// an offscreen pass, and animating one re-renders it every frame for as long
    /// as the breath runs — which `.repeatForever` means is forever. It cost more
    /// than everything else the ring does put together, for a halo on a 17pt
    /// circle. If it is wanted back, it is a second stroked `Circle`, not a shadow.
    var isBurning: Bool = false

    /// "On reset the ring fills green and pops once." A reset is the only thing
    /// that takes the figure sharply *down* — usage never falls on its own — so
    /// the drop is the trigger, and a threshold keeps a percentage point of
    /// jitter from setting it off.
    private static let resetDrop: Double = 15
    @State private var resets = 0

    var body: some View {
        ZStack {
            TrackRing(tone: tone, lineWidth: lineWidth, isBurning: isBurning)
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

/// The ring's track, and the breath it carries while tokens are flowing.
///
/// Toned while burning, plain while idle: at 0% the track is the whole ring, so
/// it is the only thing that can say anything is happening.
///
/// Driven by CoreAnimation, not by `.repeatForever`. A SwiftUI animation that
/// never completes keeps the display link running for the life of the app and
/// re-evaluates the pill's whole tree on every frame of it. Measured against a
/// build with it switched off: 9.8% of a core, continuously — more than
/// everything else the app did put together, and four times the running light.
private struct TrackRing: NSViewRepresentable {
    var tone: Color
    var lineWidth: CGFloat
    var isBurning: Bool

    func makeNSView(context: Context) -> BreathingRing { BreathingRing() }

    func updateNSView(_ view: BreathingRing, context: Context) {
        view.apply(tone: tone, lineWidth: lineWidth, isBurning: isBurning)
    }
}

final class BreathingRing: NSView {
    private let ring = CAShapeLayer()
    /// SwiftUI's own `Color`, never an `NSColor` made from it: two converted from
    /// the same `Color` do not compare equal, and this would then reinstall the
    /// breath on every update.
    private var applied: (tone: Color, lineWidth: CGFloat, isBurning: Bool)?

    /// 1.3s each way, 2.6s round — the cycle the activity dot used, kept because
    /// that pairing was set on the board.
    private static let halfBreath: CFTimeInterval = 1.3

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        ring.fillColor = nil
        layer?.addSublayer(ring)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { nil }

    /// The pill's own tracking area owns the pointer.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ring.frame = bounds
        // Straddling the bounds, as `Circle().stroke` does — inset and the track
        // sits inside the arc instead of under it.
        ring.path = CGPath(ellipseIn: bounds, transform: nil)
        CATransaction.commit()
    }

    func apply(tone: Color, lineWidth: CGFloat, isBurning: Bool) {
        guard applied.map({ $0 != (tone, lineWidth, isBurning) }) ?? true else { return }
        applied = (tone, lineWidth, isBurning)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ring.lineWidth = lineWidth
        ring.strokeColor = isBurning
            ? NSColor(tone).cgColor
            : NSColor.white.withAlphaComponent(0.14).cgColor
        ring.removeAnimation(forKey: "breath")
        ring.opacity = isBurning ? 0.15 : 1
        CATransaction.commit()

        guard isBurning else { return }
        let breath = CABasicAnimation(keyPath: "opacity")
        breath.fromValue = 0.15
        breath.toValue = 0.40
        breath.duration = Self.halfBreath
        breath.autoreverses = true
        breath.repeatCount = .infinity
        breath.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        ring.add(breath, forKey: "breath")
    }
}
