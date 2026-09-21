import Foundation

/// Asks `codex app-server` what the account's limits are.
///
/// Codex ships a JSON-RPC server in the same binary as the TUI: newline-
/// delimited JSON on stdin and stdout, no terminal to fake, no trusted project
/// to start in, no composer to mistype into. Three lines go in — `initialize`,
/// the `initialized` notification, `account/rateLimits/read` — and the reply to
/// the last one comes back as the reader's text for `CodexUsagePanel` to decode.
///
/// Lives outside `Core/` for the same reason `TerminalCLI` does: it spawns a
/// process. The panel gets the JSON; everything about how it was obtained stops
/// here.
enum CodexAppServer {
    /// Where the installers put Codex, most specific first. A GUI app inherits
    /// `PATH=/usr/bin:/bin:/usr/sbin:/sbin` from launchd and finds none of them
    /// by name.
    static var searchPaths: [String] {
        TerminalCLI.paths(binary: "codex", override: "TOKENPACER_CODEX_BIN", extra: [
            AgentHome.codex.appending(path: "packages/standalone/current/bin/codex").path,
        ])
    }

    static func locate() -> String? {
        searchPaths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// The reader a panel takes.
    ///
    /// Twenty seconds: the read is one round trip to OpenAI and lands in about
    /// a second, and the rest of the budget is for a cold binary on a machine
    /// that has just woken.
    static func reader(budget: TimeInterval = 20) -> PanelReader {
        { @Sendable in try await read(budget: budget) }
    }

    /// The id carried by the answer we are waiting for.
    ///
    /// Replies come back out of order — an unauthenticated server answered the
    /// rate-limit read *before* the initialize sent ahead of it — so the id is
    /// how the right line is found, and notifications like
    /// `remoteControl/status/changed` carry none at all.
    private static let readID = 2

    private static let requests = """
    {"id":1,"method":"initialize","params":{"clientInfo":{"name":"Token Pacer","version":"1"}}}
    {"method":"initialized","params":{}}
    {"id":\(readID),"method":"account/rateLimits/read","params":{}}

    """

    static func read(budget: TimeInterval) async throws -> String {
        guard let binary = locate() else { throw PanelError.cliNotFound }

        let child = Child()
        child.process.executableURL = URL(filePath: binary)
        // Belt and braces: nothing here asks the server to run a turn, and a
        // background usage read must not be able to.
        child.process.arguments = ["-s", "read-only", "-a", "never", "app-server"]
        child.process.standardInput = child.input
        child.process.standardOutput = child.output
        child.process.standardError = FileHandle.nullDevice
        child.process.environment = environment(binary: binary)

        do { try child.process.run() } catch { throw PanelError.spawnFailed(code: errno) }
        defer { child.stop() }

        try child.input.fileHandleForWriting.write(contentsOf: Data(requests.utf8))

        return try await withThrowingTaskGroup(of: String?.self) { group in
            group.addTask { try await answer(from: child.output.fileHandleForReading) }
            group.addTask {
                // Cancelled the moment the answer lands, which is the ordinary
                // case; the sleep is the only thing here that notices.
                do { try await Task.sleep(for: .seconds(budget)) } catch { return nil }
                // Stopping the child is what unblocks the reader. A `read(2)`
                // already in flight on the pipe does not notice a cancelled
                // Task, it notices the far end closing — and this group will not
                // return until that task has unwound.
                child.stop()
                return nil
            }

            while let result = try await group.next() {
                guard let result else { continue }
                group.cancelAll()
                return result
            }
            throw PanelError.timedOut
        }
    }

    /// Reads lines until the one answering `readID` arrives.
    ///
    /// Everything before it is the initialize reply and whatever the server
    /// decides to announce. An error object comes back verbatim rather than
    /// being thrown: `codex account authentication required to read rate
    /// limits` is a sign-in prompt in JSON, and telling that apart from a
    /// layout change is the panel's job.
    private static func answer(from handle: FileHandle) async throws -> String {
        for try await line in handle.bytes.lines where !line.isEmpty {
            guard let id = try? JSONDecoder().decode(Identified.self, from: Data(line.utf8)).id,
                  id == readID
            else { continue }
            return line
        }
        throw PanelError.timedOut
    }

    private struct Identified: Decodable {
        let id: Int?
    }

    /// The child's own environment. Unlike a TUI run, `CODEX_*` is left alone:
    /// `CODEX_HOME` is which account is being asked about, and `AgentHome`
    /// already reads the logs of that same one.
    private static func environment(binary: String) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let directory = (binary as NSString).deletingLastPathComponent
        environment["PATH"] = [directory, environment["PATH"] ?? "/usr/bin:/bin"]
            .joined(separator: ":")
        return environment
    }

    /// One run's process and its two pipes, stopped exactly once.
    ///
    /// A box rather than three locals because the timeout task has to reach
    /// them, and `Process` is not `Sendable`. Nothing outside this file touches
    /// it, and the only cross-task call is `stop()`, which the lock serialises.
    private final class Child: @unchecked Sendable {
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        private let stopped = NSLock()
        private var isStopped = false

        /// Closing stdin is what ends the server: it exits on EOF, and it does
        /// that well before the round trip to OpenAI comes back — which is why
        /// the handle stays open until the answer is in hand.
        func stop() {
            stopped.lock()
            defer { stopped.unlock() }
            guard !isStopped else { return }
            isStopped = true
            try? input.fileHandleForWriting.close()
            if process.isRunning { process.terminate() }
        }
    }
}
