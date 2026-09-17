import Darwin
import Foundation

/// Drives the `claude` CLI through a pseudo-terminal to read its `/usage` panel.
///
/// Lives outside `Core/` for the same reason the Keychain reader did: this one
/// spawns processes and talks to a tty, neither of which belongs in an engine
/// that has to stay testable. `ClaudeUsagePanel` gets the text; everything about
/// how it was obtained stops here.
///
/// The CLI only renders the panel when it believes it is talking to a terminal,
/// so a pipe will not do — hence the pty.
enum ClaudeCLI {
    /// Where the installers put it. `BURNTRACKER_CLAUDE_BIN` overrides, because a
    /// GUI app inherits `PATH=/usr/bin:/bin:/usr/sbin:/sbin` from launchd and will
    /// not find any of these by name.
    static var searchPaths: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            ProcessInfo.processInfo.environment["BURNTRACKER_CLAUDE_BIN"],
            "\(home)/.local/bin/claude",
            "\(home)/.claude/local/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            "\(home)/.bun/bin/claude",
            "\(home)/.volta/bin/claude",
        ].compactMap { $0 }
    }

    static func locate() -> String? {
        searchPaths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// The CLI refuses to start in a directory the user has not trusted — it draws
    /// a blocking "is this a project you trust?" prompt instead of the panel — so
    /// the working directory has to be one they already answered for.
    static func trustedDirectory() -> String? {
        struct Config: Decodable {
            struct Project: Decodable { let hasTrustDialogAccepted: Bool? }
            let projects: [String: Project]?
        }
        let url = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude.json")
        guard let data = try? Data(contentsOf: url),
              let config = try? JSONDecoder().decode(Config.self, from: data)
        else { return nil }

        var isDirectory: ObjCBool = false
        return config.projects?
            .filter { $0.value.hasTrustDialogAccepted == true }
            .keys.sorted()
            .first {
                FileManager.default.fileExists(atPath: $0, isDirectory: &isDirectory)
                    && isDirectory.boolValue
            }
    }

    /// One `/usage` run. Blocking — call it off the main thread.
    ///
    /// - Parameters:
    ///   - budget: hard ceiling on the whole run, including boot.
    ///   - settle: how long the screen must stop changing before the reading is
    ///     taken as final. The panel paints a cached figure first and repaints
    ///     when the refresh lands, and nothing in the output says which is which,
    ///     so waiting for quiet is the only way to end up with the later one.
    static func readUsagePanel(budget: TimeInterval = 30, settle: TimeInterval = 1.5) throws -> String {
        guard let binary = locate() else { throw PanelError.cliNotFound }
        guard let directory = trustedDirectory() else { throw PanelError.noTrustedDirectory }

        var size = winsize(ws_row: 60, ws_col: 120, ws_xpixel: 0, ws_ypixel: 0)
        var master: Int32 = -1
        var slave: Int32 = -1
        guard openpty(&master, &slave, nil, nil, &size) == 0 else {
            throw PanelError.spawnFailed(code: errno)
        }
        guard let terminal = ttyname(slave).map({ String(cString: $0) }) else {
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

        var arguments = [binary].map { strdup($0) } + [nil]
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

        return try converse(with: master, budget: budget, settle: settle)
    }

    /// Wait for the CLI to finish booting, ask for the panel, then read until the
    /// screen goes quiet.
    ///
    /// Readiness is quiet, not a banner: the prompt's wording has changed between
    /// releases and would be one more thing to chase. A slow boot can still go
    /// quiet for long enough to look ready, so the ask is repeated once if no
    /// panel follows it.
    ///
    /// Whatever was drawn comes back even when no panel did. The text is the only
    /// evidence of *why* — a login prompt reads nothing like a layout change — and
    /// `ClaudeUsagePanel` is where that is decided. Throwing here would collapse
    /// both into "the CLI did not answer in time".
    private static func converse(with master: Int32, budget: TimeInterval, settle: TimeInterval) throws -> String {
        let deadline = Date().addingTimeInterval(budget)
        var output = Data()
        var lastByteAt = Date()
        var askedAt: Date?
        var asksLeft = 2
        var sawPanel = false
        var buffer = [UInt8](repeating: 0, count: 8192)

        func ask() throws {
            guard write(master, "/usage\r", 7) == 7 else {
                throw PanelError.spawnFailed(code: errno)
            }
            askedAt = Date()
            lastByteAt = Date()
            asksLeft -= 1
        }

        while Date() < deadline {
            var descriptor = pollfd(fd: master, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, 200)

            if ready > 0 {
                let count = read(master, &buffer, buffer.count)
                if count > 0 {
                    output.append(contentsOf: buffer[0..<count])
                    lastByteAt = Date()
                    if askedAt != nil, !sawPanel {
                        sawPanel = String(decoding: output, as: UTF8.self)
                            .range(of: "Resets") != nil
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

            let quiet = Date().timeIntervalSince(lastByteAt)
            if askedAt == nil {
                // Boot is done when it stops drawing. Only then does the prompt
                // exist to type into.
                if quiet >= 0.8, !output.isEmpty { try ask() }
            } else if sawPanel {
                if quiet >= settle { return String(decoding: output, as: UTF8.self) }
            } else if asksLeft > 0, Date().timeIntervalSince(askedAt!) >= 4 {
                try ask()                       // the boot pause fooled us
            }
        }

        // Nothing at all means the CLI never spoke. Anything else is evidence,
        // even if it is a login prompt or a panel this build cannot read.
        guard !output.isEmpty else { throw PanelError.timedOut }
        return String(decoding: output, as: UTF8.self)
    }

    /// `TERM` has to be set explicitly — launchd does not provide one, and without
    /// it the CLI renders nothing worth reading. The `CLAUDE_CODE_*` markers are
    /// stripped so a session started from inside Claude Code behaves like any other.
    private static func childEnvironment(binary: String) -> [String] {
        var environment = ProcessInfo.processInfo.environment
            .filter { !$0.key.hasPrefix("CLAUDE_CODE_") }

        environment["TERM"] = "xterm-256color"
        environment["CI"] = nil
        let directory = (binary as NSString).deletingLastPathComponent
        environment["PATH"] = [directory, environment["PATH"] ?? "/usr/bin:/bin"]
            .joined(separator: ":")

        return environment.map { "\($0.key)=\($0.value)" }
    }

    /// The reader `ClaudeUsagePanel` takes, moved off the main actor.
    static var reader: ClaudeUsagePanel.Reader {
        { @Sendable in
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    continuation.resume(with: Result { try readUsagePanel() })
                }
            }
        }
    }
}
