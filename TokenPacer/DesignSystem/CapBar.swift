import SwiftUI

/// The cap bar: weekly limit, per-model splits, spend. One component, three sizes
/// from the design — 3pt in split rows, 4pt in the hover card, 7pt in the panel.
struct CapBar: View {
    /// Nil draws an empty track rather than a zero fill, so "not known yet" does
    /// not read as "nothing used".
    let percent: Double?
    let tone: Color
    var height: CGFloat = 4
    var trackOpacity: Double = 0.13

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(trackOpacity))
                if let percent {
                    Capsule()
                        .fill(tone)
                        .frame(width: geometry.size.width * min(1, max(0, percent / 100)))
                }
            }
        }
        .frame(height: height)
        .animation(.easeOut(duration: 0.6), value: percent ?? -1)
    }
}
