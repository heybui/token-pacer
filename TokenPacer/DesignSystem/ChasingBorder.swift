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

/// A light that runs the shell's outline while tokens are flowing.
///
/// Drawn by CoreAnimation, not by SwiftUI. It ran as a `TimelineView` first, over
/// views and then over a `Canvas`. Both drive the light from the main thread, and
/// SwiftUI answers a moving leaf by rebuilding a display list for the whole pill:
/// measured at ~18% of a core, continuously, for a decoration.
///
/// The construction is the board's rendering spec, and the choice it insists on
/// is this one: **the ramp turns, it does not travel**. CSS spins a conic gradient
/// at constant angular speed, so on a shallow wide shell the head sprints across
/// the ends and crawls along the long edges. An animated `strokeStart`/`strokeEnd`
/// moves at constant path speed instead — visibly calmer, and not what the board
/// drew. This port turns a pre-rendered ramp, as the spec asks.
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
        /// and restarted all of its animations several times a second.
        var tone: Color
        var light: Color
        var effect: BorderEffect
        var lineWidth: CGFloat
        var isRunning: Bool

        /// Everything the layers are built from. `isRunning` only starts and stops
        /// them, so a change to it alone must not tear them down.
        func sameShape(as other: Look) -> Bool {
            cornerRadius == other.cornerRadius && tone == other.tone
                && light == other.light && effect == other.effect
                && lineWidth == other.lineWidth
        }
    }

    /// Everything the light paints goes in here, and the mask is what makes it a
    /// border: a band along three sides and nothing along the top.
    private let container = CALayer()
    private let frameMask = CAShapeLayer()
    /// The one light that paints outside the mask, and only outside it: a shadow
    /// cast by the panel's silhouette, with the silhouette itself cut out of it.
    private let glowLayer = CALayer()
    private let glowMask = CAShapeLayer()

    private var turns: [(layer: CALayer, ramp: ConicRamp)] = []
    private var runners: [(layer: CAGradientLayer, band: EdgeBand)] = []
    private var glow: SolidLight?

    private var look: Look?
    private var built: CGSize = .zero

    /// The cycle is measured from here, and this is never reset. A shell morph
    /// re-frames every layer; anchoring the animations to one epoch means the
    /// light carries on from where it was instead of snapping back.
    private let epoch = CACurrentMediaTime()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        // Under the band, so a halo never washes over the hairline it belongs to.
        layer?.addSublayer(glowLayer)
        layer?.addSublayer(container)
        glowMask.fillRule = .evenOdd
        glowMask.fillColor = NSColor.black.cgColor
        glowLayer.mask = glowMask
        // A stroked open path, not the spec's even-odd pair of subpaths: the same
        // 1.5pt band on three sides, out of a shape the app already draws.
        frameMask.fillColor = nil
        frameMask.strokeColor = NSColor.black.cgColor
        frameMask.lineCap = .butt
        container.mask = frameMask
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
        built = bounds.size
        // The first real size. `apply` runs before AppKit has given this view any
        // bounds, and a build at zero draws nothing — in the pill that healed
        // itself on the next state change, and in a settings tile that change
        // never comes, so all twelve sat black.
        if turns.isEmpty && runners.isEmpty && container.sublayers?.isEmpty != false {
            rebuild()
        } else {
            reframe()
        }
    }

    func apply(_ next: Look) {
        let shapeChanged = look.map { !$0.sameShape(as: next) } ?? true
        let wasRunning = look?.isRunning
        look = next

        if shapeChanged {
            rebuild()
        } else if wasRunning != next.isRunning {
            next.isRunning ? animate() : stop()
        }
        fade(to: next.isRunning ? 1 : 0, animated: wasRunning != nil)
    }

    // MARK: - building

    private func rebuild() {
        guard let look, bounds.width > 0, bounds.height > 0 else { return }
        built = bounds.size

        // No implicit animations: every one of these is set outright, and CA would
        // otherwise cross-fade each colour and path change over a quarter second.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        container.sublayers?.forEach { $0.removeFromSuperlayer() }
        turns = []
        runners = []
        glow = nil
        glowLayer.shadowOpacity = 0

        switch look.effect.paint {
        case .angular(let ramps):
            for (index, ramp) in ramps.enumerated() {
                let host = CALayer()
                host.contentsGravity = .resize
                host.contents = ConicRampImage.shared.image(
                    for: ramp, index: index, effect: look.effect,
                    tone: look.tone, light: look.light
                )
                container.addSublayer(host)
                turns.append((host, ramp))
            }

        case .bands(let bands):
            for band in bands {
                let runner = CAGradientLayer()
                let colour = Self.resolve(band.tint, alpha: 1, look: look)
                // Transparent, colour, transparent: the band fades in and out
                // along its own length rather than ending on two hard edges.
                runner.colors = [
                    colour.withAlphaComponent(0).cgColor, colour.cgColor,
                    colour.withAlphaComponent(0).cgColor,
                ]
                runner.locations = [0, 0.5, 1]
                let vertical = band.edge != .bottom
                runner.startPoint = vertical ? CGPoint(x: 0.5, y: 0) : CGPoint(x: 0, y: 0.5)
                runner.endPoint = vertical ? CGPoint(x: 0.5, y: 1) : CGPoint(x: 1, y: 0.5)
                container.addSublayer(runner)
                runners.append((runner, band))
            }

        case .solid(let solid):
            let fill = CALayer()
            fill.backgroundColor = Self.resolve(solid.tint, alpha: solid.alpha, look: look).cgColor
            container.addSublayer(fill)
            if solid.glow { glow = solid }
        }

        reframe()
        if look.isRunning { animate() }
    }

    /// Geometry only. Cheap enough for any layout pass, and the turning ramps do
    /// not care: a rotation is not measured in points.
    private func reframe() {
        guard let look, bounds.width > 0, bounds.height > 0 else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        container.frame = bounds
        frameMask.frame = bounds
        frameMask.lineWidth = look.lineWidth
        frameMask.path = ShellTrack(cornerRadius: look.cornerRadius, inset: look.lineWidth / 2)
            .path(in: CGRect(origin: .zero, size: bounds.size)).cgPath

        // Square, and big enough that no angle of rotation exposes a corner.
        let side = ceil(hypot(bounds.width, bounds.height)) + 2
        for (host, _) in turns {
            host.bounds = CGRect(x: 0, y: 0, width: side, height: side)
            host.position = CGPoint(x: bounds.midX, y: bounds.midY)
        }

        for (runner, band) in runners { frame(runner, band, in: look) }

        // The still lights fill the whole frame; the mask is what shapes them.
        if case .solid = look.effect.paint { container.sublayers?.first?.frame = bounds }

        if glow != nil {
            let silhouette = UnevenRoundedRectangle(
                bottomLeadingRadius: look.cornerRadius, bottomTrailingRadius: look.cornerRadius
            ).path(in: CGRect(origin: .zero, size: bounds.size)).cgPath

            glowLayer.frame = bounds
            glowLayer.shadowColor = NSColor(look.tone).cgColor
            // The panel's own silhouette, so the glow is cast by the shell rather
            // than recomputed from what is drawn in this overlay every frame.
            glowLayer.shadowPath = silhouette

            // And the silhouette cut back out of it. A shadow is drawn *behind*
            // its layer, and this overlay is transparent, so without the cut-out
            // the blur filled the panel as well as haloing it — a green pane with
            // a soft edge instead of a glow on the desktop behind.
            glowMask.frame = bounds
            let outside = CGMutablePath()
            // Down and out from the top edge, never above it. The top edge meets
            // the notch, and a halo cast up there is a halo on the hardware —
            // the same rule that keeps every other light off that edge.
            outside.addRect(CGRect(
                x: -Self.glowReach, y: 0,
                width: bounds.width + 2 * Self.glowReach,
                height: bounds.height + Self.glowReach
            ))
            outside.addPath(silhouette)
            glowMask.path = outside
        }
        if look.isRunning, !runners.isEmpty { animate() }
    }

    /// A vertical band is 52% of the height and one line wide; a horizontal one
    /// 46% of the width. Both sit *on* their edge, and the mask trims them.
    private func frame(_ runner: CAGradientLayer, _ band: EdgeBand, in look: Look) {
        let width = bounds.width, height = bounds.height
        switch band.edge {
        case .left, .right:
            let length = height * band.lengthFraction
            runner.bounds = CGRect(x: 0, y: 0, width: look.lineWidth, height: length)
            runner.position = CGPoint(
                x: band.edge == .left ? look.lineWidth / 2 : width - look.lineWidth / 2,
                y: -length
            )
        case .bottom:
            let length = width * band.lengthFraction
            runner.bounds = CGRect(x: 0, y: 0, width: length, height: look.lineWidth)
            runner.position = CGPoint(x: -length, y: height - look.lineWidth / 2)
        }
    }

    // MARK: - motion

    private func animate() {
        guard let look, look.isRunning else { return }

        for (host, ramp) in turns {
            let turn = CABasicAnimation(keyPath: "transform.rotation.z")
            turn.fromValue = 0
            turn.toValue = ramp.reversed ? -2 * Double.pi : 2 * Double.pi
            turn.duration = ramp.duration
            turn.repeatCount = .infinity
            turn.timingFunction = CAMediaTimingFunction(name: .linear)
            turn.beginTime = epoch
            turn.isRemovedOnCompletion = false
            turn.fillMode = .both
            host.add(turn, forKey: "turn")
        }

        for (runner, band) in runners { install(band, on: runner) }

        if let solid = look.effect.solid, let fill = container.sublayers?.first {
            if let pulse = solid.pulse {
                let breath = CABasicAnimation(keyPath: "opacity")
                breath.fromValue = pulse.lowerBound
                breath.toValue = pulse.upperBound
                breath.duration = solid.duration / 2
                breath.autoreverses = true
                breath.repeatCount = .infinity
                breath.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                breath.beginTime = epoch
                breath.isRemovedOnCompletion = false
                breath.fillMode = .both
                fill.add(breath, forKey: "breathe")
            }
            if solid.glow { installGlow(solid) }
        }
    }

    /// The band travels from a length and a third before its edge to well past
    /// it — the spec's −130% to 230% of its own length — so it enters and leaves
    /// rather than appearing at the corner.
    private func install(_ band: EdgeBand, on runner: CAGradientLayer) {
        let vertical = band.edge != .bottom
        let length = vertical
            ? bounds.height * band.lengthFraction
            : bounds.width * band.lengthFraction
        let travel = CABasicAnimation(keyPath: vertical ? "position.y" : "position.x")
        travel.fromValue = -1.3 * length + length / 2
        travel.toValue = (vertical ? bounds.height : bounds.width) + 1.3 * length
        travel.duration = band.duration
        travel.repeatCount = .infinity
        travel.timingFunction = CAMediaTimingFunction(name: .linear)
        // One shared timeline with per-band offsets, and backwards fill so
        // nothing flashes at its own start.
        travel.beginTime = epoch + band.begin
        travel.isRemovedOnCompletion = false
        travel.fillMode = .backwards
        runner.add(travel, forKey: "travel")
    }

    /// The only light that paints outside the mask. Spread has no Core Animation
    /// equivalent, so the blur carries it.
    private func installGlow(_ solid: SolidLight) {
        let layer = glowLayer
        layer.shadowOffset = CGSize(width: 0, height: 2)
        layer.shadowRadius = 5
        layer.shadowOpacity = 0.28

        let pulse = { (path: String, from: Any, to: Any) -> CABasicAnimation in
            let animation = CABasicAnimation(keyPath: path)
            animation.fromValue = from
            animation.toValue = to
            animation.duration = solid.duration / 2
            animation.autoreverses = true
            animation.repeatCount = .infinity
            animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            animation.beginTime = self.epoch
            animation.isRemovedOnCompletion = false
            animation.fillMode = .both
            return animation
        }
        layer.add(pulse("shadowOpacity", 0.28, 0.9), forKey: "glowAlpha")
        layer.add(pulse("shadowRadius", 5, 20), forKey: "glowBlur")
        layer.add(
            pulse("shadowOffset", CGSize(width: 0, height: 2), CGSize(width: 0, height: 4)),
            forKey: "glowOffset"
        )
    }

    /// Removed, not paused: a resumed session would inherit a stale phase and the
    /// border would appear to jump.
    private func stop() {
        turns.forEach { $0.layer.removeAllAnimations() }
        runners.forEach { $0.layer.removeAllAnimations() }
        container.sublayers?.forEach { $0.removeAllAnimations() }
        glowLayer.removeAllAnimations()
        glowLayer.shadowOpacity = 0
    }

    private func fade(to opacity: Float, animated: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        CATransaction.setAnimationDuration(0.3)
        container.opacity = opacity
        glowLayer.opacity = opacity
        CATransaction.commit()
    }

    /// How far the halo is allowed to reach, and therefore how much of the
    /// outside the cut-out has to cover.
    private static let glowReach: CGFloat = 60

    fileprivate static func resolve(_ tint: BorderTint, alpha: Double, look: Look) -> NSColor {
        let base: NSColor = switch tint {
        case .zone: NSColor(look.tone)
        case .head: NSColor(look.light)
        case .safe: NSColor(Tokens.green)
        case .watch: NSColor(Tokens.amber)
        case .over: NSColor(Tokens.red)
        case .clear: .clear
        }
        return base.withAlphaComponent(alpha)
    }
}

private extension BorderEffect {
    var solid: SolidLight? {
        if case .solid(let solid) = paint { return solid }
        return nil
    }
}

/// The ramps, painted once each and kept.
///
/// `CAGradientLayer.conic` exists and is not good enough: it ignores the mid-stop
/// precision these tables need. The spec says to render the ramp into an image
/// and turn that, so this draws it a degree at a time and caches the result —
/// nothing here runs while the light is running.
@MainActor
private final class ConicRampImage {
    static let shared = ConicRampImage()

    private struct Key: Hashable {
        var effect: String
        var index: Int
        var tone: Color
        var light: Color
    }

    private var cache: [Key: CGImage] = [:]
    /// Least recently asked for first. A ramp is 590KB, and the Appearance pane
    /// asks for thirteen at once — one per tile — while the app itself only ever
    /// runs one. Kept to a handful so the pane's are let go after it closes.
    private var order: [Key] = []
    private let keep = 8
    /// Wide enough that the narrowest dash is a couple of dozen pixels at the rim.
    private let side = 384

    func image(
        for ramp: ConicRamp, index: Int, effect: BorderEffect, tone: Color, light: Color
    ) -> CGImage? {
        let key = Key(effect: effect.rawValue, index: index, tone: tone, light: light)
        order.removeAll { $0 == key }
        order.append(key)
        if let known = cache[key] { return known }

        guard let drawn = draw(ramp, tone: tone, light: light) else { return nil }
        cache[key] = drawn
        while order.count > keep, let oldest = order.first {
            order.removeFirst()
            cache[oldest] = nil
        }
        return drawn
    }

    private func draw(_ ramp: ConicRamp, tone: Color, light: Color) -> CGImage? {
        guard let context = CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        let centre = CGPoint(x: CGFloat(side) / 2, y: CGFloat(side) / 2)
        let radius = CGFloat(side)
        let steps = 720
        for step in 0..<steps {
            let from = Double(step) * 360 / Double(steps)
            let to = Double(step + 1) * 360 / Double(steps)
            let colour = Self.colour(ramp.stops, at: (from + to) / 2, tone: tone, light: light)
            guard colour.a > 0.002 else { continue }
            context.setFillColor(
                red: colour.r, green: colour.g, blue: colour.b, alpha: colour.a
            )
            let wedge = CGMutablePath()
            wedge.move(to: centre)
            // A hair past each end, so neighbouring wedges meet without a seam.
            wedge.addArc(
                center: centre, radius: radius,
                startAngle: Self.radians(from - 0.05), endAngle: Self.radians(to + 0.05),
                clockwise: true
            )
            wedge.closeSubpath()
            context.addPath(wedge)
            context.fillPath()
        }
        return context.makeImage()
    }

    /// Degrees clockwise from twelve o'clock, in the bitmap's own y-up space.
    private static func radians(_ degrees: Double) -> CGFloat {
        CGFloat((90 - degrees) * .pi / 180)
    }

    /// Interpolated the way CSS does it: premultiplied, so a stop fading to
    /// nothing does not drag the colour towards black on the way.
    private static func colour(
        _ stops: [ConicStop], at angle: Double, tone: Color, light: Color
    ) -> (r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat) {
        guard let first = stops.first else { return (0, 0, 0, 0) }
        if angle <= first.angle { return components(first, tone: tone, light: light) }
        for index in 1..<stops.count {
            let before = stops[index - 1], after = stops[index]
            guard angle <= after.angle else { continue }
            let span = after.angle - before.angle
            let t = span <= 0 ? 1 : CGFloat((angle - before.angle) / span)
            let a = components(before, tone: tone, light: light)
            let b = components(after, tone: tone, light: light)
            let alpha = a.a + (b.a - a.a) * t
            guard alpha > 0 else { return (0, 0, 0, 0) }
            let mix = { (x: CGFloat, y: CGFloat, xa: CGFloat, ya: CGFloat) in
                (x * xa + (y * ya - x * xa) * t) / alpha
            }
            return (
                mix(a.r, b.r, a.a, b.a), mix(a.g, b.g, a.a, b.a),
                mix(a.b, b.b, a.a, b.a), alpha
            )
        }
        return components(stops[stops.count - 1], tone: tone, light: light)
    }

    private static func components(
        _ stop: ConicStop, tone: Color, light: Color
    ) -> (r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat) {
        let colour: NSColor = switch stop.tint {
        case .zone: NSColor(tone)
        case .head: NSColor(light)
        case .safe: NSColor(Tokens.green)
        case .watch: NSColor(Tokens.amber)
        case .over: NSColor(Tokens.red)
        case .clear: .clear
        }
        guard let rgb = colour.usingColorSpace(.sRGB) else { return (0, 0, 0, 0) }
        return (rgb.redComponent, rgb.greenComponent, rgb.blueComponent, CGFloat(stop.alpha))
    }
}
