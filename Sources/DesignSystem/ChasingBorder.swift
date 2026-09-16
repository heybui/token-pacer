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

    @State private var phase: Double = 0

    var body: some View {
        ZStack {
            segment(from: phase, to: min(1, phase + length))
            // `trim` does not wrap, so the tail is drawn again from the start.
            if phase + length > 1 {
                segment(from: 0, to: phase + length - 1)
            }
        }
        .opacity(isRunning ? 1 : 0)
        .animation(.easeOut(duration: 0.3), value: isRunning)
        .onAppear { run(isRunning) }
        .onChange(of: isRunning) { _, running in run(running) }
    }

    private func segment(from start: Double, to end: Double) -> some View {
        shape
            .inset(by: lineWidth / 2)
            .trim(from: start, to: end)
            .stroke(
                // Faded at both ends: a hard-edged arc looks like a rendering
                // artefact, a tapered one looks like light travelling.
                LinearGradient(
                    colors: [tone.opacity(0), tone.opacity(0.95), tone.opacity(0)],
                    startPoint: .leading, endPoint: .trailing
                ),
                style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
            )
            .shadow(color: tone.opacity(0.5), radius: 3)
    }

    private func run(_ running: Bool) {
        guard running else {
            // Stop where it is rather than snapping to the start: the fade-out
            // hides the rest.
            withAnimation(.linear(duration: 0)) { phase = phase }
            return
        }
        phase = 0
        withAnimation(.linear(duration: duration).repeatForever(autoreverses: false)) {
            phase = 1
        }
    }
}
