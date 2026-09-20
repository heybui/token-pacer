import Foundation

enum SourceID: String, CaseIterable, Sendable, Codable {
    case claude, codex, copilot

    /// A product name, so never localized — "Claude Code" is "Claude Code" in
    /// every language, and `wordmark` below is the same name cut to fit.
    var displayName: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .copilot: "Copilot"
        }
    }

    /// What this provider gives the pill, in the words of someone deciding
    /// whether to turn it on. One line each, and each one different: three rows
    /// repeating "needs the CLI" say nothing about which of the three to keep.
    var blurb: String {
        switch self {
        case .claude: String(localized: "Your 5-hour window and weekly cap, read from ~/.claude.")
        case .codex: String(localized: "The 5-hour and weekly figures Codex prints, from ~/.codex.")
        case .copilot: String(localized: "The monthly credit budget Copilot reports, from ~/.copilot.")
        }
    }

    /// The words that open the install page. Named for the tool, so three rows
    /// of links are three different offers rather than one word three times.
    var installLabel: String {
        switch self {
        case .claude: String(localized: "Get Claude Code")
        case .codex: String(localized: "Get the Codex CLI")
        case .copilot: String(localized: "Get Copilot CLI")
        }
    }

    /// Where the CLI itself comes from, on the provider's own documentation.
    ///
    /// The app reads what these tools write and can do nothing at all until one
    /// of them is installed and signed in, so the switch that tracks a provider
    /// is also the only sensible place to say where to get it.
    var docs: URL {
        switch self {
        case .claude: Self.url("https://code.claude.com/docs/en/setup")
        case .codex: Self.url("https://developers.openai.com/codex/cli")
        case .copilot: Self.url("https://docs.github.com/en/copilot/how-tos/set-up/install-copilot-cli")
        }
    }

    /// `URL(string:)` is failable and every argument here is a literal, so a nil
    /// is a typo in this file rather than a runtime condition — and the rule is
    /// no force unwrap.
    private static func url(_ text: String) -> URL {
        guard let url = URL(string: text) else {
            fatalError("SourceID.docs is not a valid URL: \(text)")
        }
        return url
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
