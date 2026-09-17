import AppKit
import SwiftUI

/// The shell's outline minus its top edge: an open path from the top-left corner,
/// down and round the bottom, up to the top-right.
///
/// Open, not closed. The top edge lies against the notch, and a light run along
/// it is a light run under the hardware — half of it eaten, the rest reading as a
/// seam. The bottom is always in open screen: every shell keeps either a body or
/// `PillState.overhang` below the notch, so this is one straight sweep and never
/// a climb around the hardware. Drawn in traversal order, so `trim` positions and
/// the eye agree: 0 is the left, 1 is the right.
struct ShellTrack: Shape {
    var cornerRadius: CGFloat
    var inset: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let left = rect.minX + inset
        let right = rect.maxX - inset
        let bottom = rect.maxY - inset
        let radius = min(cornerRadius, (right - left) / 2, bottom - rect.minY)

        var path = Path()
        path.move(to: CGPoint(x: left, y: rect.minY))
        // Tangent arcs, not quad curves: the static ring is a circular
        // `UnevenRoundedRectangle`, and the light has to sit on it, not near it.
        path.addArc(
            tangent1End: CGPoint(x: left, y: bottom),
            tangent2End: CGPoint(x: right, y: bottom), radius: radius
        )
        path.addArc(
            tangent1End: CGPoint(x: right, y: bottom),
            tangent2End: CGPoint(x: right, y: rect.minY), radius: radius
        )
        path.addLine(to: CGPoint(x: right, y: rect.minY))
        return path
    }
}

/// A highlight that runs the shell's outline while tokens are flowing.
///
/// Measured in points, not in fractions of the path. The shell morphs from a
/// 226×36 pill to a 404×98 card — more than double the outline — so a tail of
/// "18% of the path" was half the pill and the length of a finger on the card,
/// and it crawled on one and raced on the other. A fixed length at a fixed speed
/// looks like the same light on every state.
///
/// Drawn by CoreAnimation, not by SwiftUI.
///
/// It ran as a `TimelineView` first, over views and then over a `Canvas`. Both
/// drive the light from the main thread, and SwiftUI answers a moving leaf by
/// rebuilding a display list for the whole pill: measured at ~18% of a core,
/// continuously, for a decoration. `strokeStart`/`strokeEnd` animations run on
/// the render server instead — set up once, then nothing per frame.
struct ChasingBorder: NSViewRepresentable {
    var cornerRadius: CGFloat
    var tone: Color
    var isRunning: Bool
    var lineWidth: CGFloat = 1.5
    /// Length of the lit arc, in points.
    var tail: Double = 104
    /// Points per second. 2.6s round the collapsed pill — the ring's breath,
    /// which is where the pairing was set.
    var speed: Double = 200

    func makeNSView(context: Context) -> BorderLight { BorderLight() }

    func updateNSView(_ view: BorderLight, context: Context) {
        view.apply(.init(
            cornerRadius: cornerRadius, tone: tone, lineWidth: lineWidth,
            tail: tail, speed: speed, isRunning: isRunning
        ))
    }
}

/// The layers the light is made of, and the one place their animations are built.
final class BorderLight: NSView {
    struct Look: Equatable {
        var cornerRadius: CGFloat
        /// SwiftUI's own `Color`, not an `NSColor` made from it. Two `NSColor`s
        /// converted from the same `Color` do not compare equal, so holding one
        /// here made `sameShape` false on every update — and the light tore down
        /// and restarted all fifty of its animations several times a second.
        var tone: Color
        var lineWidth: CGFloat
        var tail: Double
        var speed: Double
        var isRunning: Bool

        /// Everything the layers are built from. `isRunning` only starts and stops
        /// them, so a change to it alone must not tear them down and restart the
        /// light at the left edge.
        func sameShape(as other: Look) -> Bool {
            cornerRadius == other.cornerRadius && tone == other.tone
                && lineWidth == other.lineWidth && tail == other.tail && speed == other.speed
        }
    }

    /// The tail is drawn as this many arcs of falling opacity and width.
    ///
    /// A gradient *stroke* cannot do it: a gradient fades by position in the view,
    /// so the head vanished down the left and right edges and the light appeared
    /// to run along the top and bottom only. Opacity has to follow the path, and
    /// the path is the only thing that knows where it goes.
    private static let segments = 24

    private var strokes: [CAShapeLayer] = []
    /// Pending reinstall, coalesced. See `layout()`.
    private var settle: DispatchWorkItem?
    private var look: Look?
    private var built: CGSize = .zero

    /// The cycle is measured from here, and this is never reset. A shell morph
    /// rebuilds every animation; anchoring them all to one epoch means the light
    /// carries on from where it was instead of snapping back to the left edge.
    private let epoch = CACurrentMediaTime()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    @available(*, unavailable) required init?(coder: NSCoder) { nil }

    /// SwiftUI's coordinate space, because `ShellTrack` is written in it: the top
    /// edge is `minY`. Unflipped, the light would run around the top.
    override var isFlipped: Bool { true }

    /// The pill's own tracking area owns the pointer. An overlay that answers
    /// hit tests would swallow hover and the card would never open.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        guard bounds.size != built else { return }
        // Claimed before the work, not after: AppKit calls this on every display
        // cycle while a layer animates, and a rebuild that re-enters layout would
        // then rebuild for ever.
        built = bounds.size
        retrack()
        guard look?.isRunning == true else { return }

        // The shell morphs on a spring, so during a collapse or an expand the
        // bounds arrive changed on every single frame. The sweep's duration is
        // derived from the track's length, so reinstalling on each one restarted
        // all fifty animations mid-sweep and the light read as chaos.
        //
        // The path still follows every frame — that is `retrack`, and it is free.
        // Only the timing waits for the size to stop moving, which costs the
        // light the morph's own length at the old speed and nothing else.
        settle?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.animate() }
        settle = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.settleDelay, execute: work)
    }

    /// Longer than the shell's spring, so one reinstall lands after it, not during.
    private static let settleDelay: TimeInterval = 0.45

    private func track(for size: CGSize) -> CGFloat { max(1, size.width + 2 * size.height) }

    /// The path only. Cheap enough to run on any layout pass, and it leaves the
    /// running animations alone.
    private func retrack() {
        guard let look, bounds.width > 0, bounds.height > 0 else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let path = ShellTrack(cornerRadius: look.cornerRadius, inset: look.lineWidth / 2)
            .path(in: CGRect(origin: .zero, size: bounds.size)).cgPath
        for stroke in strokes {
            stroke.path = path
            stroke.frame = bounds
        }
        CATransaction.commit()
    }

    func apply(_ new: Look) {
        let shapeChanged = look.map { !$0.sameShape(as: new) } ?? true
        let wasRunning = look?.isRunning
        look = new

        if shapeChanged || bounds.size != built {
            rebuild()
        } else if wasRunning != new.isRunning {
            new.isRunning ? animate() : strokes.forEach { $0.removeAllAnimations() }
        }
        fade(to: new.isRunning ? 1 : 0, animated: wasRunning != nil)
    }

    private func rebuild() {
        guard let look, bounds.width > 0, bounds.height > 0 else { return }
        built = bounds.size

        // No implicit animations: every one of these is set outright, and CA would
        // otherwise cross-fade each colour and path change over a quarter second.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        let path = ShellTrack(cornerRadius: look.cornerRadius, inset: look.lineWidth / 2)
            .path(in: CGRect(origin: .zero, size: bounds.size)).cgPath

        if strokes.count != Self.segments + 2 {
            strokes.forEach { $0.removeFromSuperlayer() }
            strokes = (0..<(Self.segments + 2)).map { _ in
                let layer = CAShapeLayer()
                layer.fillColor = nil
                layer.lineCap = .round
                // Nothing drawn until an animation moves them apart, so a paused
                // light is not a full outline sitting on the shell.
                layer.strokeStart = 0
                layer.strokeEnd = 0
                self.layer?.addSublayer(layer)
                return layer
            }
        }

        for (index, stroke) in strokes.enumerated() {
            stroke.path = path
            stroke.frame = bounds
            let (opacity, width) = ramp(at: index, look: look)
            stroke.strokeColor = NSColor(look.tone).withAlphaComponent(opacity).cgColor
            stroke.lineWidth = width
        }
        if look.isRunning { animate() }
    }

    /// Opacity and width along the tail. The last two layers are the head: a crisp
    /// stroke and a wider, fainter one under it, which is the glow. It used to be
    /// a Gaussian blur, and a blur is an offscreen pass every frame for a halo on
    /// a 1.5pt line.
    private func ramp(at index: Int, look: Look) -> (opacity: CGFloat, width: CGFloat) {
        switch index {
        case Self.segments: (0.25, look.lineWidth * 3)       // halo
        case Self.segments + 1: (0.9, look.lineWidth)        // head
        default:
            // 0 at the end of the tail, 1 at the head. Cubed, not linear: the tail
            // has to dissolve into the ring rather than end on a step, and the eye
            // finds a linear ramp's shoulder every time.
            {
                let t = Double(index) / Double(Self.segments - 1)
                return (CGFloat(t * t * t), look.lineWidth * (0.35 + 0.65 * t))
            }()
        }
    }

    private func animate() {
        guard let look else { return }
        let track = max(1, bounds.width + 2 * bounds.height)
        let length = min(0.5, look.tail / track)
        // The head runs from the start to one tail past the end, so the light
        // drains off the right rather than being cut mid-glow and restarting.
        // `strokeStart`/`strokeEnd` clamp to 0...1 on their own, which is exactly
        // the clipping the old hand-rolled version did at both ends.
        let sweep = 1 + length
        let duration = track * sweep / look.speed
        let step = length / Double(Self.segments)

        for (index, stroke) in strokes.enumerated() {
            // How far this layer trails the head, as a fraction of the path.
            let trail = index >= Self.segments
                ? step
                : length * (1 - Double(index) / Double(Self.segments - 1))
            // Overlapped: exact joins leave hairline gaps that strobe as the
            // light moves.
            let span = index >= Self.segments ? step : step * 1.8

            stroke.removeAllAnimations()
            stroke.add(sweepAnimation("strokeStart", from: -trail,
                                      sweep: sweep, duration: duration), forKey: "start")
            stroke.add(sweepAnimation("strokeEnd", from: -trail + span,
                                      sweep: sweep, duration: duration), forKey: "end")
        }
    }

    private func sweepAnimation(
        _ keyPath: String, from: Double, sweep: Double, duration: Double
    ) -> CABasicAnimation {
        let animation = CABasicAnimation(keyPath: keyPath)
        animation.fromValue = from
        animation.toValue = from + sweep
        animation.duration = duration
        animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: .linear)
        animation.beginTime = epoch
        animation.isRemovedOnCompletion = false
        animation.fillMode = .both
        return animation
    }

    private func fade(to opacity: Float, animated: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        CATransaction.setAnimationDuration(0.3)
        layer?.opacity = opacity
        CATransaction.commit()
    }
}
