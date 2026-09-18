import AppKit
import SwiftUI

/// The mark's marker, and its creep while a model is answering.
///
/// Drawn by CoreAnimation, not by SwiftUI — the same lesson `ChasingBorder`
/// records, learned twice. A `repeatForever` animation on a SwiftUI geometry
/// modifier moves this 2pt capsule by re-laying out the whole hosting view on
/// every display cycle, and this app's host is sized for the pinned panel whether
/// the panel is open or not: **11% of a core, measured, for a 3pt wobble.**
///
/// A `CABasicAnimation` on `transform.translation.x` is installed once and runs
/// on the render server. Nothing happens on the main thread per frame, and the
/// measured cost of running it is nil against the same app with it stopped.
struct CreepingMarker: NSViewRepresentable {
    var color: Color
    var width: CGFloat
    var height: CGFloat
    /// How far it creeps, in points. The board's mark drifts 3.5pt on a 46pt bar.
    var distance: CGFloat = 3
    var isRunning: Bool

    func makeNSView(context: Context) -> MarkerDot { MarkerDot() }

    func updateNSView(_ view: MarkerDot, context: Context) {
        view.apply(.init(
            color: color, width: width, height: height,
            distance: distance, isRunning: isRunning
        ))
    }
}

/// One layer, one animation, and the bookkeeping that stops it being rebuilt.
final class MarkerDot: NSView {
    struct Look: Equatable {
        var color: Color
        var width: CGFloat
        var height: CGFloat
        var distance: CGFloat
        var isRunning: Bool

        /// Everything the layer is built from. `isRunning` only starts and stops
        /// the creep, so a change to it alone must not rebuild the layer.
        func sameShape(as other: Look) -> Bool {
            color == other.color && width == other.width
                && height == other.height && distance == other.distance
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
            layer.cornerRadius = next.width / 2
        }
        guard next.isRunning else { return layer.removeAnimation(forKey: Self.key) }
        guard layer.animation(forKey: Self.key) == nil else { return }

        let creep = CABasicAnimation(keyPath: "transform.translation.x")
        creep.fromValue = 0
        creep.toValue = next.distance
        creep.duration = 0.8
        creep.autoreverses = true
        creep.repeatCount = .infinity
        creep.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(creep, forKey: Self.key)
    }
}
