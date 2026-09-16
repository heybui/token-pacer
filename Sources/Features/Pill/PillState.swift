import CoreGraphics

/// The eight states from the design board. One object, one shell, different sizes.
enum PillState: String, CaseIterable, Sendable {
    case dormant, ghost, collapsed, hover, warning, exhausted, paused, pinned

    /// Shell dimensions, verbatim from the design board.
    var size: CGSize {
        switch self {
        case .dormant: CGSize(width: 226, height: 3)
        case .ghost, .collapsed, .exhausted, .paused: CGSize(width: 226, height: 36)
        case .hover, .warning: CGSize(width: 404, height: 98)
        case .pinned: CGSize(width: 752, height: 540)
        }
    }

    /// Bottom corner radius; the shell only ever grows downward out of the notch.
    var cornerRadius: CGFloat {
        switch self {
        case .dormant: 6
        case .ghost, .collapsed, .exhausted, .paused: 13
        case .hover, .warning, .pinned: 26
        }
    }

    var opacity: Double { self == .ghost ? 0.45 : 1 }

    /// Largest shell plus room for the context menu below it. The panel is fixed at this
    /// size forever; only the content morphs.
    static let hostSize = CGSize(width: 792, height: 580)
}
