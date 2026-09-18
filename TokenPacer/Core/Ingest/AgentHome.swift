import Foundation

/// Where each agent keeps its own files.
///
/// `~/.claude`, `~/.codex` and `~/.copilot` are defaults, not addresses: every
/// one of the three reads an environment variable that moves it, and people do
/// move them — onto another volume, into a synced folder, or per-account on a
/// shared machine. Hard-coding the default is how a tracker reads nothing at all
/// and says the CLI is idle.
///
/// Read fresh each time rather than resolved once at launch. The app outlives
/// any single run of an agent, and the variable it is launched with is the one
/// that counts; caching it would pin the first answer for the process's life.
enum AgentHome {
    /// `CLAUDE_CONFIG_DIR`, which Claude Code calls "the configuration home".
    static var claude: URL { resolve("CLAUDE_CONFIG_DIR", default: ".claude") }
    /// `CODEX_HOME`, the root Codex layers its own config and sessions under.
    static var codex: URL { resolve("CODEX_HOME", default: ".codex") }
    /// `COPILOT_HOME`, "the directory where configuration and state files are
    /// stored; defaults to `$HOME/.copilot`".
    static var copilot: URL { resolve("COPILOT_HOME", default: ".copilot") }

    /// Claude's answers to the trust dialog live in `.claude.json`, which sits
    /// *beside* `~/.claude` in a default install and moves inside the
    /// configuration home when one is set. Both are offered, in that order, so
    /// neither layout has to be guessed at.
    static var claudeConfigFiles: [URL] {
        [claude.appending(path: ".claude.json"),
         FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude.json")]
    }

    /// An override is honoured only when it is absolute — the CLIs themselves
    /// refuse a relative one, and a directory resolved against this app's
    /// working directory would be a different place than the agent's.
    private static func resolve(_ variable: String, default name: String) -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        guard let value = ProcessInfo.processInfo.environment[variable]?
            .trimmingCharacters(in: .whitespaces), !value.isEmpty
        else { return home.appending(path: name) }

        let expanded = value.hasPrefix("~")
            ? home.appending(path: String(value.dropFirst()).trimmingCharacters(in: ["/"])).path
            : value
        return expanded.hasPrefix("/") ? URL(filePath: expanded) : home.appending(path: name)
    }
}
