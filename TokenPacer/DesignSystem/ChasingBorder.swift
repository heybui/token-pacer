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
///
/// Which light it is comes from `BorderEffect`; this only knows how to install
/// the pieces one is made of.
struct ChasingBorder: NSViewRepresentable {
    var cornerRadius: CGFloat
    var tone: Color
    /// The head's own colour, a step brighter than the zone it runs in.
    var light: Color
    var effect: BorderEffect = .comet
    var isRunning: Bool
    var lineWidth: CGFloat = 1.5

    func makeNSView(context: Context) -> BorderLight { BorderLight() }

    func updateNSView(_ view: BorderLight, context: Context) {
        view.apply(.init(
            cornerRadius: cornerRadius, tone: tone, light: light,
            effect: effect, lineWidth: lineWidth, isRunning: isRunning
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
        var light: Color
        var effect: BorderEffect
        var lineWidth: CGFloat
        var isRunning: Bool

        /// Everything the layers are built from. `isRunning` only starts and stops
        /// them, so a change to it alone must not tear them down and restart the
        /// light at the left edge.
        func sameShape(as other: Look) -> Bool {
            cornerRadius == other.cornerRadius && tone == other.tone
                && light == other.light && effect == other.effect
                && lineWidth == other.lineWidth
        }

        var pieces: [BorderPiece] {
            effect.pieces(
                tone: tone, light: light,
                zones: (Tokens.green, Tokens.amber, Tokens.red), lineWidth: lineWidth
            )
        }
    }

    private var strokes: [CAShapeLayer] = []
    private var pieces: [BorderPiece] = []
    /// Pending reinstall, coalesced. See `layout()`.
    private var settle: Task<Void, Never>?
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

    /// The host's tracking area owns the pointer. An overlay that answers hit
    /// tests would swallow hover and the card would never open.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        guard bounds.size != built else { return }
        // Claimed before the work, not after: AppKit calls this on every display
        // cycle while a layer animates, and a rebuild that re-enters layout would
        // then rebuild for ever.
        built = bounds.size
        // The first real size. `apply` runs before AppKit has given this view any
        // bounds, and a rebuild at zero draws nothing and builds nothing — in the
        // pill that healed itself on the next state change, and in a settings tile
        // that never comes, so all twelve sat black.
        guard !strokes.isEmpty else { return rebuild() }
        retrack()
        guard look?.isRunning == true else { return }

        // The shell morphs on a spring, so during a collapse or an expand the
        // bounds arrive changed on every single frame. A sweep's duration is
        // derived from the track's length, so reinstalling on each one restarted
        // every animation mid-sweep and the light read as chaos.
        //
        // The path still follows every frame — that is `retrack`, and it is free.
        // Only the timing waits for the size to stop moving, which costs the
        // light the morph's own length at the old speed and nothing else.
        settle?.cancel()
        settle = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.settleDelay))
            guard !Task.isCancelled else { return }
            self?.animate()
        }
    }

    /// Longer than the shell's spring, so one reinstall lands after it, not during.
    private static let settleDelay: TimeInterval = 0.45

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
        pieces = look.pieces

        // No implicit animations: every one of these is set outright, and CA would
        // otherwise cross-fade each colour and path change over a quarter second.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        let path = ShellTrack(cornerRadius: look.cornerRadius, inset: look.lineWidth / 2)
            .path(in: CGRect(origin: .zero, size: bounds.size)).cgPath

        if strokes.count != pieces.count {
            strokes.forEach { $0.removeFromSuperlayer() }
            strokes = pieces.map { _ in
                let layer = CAShapeLayer()
                layer.fillColor = nil
                layer.lineCap = .round
                self.layer?.addSublayer(layer)
                return layer
            }
        }

        for (piece, stroke) in zip(pieces, strokes) {
            stroke.path = path
            stroke.frame = bounds
            stroke.strokeColor = NSColor(piece.color)
                .withAlphaComponent(piece.opacity).cgColor
            stroke.lineWidth = piece.width
            // Spelled out rather than `map(NSNumber.init)`: that picked an
            // overload CoreAnimation could not read back, and the crash landed
            // inside the render-layer copy with no mention of this line.
            stroke.lineDashPattern = piece.dash.isEmpty
                ? nil
                : piece.dash.map { NSNumber(value: Double($0)) }
            switch piece.motion {
            case .sweep:
                // Nothing drawn until an animation moves them apart, so a paused
                // light is not a full outline sitting on the shell.
                stroke.strokeStart = 0
                stroke.strokeEnd = 0
            case .pulse, .dash:
                stroke.strokeStart = 0
                stroke.strokeEnd = 1
            }
        }
        if look.isRunning { animate() }
    }

    /// Where each segment of the outline begins and ends, as fractions of the
    /// track. The traversal is left edge, bottom, right edge — so the ranges are
    /// the edges' own lengths in order.
    private func range(of segment: BorderPiece.Segment) -> ClosedRange<Double> {
        let height = Double(bounds.height), width = Double(bounds.width)
        let track = max(1, width + 2 * height)
        return switch segment {
        case .whole: 0...1
        case .left: 0...(height / track)
        case .bottom: (height / track)...((height + width) / track)
        case .right: ((height + width) / track)...1
        }
    }

    private func animate() {
        guard look != nil else { return }
        let track = max(1, Double(bounds.width) + 2 * Double(bounds.height))
        // Every piece travelling the same part of the outline has to finish its
        // lap at the same moment as the rest, or the zone sweep's three colours
        // drift apart and open gaps: they move at one speed but each restarts
        // when it alone reaches the end. One margin per segment, the longest
        // piece's, makes the lap the same length for all of them.
        let margins = Dictionary(grouping: pieces, by: \.segment)
            .mapValues { $0.map(\.length).max() ?? 0 }

        for (piece, stroke) in zip(pieces, strokes) {
            stroke.removeAllAnimations()
            switch piece.motion {
            case .sweep:
                install(
                    sweep: piece, on: stroke, track: track,
                    margin: margins[piece.segment] ?? piece.length
                )
            case .pulse: install(pulse: piece, on: stroke)
            case .dash: install(dash: piece, on: stroke, track: track)
            }
        }
    }

    /// The band runs from just before its own segment to just past the end of it,
    /// so it enters and leaves rather than being cut on at the boundary.
    /// `strokeStart`/`strokeEnd` clamp to 0...1 on their own, which is exactly the
    /// clipping this needs at both ends.
    ///
    /// A piece confined to one edge measures itself against *that edge*: a third
    /// of the outline is most of a 34pt side and a quarter of the bottom, and a
    /// side runner longer than its own side is a runner nobody can see move.
    private func install(
        sweep piece: BorderPiece, on stroke: CAShapeLayer, track: Double, margin: Double
    ) {
        let span = range(of: piece.segment)
        let width = span.upperBound - span.lowerBound
        let scale = piece.segment == .whole ? 1 : width
        let length = piece.length * scale
        let trail = piece.trail * scale
        let distance = width + margin * scale
        let duration = max(0.05, distance * track / piece.speed)

        // The head of the whole effect, which this piece follows at its own
        // distance behind.
        let base = piece.reversed
            ? span.upperBound + trail
            : span.lowerBound - margin * scale - trail
        let end = piece.reversed ? base - distance : base + distance

        stroke.add(
            sweepAnimation("strokeStart", from: base, to: end, duration: duration, piece: piece),
            forKey: "start"
        )
        stroke.add(
            sweepAnimation(
                "strokeEnd", from: base + length, to: end + length,
                duration: duration, piece: piece
            ),
            forKey: "end"
        )
    }

    private func install(pulse piece: BorderPiece, on stroke: CAShapeLayer) {
        let breath = CABasicAnimation(keyPath: "opacity")
        breath.fromValue = 0.22
        breath.toValue = 1
        breath.duration = piece.period / 2
        breath.autoreverses = true
        breath.repeatCount = .infinity
        breath.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        breath.beginTime = epoch
        breath.isRemovedOnCompletion = false
        breath.fillMode = .both
        stroke.add(breath, forKey: "pulse")
    }

    /// One dash pattern's worth of travel, repeated. The train never restarts,
    /// because moving by exactly one period leaves the outline looking identical.
    private func install(dash piece: BorderPiece, on stroke: CAShapeLayer, track: Double) {
        let period = piece.dash.reduce(0, +)
        guard period > 0 else { return }
        let creep = CABasicAnimation(keyPath: "lineDashPhase")
        creep.fromValue = 0
        creep.toValue = -period
        creep.duration = Double(period) / piece.speed
        creep.repeatCount = .infinity
        creep.timingFunction = CAMediaTimingFunction(name: .linear)
        creep.beginTime = epoch
        creep.isRemovedOnCompletion = false
        creep.fillMode = .both
        stroke.add(creep, forKey: "dash")
    }

    private func sweepAnimation(
        _ keyPath: String, from: Double, to: Double, duration: Double, piece: BorderPiece
    ) -> CABasicAnimation {
        let animation = CABasicAnimation(keyPath: keyPath)
        animation.fromValue = from
        animation.toValue = to
        animation.duration = duration
        animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: .linear)
        // Anchored to the one epoch, less this piece's own head start: two heads
        // half a lap apart are one animation started half a lap ago.
        animation.beginTime = epoch - piece.phase * duration
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
