import Foundation

enum SourceID: String, CaseIterable, Sendable, Codable {
    case claude, codex

    var displayName: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        }
    }
}
