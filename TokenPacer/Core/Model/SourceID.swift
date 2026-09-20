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
    /// whether to turn it on.
    ///
    /// Deliberately vague about the shape of the limit. These lines used to name
    /// one — "5-hour and weekly" — and then an Enterprise Codex workspace turned
    /// up with a monthly credit budget and no five-hour window at all. The app
    /// reads whatever the account has; the row should promise exactly that much.
    var blurb: String {
        switch self {
        case .claude: String(localized: "Whatever your Claude plan allows, from ~/.claude.")
        case .codex: String(localized: "Your ChatGPT plan or credits, from ~/.codex.")
        case .copilot: String(localized: "Your Copilot credits, from ~/.copilot.")
        }
    }

    /// The words that open the install page. One word, not the tool's name
    /// again: the row is already titled with it, and repeating it was what put
    /// every one of these lines onto a second line.
    var installLabel: String {
        switch self {
        case .claude, .codex, .copilot: String(localized: "Install")
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
