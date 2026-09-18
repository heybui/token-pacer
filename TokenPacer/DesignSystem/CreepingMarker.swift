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
    /// What "working" looks like for this mark. A marker on a line creeps along
    /// it; a dot on a ring has nowhere to creep to, so it breathes instead.
    enum Motion: Equatable { case creep, pulse }

    var color: Color
    var width: CGFloat
    var height: CGFloat
    /// How far it creeps, in points. The board's mark drifts 3.5pt on a 46pt bar.
    var distance: CGFloat = 3
    var motion: Motion = .creep
    var isRunning: Bool

    func makeNSView(context: Context) -> MarkerDot { MarkerDot() }

    func updateNSView(_ view: MarkerDot, context: Context) {
        view.apply(.init(
            color: color, width: width, height: height,
            distance: distance, motion: motion, isRunning: isRunning
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
        var motion: CreepingMarker.Motion
        var isRunning: Bool

        /// Everything the layer is built from. `isRunning` only starts and stops
        /// the creep, so a change to it alone must not rebuild the layer.
        func sameShape(as other: Look) -> Bool {
            color == other.color && width == other.width && height == other.height
                && distance == other.distance && motion == other.motion
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

        let move = CABasicAnimation(
            keyPath: next.motion == .creep ? "transform.translation.x" : "transform.scale"
        )
        move.fromValue = next.motion == .creep ? 0 : 1
        // 1.3, not the board's 1.8. The board breathes a dot drawn on a page;
        // this one is 4.5pt on an 18pt ring, and at 1.8 it stopped being a
        // reading on a track and became a blob covering three of them.
        move.toValue = next.motion == .creep ? next.distance : 1.3
        move.duration = next.motion == .creep ? 0.8 : 0.625
        move.autoreverses = true
        move.repeatCount = .infinity
        move.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(move, forKey: Self.key)
    }
}
