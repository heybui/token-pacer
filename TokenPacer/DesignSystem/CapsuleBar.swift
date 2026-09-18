import SwiftUI

/// The capsule bar: the board's default mark, and the only one that shows a
/// position and all three boundaries at once.
///
/// The track is the scale, not the reading. Three capsules stand for safe, watch
/// and over — always at full colour, always the same widths — and a marker rides
/// them at the provider's percentage. A filled bar would say the same thing with
/// one fewer fact in it: you would know how far along, but not how far from the
/// boundary you are about to cross.
struct CapsuleBar: View {
    /// Nil draws the track with no marker on it: the zones are a scale whether or
    /// not anything has been reported against them.
    let percent: Double?
    /// The same provider's weekly cap, riding the same track as a dot.
    ///
    /// One bar, two readings. A week is the same kind of fact as a five-hour
    /// window — a share of a quota with a reset — so it belongs on the same scale
    /// rather than on a row of its own. The two are told apart by *shape*: the
    /// window is a rule through the track, the week is a dot sitting on it. Fill
    /// and outline were the first idea and the wrong one — a 1.25pt hairline is
    /// what dies first at menu-bar size.
    var weekPercent: Double? = nil
    /// The board's own glyph width. 76 is what it calls the mark's appetite —
    /// "it wants 76px, which is what makes it expensive in a wing" — but that
    /// figure buys a 44pt wordmark beside it, and with one provider there is no
    /// wordmark to name. 46 is what the board actually draws.
    var width: CGFloat = 36
    var height: CGFloat = 4
    var markerHeight: CGFloat = 11
    /// Creeps the marker while a model is answering. The mark's own way of saying
    /// "working", which is what the board asks every mark to carry.
    var isBurning: Bool = false

    @State private var creeping = false

    @Environment(\.tone) private var tone

    /// Each boundary is a gap, not a line. The board leaves 2% between capsules,
    /// a point either side of the threshold, so the eye reads three objects
    /// rather than one bar that changes colour.
    private static let gap: Double = 1

    var body: some View {
        ZStack(alignment: .leading) {
            zone(from: 0, to: tone.warnAt - Self.gap, Tokens.green)
            zone(from: tone.warnAt + Self.gap, to: tone.critAt - Self.gap, Tokens.amber)
            zone(from: tone.critAt + Self.gap, to: 100, Tokens.red)
            // The week first, so a session marker landing on the same point is
            // the one you see.
            if let weekPercent { weekMarker(at: weekPercent) }
            if let percent { marker(at: percent) }
        }
        // The marker overhangs the track top and bottom, so the row is as tall as
        // the marker and the capsules sit centred in it.
        //
        // Leading, not the default centre. Every zone is placed with `.offset`,
        // which draws without taking part in layout, so the stack's own width is
        // its widest child — the safe zone, three quarters of the bar. Centred,
        // that narrower stack sat an eighth of the bar to the right of where the
        // offsets were measured from, and the over zone ran out past the end of
        // the bar into the percentage beside it.
        .frame(width: width, height: markerHeight, alignment: .leading)
        .onChange(of: isBurning, initial: true) { creeping = isBurning }
    }

    private func zone(from start: Double, to end: Double, _ color: Color) -> some View {
        Capsule()
            .fill(color)
            .frame(width: width * (end - start) / 100, height: height)
            .offset(x: width * start / 100)
    }

    /// The week: a dot on the track, ringed in the shell's own black so it reads
    /// against whichever capsule it lands on. A ring drawn as a second filled
    /// circle rather than a shadow — a blur here is the offscreen pass that cost
    /// this view seven times its CPU once already.
    private func weekMarker(at percent: Double) -> some View {
        let clamped = min(100, max(0, percent))
        return ZStack {
            Circle().fill(.black).frame(width: dotSize + 2, height: dotSize + 2)
            Circle().fill(tone.light(clamped)).frame(width: dotSize, height: dotSize)
        }
        .offset(x: width * clamped / 100 - (dotSize + 2) / 2)
        .animation(.easeOut(duration: 0.6), value: percent)
    }

    /// Wider than the track it sits on. At exactly the track's height the dark
    /// ring around it read as a gap cut into the capsule rather than as a bead
    /// lying on top of one — the board's own dot overhangs its ring for the same
    /// reason.
    private var dotSize: CGFloat { height + 2 }

    /// The reading itself, creeping while a model is answering.
    ///
    /// What the board asks for and this does not have is the marker's drop
    /// shadow, measured rather than argued: a blur is an offscreen pass, and with
    /// the creep driving it at the display's refresh rate on a view that is on
    /// screen for hours, the pair took the app from 1.5% of a core to 10.5%. The
    /// creep on its own is a transform on a 2pt capsule and costs nothing like
    /// that; the shadow is what could not stay.
    private func marker(at percent: Double) -> some View {
        let clamped = min(100, max(0, percent))
        return Capsule()
            .fill(tone.light(clamped))
            .frame(width: 2, height: markerHeight)
            .offset(x: width * clamped / 100 - 1 + (creeping ? 3 : 0))
            .animation(
                creeping
                    ? .easeInOut(duration: 0.8).repeatForever(autoreverses: true)
                    : .easeOut(duration: 0.2),
                value: creeping
            )
            .animation(.easeOut(duration: 0.6), value: percent)
    }
}
