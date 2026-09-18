import Foundation

enum SourceID: String, CaseIterable, Sendable, Codable {
    case claude, codex, copilot

    var displayName: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .copilot: "Copilot"
        }
    }

    /// What fits beside a bar at menu-bar size. "Claude Code" does not.
    var wordmark: String {
        switch self {
        case .claude: "CLAUDE"
        case .codex: "CODEX"
        case .copilot: "COPILOT"
        }
    }
}
