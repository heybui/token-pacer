import AppKit
import SwiftUI

/// Every moving part of every mark, and the only thing in the band that moves.
///
/// Drawn by CoreAnimation, not by SwiftUI — the same lesson `ChasingBorder`
/// records, learned twice. A `repeatForever` animation on a SwiftUI geometry
/// modifier moves this 2pt capsule by re-laying out the whole hosting view on
/// every display cycle, and this app's host is sized for the pinned panel whether
/// the panel is open or not: **11% of a core, measured, for a 3pt wobble.**
///
/// A `CABasicAnimation` is installed once and runs on the render server. Nothing
/// happens on the main thread per frame, and the measured cost of running it is
/// nil against the same app with it stopped. Twelve marks share this one view
/// rather than each bringing its own animation: a mark is a static drawing plus,
/// at most, one of these.
struct CreepingMarker: View {
    /// What "working" looks like for this mark. The board gives each mechanism
    /// its own motion — a marker on a line creeps along it, a dot on a ring has
    /// nowhere to creep to so it breathes, a level bobs, a countable increment
    /// charges before it lands, a grain falls.
    enum Motion: Equatable { case creep, pulse, bob, charge, fall }

    var color: Color
    var width: CGFloat
    var height: CGFloat
    /// How far it travels, in points. The board's bar marker drifts 3.5pt on a
    /// 46pt bar; a meniscus bobs 3; a grain falls the height of its chamber.
    var distance: CGFloat = 3
    var motion: Motion = .creep
    /// Square-ended marks — a pip, a matrix cell — are not capsules.
    var cornerRadius: CGFloat?
    var isRunning: Bool

    /// Standing still is a shape, not a hosted view.
    ///
    /// An `NSViewRepresentable` costs a round trip through AppKit layout every
    /// time anything around it changes, and a mark that is not working never
    /// moves — so the interop is worth paying for only while there is something
    /// to animate. Twelve marks redrawing at ten readings a second cost 16% of a
    /// core as hosted views and a fraction of that as shapes.
    var body: some View {
        if isRunning {
            Layer(
                color: color, width: width, height: height, distance: distance,
                motion: motion, cornerRadius: cornerRadius, isRunning: true
            )
        } else {
            RoundedRectangle(cornerRadius: cornerRadius ?? min(width, height) / 2)
                .fill(color)
        }
    }

    private struct Layer: NSViewRepresentable {
        var color: Color
        var width: CGFloat
        var height: CGFloat
        var distance: CGFloat
        var motion: Motion
        var cornerRadius: CGFloat?
        var isRunning: Bool

        func makeNSView(context: Context) -> MarkerDot { MarkerDot() }

        func updateNSView(_ view: MarkerDot, context: Context) {
            view.apply(.init(
                color: color, width: width, height: height, distance: distance,
                motion: motion, cornerRadius: cornerRadius ?? min(width, height) / 2,
                isRunning: isRunning
            ))
        }
    }
}

/// One layer, one animation, and the bookkeeping that stops it being rebuilt.
final class MarkerDot: NSView {
    struct Look: Equatable {
        var color: Color
        var width: CGFloat
        var height: CGFloat
        var distance: CGFloat
        var motion: CreepingMarker.Motion
        var cornerRadius: CGFloat
        var isRunning: Bool

        /// Everything the layer is built from. `isRunning` only starts and stops
        /// the motion, so a change to it alone must not rebuild the layer.
        func sameShape(as other: Look) -> Bool {
            color == other.color && width == other.width && height == other.height
                && distance == other.distance && motion == other.motion
                && cornerRadius == other.cornerRadius
        }
    }

    private static let key = "creep"
    private var look: Look?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func apply(_ next: Look) {
        defer { look = next }
        guard let layer else { return }

        if look?.sameShape(as: next) != true {
            layer.backgroundColor = NSColor(next.color).cgColor
            layer.cornerRadius = next.cornerRadius
        }
        guard next.isRunning else { return layer.removeAnimation(forKey: Self.key) }
        guard layer.animation(forKey: Self.key) == nil else { return }
        layer.add(Self.animation(for: next), forKey: Self.key)
    }

    private static func animation(for look: Look) -> CAAnimation {
        switch look.motion {
        case .creep:
            return basic("transform.translation.x", 0, look.distance, 0.8)
        case .pulse:
            // 1.3, not the board's 1.8. The board breathes a dot drawn on a page;
            // this one is 4.5pt on an 18pt ring, and at 1.8 it stopped being a
            // reading on a track and became a blob covering three of them.
            return basic("transform.scale", 1, 1.3, 0.625)
        case .bob:
            return basic("transform.translation.y", 0, look.distance, 0.75)
        case .charge:
            // The increment that is about to land, arriving before it does. Two
            // properties, one group, still one animation on the render server.
            return group([
                basic("transform.scale", 0.78, 1.18, 0.475),
                basic("opacity", 0.08, 1, 0.475),
            ])
        case .fall:
            // The one motion that does not come back: a grain leaves the upper
            // cone, falls the height of the lower one and is gone.
            let drop = basic("transform.translation.y", 0, -look.distance, 0.8)
            drop.autoreverses = false
            drop.timingFunction = CAMediaTimingFunction(name: .linear)
            let fade = basic("opacity", 1, 0, 0.8)
            fade.autoreverses = false
            return group([drop, fade])
        }
    }

    private static func basic(
        _ path: String, _ from: Double, _ to: Double, _ duration: Double
    ) -> CABasicAnimation {
        let move = CABasicAnimation(keyPath: path)
        move.fromValue = from
        move.toValue = to
        move.duration = duration
        move.autoreverses = true
        move.repeatCount = .infinity
        move.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        return move
    }

    /// The group repeats, not its members: a child that repeats forever inside a
    /// group that does not is clipped to the group's own duration.
    private static func group(_ children: [CABasicAnimation]) -> CAAnimationGroup {
        let duration = children.map(\.duration).max() ?? 1
        for child in children { child.repeatCount = 1 }
        let group = CAAnimationGroup()
        group.animations = children
        group.duration = duration * (children.contains { $0.autoreverses } ? 2 : 1)
        group.repeatCount = .infinity
        return group
    }
}
