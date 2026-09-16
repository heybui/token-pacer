import SwiftUI

/// The donut that mirrors the percentage. Butt caps, not round: the design's ring
/// is a filled arc, not a progress bar bent into a circle.
struct UsageRing: View {
    let percent: Double?
    let tone: Color
    var size: CGFloat
    var lineWidth: CGFloat

    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.14), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: (percent ?? 0) / 100)
                .stroke(tone, style: StrokeStyle(lineWidth: lineWidth, lineCap: .butt))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: size, height: size)
        .animation(.easeOut(duration: 0.6), value: percent ?? -1)
    }
}

enum Format {
    /// "2h 04m" — the design always shows both units.
    static func countdown(to date: Date?, from now: Date = Date()) -> String {
        guard let date else { return "--" }
        let minutes = max(0, Int(date.timeIntervalSince(now) / 60))
        return "\(minutes / 60)h \(String(format: "%02d", minutes % 60))m"
    }

    static func percent(_ value: Double?) -> String {
        value.map { "\(Int($0.rounded()))%" } ?? "--"
    }

    /// Shown instead of a percentage until a ceiling has been observed.
    static func tokens(_ count: Int) -> String {
        switch count {
        case 1_000_000...: String(format: "%.2fM", Double(count) / 1_000_000)
        case 1_000...: String(format: "%.0fK", Double(count) / 1_000)
        default: "\(count)"
        }
    }
}
