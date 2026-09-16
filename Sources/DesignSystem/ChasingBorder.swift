import SwiftUI

/// A highlight that runs the shell's outline while tokens are flowing.
///
/// The same signal as the activity dot, on the same 2.6s cycle, so the two beat
/// together rather than against each other — one is legible from across the room,
/// the other from arm's length.
struct ChasingBorder<S: InsettableShape>: View {
    let shape: S
    var tone: Color
    var isRunning: Bool
    var lineWidth: CGFloat = 1.5
    /// Fraction of the outline lit at once. Long enough to read as motion on a
    /// 226pt pill, short enough not to become a plain border on a 404pt card.
    var length: Double = 0.18
    /// `PulsingDot`'s full cycle.
    var duration: Double = 2.6

    /// The tail is drawn as this many arcs of falling opacity.
    ///
    /// A gradient *stroke* cannot do it: `LinearGradient` fades by position in the
    /// view, so the head vanished down the left and right edges and the light
    /// appeared to run along the top and bottom only. Opacity has to follow the
    /// path, and the path is the only thing that knows where it goes.
    private let segments = 10

    @State private var phase: Double = 0

    var body: some View {
        ZStack {
            ForEach(0..<segments, id: \.self) { index in
                let step = length / Double(segments)
                let start = phase + step * Double(index)
                // Overlapped by a hair: exact joins leave hairline gaps that
                // strobe as the arc moves.
                arc(from: start, to: start + step * 1.25,
                    opacity: 0.1 + 0.9 * Double(index + 1) / Double(segments))
            }
        }
        .shadow(color: tone.opacity(0.45), radius: 3)
        .opacity(isRunning ? 1 : 0)
        .animation(.easeOut(duration: 0.3), value: isRunning)
        .onAppear { run(isRunning) }
        .onChange(of: isRunning) { _, running in run(running) }
    }

    /// `trim` does not wrap, so an arc crossing the start of the path is drawn as
    /// two — otherwise it bites off at the same corner every cycle.
    @ViewBuilder
    private func arc(from start: Double, to end: Double, opacity: Double) -> some View {
        let from = start.truncatingRemainder(dividingBy: 1)
        let to = end.truncatingRemainder(dividingBy: 1)

        if to > from {
            stroke(from: from, to: to, opacity: opacity)
        } else {
            stroke(from: from, to: 1, opacity: opacity)
            stroke(from: 0, to: to, opacity: opacity)
        }
    }

    private func stroke(from: Double, to: Double, opacity: Double) -> some View {
        shape
            .inset(by: lineWidth / 2)
            .trim(from: from, to: to)
            .stroke(
                tone.opacity(opacity),
                style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
            )
    }

    private func run(_ running: Bool) {
        guard running else { return }   // the fade-out covers stopping in place
        phase = 0
        withAnimation(.linear(duration: duration).repeatForever(autoreverses: false)) {
            phase = 1
        }
    }
}
