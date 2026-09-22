import Darwin
import Foundation

/// Drives a coding CLI through a pseudo-terminal to read its own usage screen.
///
/// Claude Code renders one on `/usage`, and only when it believes it is talking
/// to a terminal, so a pipe will not do. Everything it needs beyond that is a
/// `Spec`. Codex and Copilot are read through `CodexAppServer` and
/// `CopilotAppServer` instead — both answer JSON-RPC, and a CLI that can answer
/// a question does not need its screen read. Claude Code is the last one that
/// cannot.
///
/// Lives outside `Core/` for the same reason the Keychain reader did: this one
/// spawns processes and talks to a tty, neither of which belongs in an engine
/// that has to stay testable. The panels get the text; everything about how it
/// was obtained stops here.
enum TerminalCLI {
    /// One CLI's way in.
    struct Spec: Sendable {
        /// What the user calls it, for the one place a failure is shown.
        var name: String
        /// Where the installers put it, most specific first. A GUI app inherits
        /// `PATH=/usr/bin:/bin:/usr/sbin:/sbin` from launchd and will not find
        /// any of them by name.
        var searchPaths: [String]
        /// Typed at the prompt, without the newline — the driver sends that.
        var command: String
        /// Arguments the CLI is started with; nothing here ever sends a prompt,
        /// so anything a turn would need can be left off.
        var arguments: [String] = []
        /// Hard ceiling on a run, boot included.
        var budget: TimeInterval = 30
        /// Text that only appears once the panel has been drawn. Searched for
        /// in what arrives *after* the command was typed: a CLI's boot status
        /// line can carry some of the same words.
        var marker: String
        /// Where to run it. For Claude this has to be a directory the user
        /// already answered the trust dialog for — it draws that prompt where
        /// the panel should be.
        var workingDirectory: @Sendable () -> String?
    }

    fileprivate static var home: String {
        FileManager.default.homeDirectoryForCurrentUser.path
    }

    /// Where a user-installed CLI ends up, most preferred first.
    fileprivate static var binDirectories: [String] {
        [
            "\(home)/.local/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "\(home)/.bun/bin",
            "\(home)/.volta/bin",
        ]
    }

    static func paths(binary: String, override: String, extra: [String]) -> [String] {
        [ProcessInfo.processInfo.environment[override]].compactMap { $0 }
            + extra
            + binDirectories.map { "\($0)/\(binary)" }
    }

    /// The `PATH` a spawned CLI gets: its own directory, then everywhere else a
    /// CLI is installed, then whatever we inherited.
    ///
    /// Its own directory is not enough. Copilot resolves the account's token by
    /// running `gh`, and a Finder-launched app inherits
    /// `PATH=/usr/bin:/bin:/usr/sbin:/sbin` from launchd — no Homebrew, no
    /// `~/.local/bin`. With `gh` out of reach `account.getQuota` answers "Not
    /// authenticated", which the panel could only report as an unreadable one.
    /// The same read from a terminal inherits the user's own `PATH` and works,
    /// which is why this outlived several rounds of looking for it.
    static func searchPath(for binary: String, inheriting inherited: String?) -> String {
        ([(binary as NSString).deletingLastPathComponent]
            + binDirectories
            + [inherited ?? "/usr/bin:/bin"]).joined(separator: ":")
    }

    static func locate(_ spec: Spec) -> String? {
        spec.searchPaths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Claude Code keeps its answers to the trust dialog in `~/.claude.json`.
    static func claudeTrustedDirectory() -> String? {
        struct Config: Decodable {
            struct Project: Decodable { let hasTrustDialogAccepted: Bool? }
            let projects: [String: Project]?
        }
        // The first file that *answers*, not the first that parses. A default
        // install has a small `.claude.json` inside the configuration home as
        // well as the real one beside it, and that one decodes perfectly into a
        // `Config` with no projects in it — which read as "nothing is trusted"
        // and stopped the reading for a whole provider. Caught by `--probe`.
        for url in AgentHome.claudeConfigFiles {
            guard let data = try? Data(contentsOf: url),
                  let config = try? JSONDecoder().decode(Config.self, from: data),
                  let directory = firstExisting(config.projects?
                      .filter({ $0.value.hasTrustDialogAccepted == true })
                      .keys.sorted() ?? [])
            else { continue }
            return directory
        }
        return nil
    }

    /// Sorted, so the choice is the same from one run to the next, and checked,
    /// because a trusted project that has since been deleted is not a directory
    /// anything can start in.
    private static func firstExisting(_ paths: [String]) -> String? {
        var isDirectory: ObjCBool = false
        return paths.first {
            FileManager.default.fileExists(atPath: $0, isDirectory: &isDirectory)
                && isDirectory.boolValue
        }
    }


    /// One panel run. Blocking — call it off the main thread.
    ///
    /// - Parameters:
    ///   - budget: hard ceiling on the whole run, including boot.
    ///   - settle: how long the screen must stop changing before the reading is
    ///     taken as final. The panel paints a cached figure first and repaints
    ///     when the refresh lands, and nothing in the output says which is which,
    ///     so waiting for quiet is the only way to end up with the later one.
    static func readUsagePanel(_ spec: Spec, settle: TimeInterval = 1.5) throws -> String {
        guard let binary = locate(spec) else { throw PanelError.cliNotFound }
        guard let directory = spec.workingDirectory() else { throw PanelError.noTrustedDirectory }
        let budget = spec.budget

        var size = winsize(ws_row: 60, ws_col: 120, ws_xpixel: 0, ws_ypixel: 0)
        var master: Int32 = -1
        var slave: Int32 = -1
        guard openpty(&master, &slave, nil, nil, &size) == 0 else {
            throw PanelError.spawnFailed(code: errno)
        }
        // `ttyname` answers out of one static buffer for the whole process, so
        // three providers read at once — which is what "Check again" asks for —
        // and two children can be handed the same pty name. Both CLIs then draw
        // into one terminal and neither render parses, which reads back as
        // "could not read the usage panel". The _r form writes into our own.
        var name = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard ttyname_r(slave, &name, name.count) == 0,
              let terminal = String(validatingCString: name)
        else {
            close(master)
            close(slave)
            throw PanelError.spawnFailed(code: errno)
        }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawn_file_actions_addchdir_np(&actions, directory)
        // The child *opens* the terminal rather than inheriting it. A session
        // leader with no controlling terminal acquires one by opening a tty, and
        // that is what makes closing the master deliver SIGHUP — inheriting the
        // fd through dup2 acquires nothing, and the CLI then outlives a crash of
        // this app as an orphan of init, MCP servers and all. Verified both ways.
        posix_spawn_file_actions_addopen(&actions, 0, terminal, O_RDWR, 0)
        for target in Int32(1)...2 { posix_spawn_file_actions_adddup2(&actions, 0, target) }

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        // Its own session: required for the acquisition above, and it means
        // killing the group takes the whole CLI — and any MCP server it started.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID))

        defer {
            posix_spawn_file_actions_destroy(&actions)
            posix_spawnattr_destroy(&attributes)
        }

        var arguments = ([binary] + spec.arguments).map { strdup($0) } + [nil]
        var environment = childEnvironment(binary: binary).map { strdup($0) } + [nil]
        defer {
            for pointer in arguments + environment { free(pointer) }
        }

        var pid: pid_t = 0
        let status = posix_spawn(&pid, binary, &actions, &attributes, &arguments, &environment)
        close(slave)
        guard status == 0 else {
            close(master)
            throw PanelError.spawnFailed(code: status)
        }

        defer {
            kill(-pid, SIGKILL)
            var reaped: Int32 = 0
            waitpid(pid, &reaped, 0)
            close(master)
        }

        let text = try converse(with: master, spec: spec, budget: budget, settle: settle)
        dump(text, spec: spec)
        return text
    }

    /// `TOKENPACER_PANEL_DUMP=<dir>` writes every run's raw render there. A panel
    /// that fails to parse only ever fails somewhere the debugger is not, and the
    /// render is the whole evidence.
    private static func dump(_ text: String, spec: Spec) {
        guard let directory = ProcessInfo.processInfo.environment["TOKENPACER_PANEL_DUMP"] else { return }
        let url = URL(filePath: directory)
            .appending(path: "\(spec.name.replacing(" ", with: "-"))-\(Int(Date.now.timeIntervalSince1970)).raw")
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Wait for the CLI to finish booting, ask for the panel, then read until the
    /// screen goes quiet.
    ///
    /// Readiness is quiet, not a banner: the prompt's wording has changed between
    /// releases and would be one more thing to chase. A slow boot can still go
    /// quiet for long enough to look ready, so the ask is repeated once if no
    /// panel follows it.
    ///
    /// The command and the newline are two writes with a pause between them: a
    /// completion popup drawn over the composer swallows a newline that arrives
    /// in the same read, and the command is then left sitting there until the
    /// budget runs out.
    ///
    /// Whatever was drawn comes back even when no panel did. The text is the only
    /// evidence of *why* — a login prompt reads nothing like a layout change —
    /// and the panels are where that is decided. Throwing here would collapse
    /// both into "the CLI did not answer in time".
    private static func converse(
        with master: Int32, spec: Spec, budget: TimeInterval, settle: TimeInterval
    ) throws -> String {
        let deadline = Date.now.addingTimeInterval(budget)
        var output = Data()
        var lastByteAt = Date.now
        var askedAt: Date?
        /// Where the ask starts in `output`. Both CLIs put a summary of the same
        /// figures in the status line at boot, so the marker is only meaningful
        /// in what was drawn after the command was typed.
        var askedAtOffset = 0
        var submitted = false
        // Asking twice is for a boot pause that fooled the quiet heuristic.
        var asksLeft = 2
        var sawPanel = false
        var buffer = [UInt8](repeating: 0, count: 8192)

        func write(_ text: String) throws {
            let bytes = Array(text.utf8)
            guard Darwin.write(master, bytes, bytes.count) == bytes.count else {
                throw PanelError.spawnFailed(code: errno)
            }
            lastByteAt = Date.now
        }

        func ask() throws {
            askedAtOffset = output.count
            try write(spec.command)
            askedAt = Date.now
            submitted = false
            asksLeft -= 1
        }

        while Date.now < deadline {
            var descriptor = pollfd(fd: master, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, 200)

            if ready > 0 {
                let count = read(master, &buffer, buffer.count)
                if count > 0 {
                    output.append(contentsOf: buffer[0..<count])
                    lastByteAt = Date.now
                    if submitted, !sawPanel {
                        sawPanel = String(decoding: output[askedAtOffset...], as: UTF8.self)
                            .range(of: spec.marker) != nil
                    }
                } else if count == 0 {
                    break                       // the CLI exited on its own
                } else if errno != EINTR, errno != EAGAIN {
                    // POLLHUP or POLLERR with a read error: poll returns ready
                    // immediately from here on, so continuing would spin at full
                    // tilt for the rest of the budget rather than wait.
                    break
                }
            }

            let quiet = Date.now.timeIntervalSince(lastByteAt)
            if askedAt == nil {
                // Boot is done when it stops drawing. Only then does a prompt
                // exist to type into.
                if quiet >= 0.8, !output.isEmpty { try ask() }
            } else if !submitted {
                // The composer has finished redrawing around what was typed.
                if quiet >= 0.4 {
                    try write("\r")
                    submitted = true
                }
            } else if sawPanel {
                if quiet >= settle { return String(decoding: output, as: UTF8.self) }
            } else if asksLeft > 0, let askedAt, Date.now.timeIntervalSince(askedAt) >= 4 {
                try ask()                       // the boot pause fooled us
            }
        }

        // Nothing at all means the CLI never spoke. Anything else is evidence,
        // even if it is a login prompt or a panel this build cannot read.
        guard !output.isEmpty else { throw PanelError.timedOut }
        return String(decoding: output, as: UTF8.self)
    }

    /// `TERM` has to be set explicitly — launchd does not provide one, and without
    /// it the CLI renders nothing worth reading. The `CLAUDE_CODE_*` and `CODEX_*`
    /// markers are stripped so a run started from inside either agent behaves like
    /// any other session.
    private static func childEnvironment(binary: String) -> [String] {
        var environment = ProcessInfo.processInfo.environment
            .filter { !$0.key.hasPrefix("CLAUDE_CODE_") && !$0.key.hasPrefix("CODEX_") }

        environment["TERM"] = "xterm-256color"
        environment["CI"] = nil
        environment["PATH"] = searchPath(for: binary, inheriting: environment["PATH"])

        return environment.map { "\($0.key)=\($0.value)" }
    }

    /// The reader a panel takes, moved off the main actor.
    ///
    /// The second `DispatchQueue` in the app, and the one the rule in CLAUDE.md
    /// does not describe: it wraps no C callback. It is here because
    /// `readUsagePanel` **blocks** — `poll(2)` and `read(2)` in a loop, for up to
    /// the spec's whole budget. Swift's cooperative pool has one thread per core,
    /// so parking one there for half a minute (which `Task.detached` would also
    /// do) starves everything else; a blocking syscall loop wants a thread of its
    /// own.
    static func reader(_ spec: Spec) -> PanelReader {
        { @Sendable in
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    continuation.resume(with: Result { try readUsagePanel(spec) })
                }
            }
        }
    }
}

extension SourceID {
    /// Whether this provider's CLI is on the machine at all.
    ///
    /// The same search the reader does — the paths a panel would spawn from —
    /// without spawning anything: a few `isExecutableFile` calls. So "installed"
    /// here and `cliNotFound` there can never disagree, including about a
    /// `TOKENPACER_*_BIN` override pointing somewhere unusual.
    var cliIsInstalled: Bool {
        switch self {
        case .claude: TerminalCLI.locate(.claude) != nil
        case .codex: CodexAppServer.locate() != nil
        case .copilot: CopilotAppServer.locate() != nil
        }
    }
}

extension TerminalCLI.Spec {
    static var claude: Self {
        Self(
            name: "Claude Code",
            searchPaths: TerminalCLI.paths(binary: "claude", override: "TOKENPACER_CLAUDE_BIN", extra: [
                AgentHome.claude.appending(path: "local/claude").path,
            ]),
            command: "/usage",
            marker: "Resets",
            workingDirectory: TerminalCLI.claudeTrustedDirectory
        )
    }

}
