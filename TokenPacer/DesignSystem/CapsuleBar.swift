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
    var width: CGFloat = 76
    var height: CGFloat = 4
    var markerHeight: CGFloat = 11

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
    }

    private func zone(from start: Double, to end: Double, _ color: Color) -> some View {
        Capsule()
            .fill(color)
            .frame(width: width * (end - start) / 100, height: height)
            .offset(x: width * start / 100)
    }

    /// The reading itself.
    ///
    /// Two things the board asks for are deliberately not here, both measured
    /// rather than argued: the marker's drop shadow and its creep while a model
    /// is answering. Together they took the app from 1.5% of a core to 10.5% —
    /// a blur is an offscreen pass, `repeatForever` drives it at the display's
    /// refresh rate, and this view is on screen for hours at a time. The border
    /// already says "working", and it runs on a clock built for the job.
    private func marker(at percent: Double) -> some View {
        let clamped = min(100, max(0, percent))
        return Capsule()
            .fill(tone.light(clamped))
            .frame(width: 2, height: markerHeight)
            .offset(x: width * clamped / 100 - 1)
            .animation(.easeOut(duration: 0.6), value: percent)
    }
}
