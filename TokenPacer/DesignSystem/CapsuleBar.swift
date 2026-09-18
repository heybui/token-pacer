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
            if let percent { marker(at: percent) }
        }
        // The marker overhangs the track top and bottom, so the row is as tall as
        // the marker and the capsules sit centred in it.
        .frame(width: width, height: markerHeight)
        .onChange(of: isBurning, initial: true) { creeping = isBurning }
    }

    private func zone(from start: Double, to end: Double, _ color: Color) -> some View {
        Capsule()
            .fill(color)
            .frame(width: width * (end - start) / 100, height: height)
            .offset(x: width * start / 100)
    }

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
