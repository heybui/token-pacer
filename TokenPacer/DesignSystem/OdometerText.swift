import SwiftUI

/// Digits that roll rather than cut, as the design's `odo()` does.
///
/// Each digit is a 0–9 strip clipped to one glyph height and offset to the value,
/// so a change slides the strip instead of swapping the character. Non-digits —
/// `%`, `h`, `m`, `$`, spaces — are drawn plainly and never move.
struct OdometerText: View {
    let text: String
    var size: CGFloat
    var color: Color
    var weight: Font.Weight = .medium

    private var font: Font { Typography.mono(size, weight) }
    /// Matches the design's `.6em` digit cell.
    private var digitWidth: CGFloat { size * 0.6 }
    private var digitHeight: CGFloat { size * 1.2 }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(text.enumerated()), id: \.offset) { index, character in
                if let value = character.wholeNumberValue, character.isNumber {
                    DigitStrip(
                        value: value, font: font, color: color,
                        width: digitWidth, height: digitHeight
                    )
                } else {
                    Text(String(character))
                        .font(font)
                        .foregroundStyle(color)
                        .fixedSize()
                }
            }
        }
        .frame(height: digitHeight)
    }
}

private struct DigitStrip: View {
    let value: Int
    let font: Font
    let color: Color
    let width: CGFloat
    let height: CGFloat

    /// A hair of blur while the strip is in flight, so the roll reads as motion
    /// rather than a jump. The design does the same with a filter keyframe.
    @State private var settled = true

    var body: some View {
        VStack(spacing: 0) {
            ForEach(0...9, id: \.self) { digit in
                Text(String(digit))
                    .font(font)
                    .foregroundStyle(color)
                    .frame(width: width, height: height)
            }
        }
        .offset(y: -CGFloat(value) * height)
        .frame(width: width, height: height, alignment: .top)
        .clipped()
        .blur(radius: settled ? 0 : 0.5)
        // 0.48, not the board's 0.34: at a third of a second the roll read as a
        // number replacing itself rather than a wheel turning, and the blur it is
        // drawn with had no time to be seen at all.
        .animation(.timingCurve(0.32, 0.72, 0, 1, duration: 0.48), value: value)
        // Out and back, chained on the completion. Written as two plain writes
        // the blur never rendered at all: both landed before SwiftUI's next
        // pass, so the view was only ever evaluated with `settled` true.
        .onChange(of: value) { _, _ in
            // Half the roll out, half of it back, so the blur lives across the
            // whole turn rather than clearing while the wheel is still moving.
            withAnimation(.easeOut(duration: 0.24)) {
                settled = false
            } completion: {
                withAnimation(.easeOut(duration: 0.24)) { settled = true }
            }
        }
    }
}
