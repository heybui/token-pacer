import Foundation

/// Asks the Copilot CLI what the account's quota is, over the JSON-RPC face it
/// already ships for `@github/copilot-sdk`.
///
/// This replaces driving `/usage` through a pseudo-terminal, which had become
/// the least reliable thing in the app. Copilot 1.0.86 draws a folder-trust
/// dialog at boot — "Do you trust the files in this folder?" — and it lands
/// wherever it lands: before the typed `/usage`, which the dialog swallows, or
/// after it, which leaves the submit key selecting a dialog row. Either way the
/// run spent its whole 60-second budget and came back as a screen with no panel
/// on it.
///
/// `copilot --headless --stdio` has no screen at all. Two frames go in —
/// `connect`, then `account.getQuota` — and the reply to the second is the
/// reader's text for `CopilotUsagePanel` to decode. Measured at ~1.3s against
/// 1.0.86, against a 60s budget the TUI regularly used in full, and the reply
/// carries what no render did: the real `resetDate`, the overage, and whether
/// the entitlement is unlimited.
///
/// The framing is `vscode-jsonrpc`'s, not Codex's newline-delimited JSON:
/// `Content-Length: n`, a blank line, then `n` bytes of body.
///
/// ponytail: `--headless --stdio` is undocumented — absent from `--help`, and
/// removed once already in the CLI's history. It is the interface GitHub's own
/// SDK drives, so a release that moves it breaks that too, and it fails here as
/// a JSON-RPC error rather than as a misparsed picture. `--acp --stdio`, the
/// other programmatic face, speaks Agent Client Protocol and has no quota call.
enum CopilotAppServer {
    /// Where the installer puts Copilot. A GUI app inherits
    /// `PATH=/usr/bin:/bin:/usr/sbin:/sbin` from launchd and finds none of them
    /// by name.
    static var searchPaths: [String] {
        TerminalCLI.paths(binary: "copilot", override: "TOKENPACER_COPILOT_BIN", extra: [])
    }

    static func locate() -> String? {
        searchPaths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// The reader a panel takes.
    ///
    /// Twenty seconds: the quota is one round trip to GitHub and lands in about
    /// a second, and the rest of the budget is for a cold binary on a machine
    /// that has just woken — which is exactly when this used to fail.
    static func reader(budget: TimeInterval = 20) -> PanelReader {
        { @Sendable in try await read(budget: budget) }
    }

    /// The id carried by the answer we are waiting for. `connect` is sent for
    /// its version check and its reply is stepped over.
    private static let readID = 2

    /// `clientInfo` is an editor's, not a client's: the server rejects the
    /// `name`/`version` pair every other JSON-RPC handshake in this app uses.
    private static let requests = [
        """
        {"jsonrpc":"2.0","id":1,"method":"connect","params":{"clientInfo":\
        {"editorName":"Token Pacer","editorVersion":"1","extensionName":"token-pacer",\
        "extensionVersion":"1"}}}
        """,
        """
        {"jsonrpc":"2.0","id":\(readID),"method":"account.getQuota","params":{}}
        """,
    ]

    static func read(budget: TimeInterval) async throws -> String {
        guard let binary = locate() else { throw PanelError.cliNotFound }

        let child = Child()
        child.process.executableURL = URL(filePath: binary)
        // `--headless` is the whole point: no TUI, no trust dialog, no composer.
        // `--log-level none` keeps a five-minute poll from leaving a file per run
        // in `~/.copilot/logs`.
        child.process.arguments = [
            "--headless", "--stdio", "--no-auto-update", "--log-level", "none",
        ]
        child.process.standardInput = child.input
        child.process.standardOutput = child.output
        child.process.standardError = FileHandle.nullDevice
        child.process.environment = environment(binary: binary)

        do { try child.process.run() } catch { throw PanelError.spawnFailed(code: errno) }
        defer { child.stop() }

        let framed = requests
            .map { "Content-Length: \($0.utf8.count)\r\n\r\n\($0)" }
            .joined()
        try child.input.fileHandleForWriting.write(contentsOf: Data(framed.utf8))

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

    /// Reads frames until the one answering `readID` arrives.
    ///
    /// An error object comes back verbatim rather than being thrown: a server
    /// that cannot say what the quota is because nobody is signed in is a
    /// sign-in prompt in JSON, and telling that apart from a release that moved
    /// the field is the panel's job.
    private static func answer(from handle: FileHandle) async throws -> String {
        var buffer = Data()
        for try await byte in handle.bytes {
            buffer.append(byte)
            guard let frame = Self.frame(from: &buffer) else { continue }
            guard let id = try? JSONDecoder().decode(Identified.self, from: Data(frame.utf8)).id,
                  id == readID
            else { continue }
            return frame
        }
        throw PanelError.timedOut
    }

    /// One complete `Content-Length` frame, taken off the front of the buffer.
    /// Nil until the whole body has arrived.
    private static func frame(from buffer: inout Data) -> String? {
        guard let blank = buffer.firstRange(of: Data("\r\n\r\n".utf8)),
              let length = PanelText.firstCapture(
                  #"Content-Length:\s*([0-9]+)"#,
                  in: String(decoding: buffer[..<blank.lowerBound], as: UTF8.self)
              ).flatMap(Int.init),
              buffer.distance(from: blank.upperBound, to: buffer.endIndex) >= length
        else { return nil }

        let end = buffer.index(blank.upperBound, offsetBy: length)
        let body = String(decoding: buffer[blank.upperBound..<end], as: UTF8.self)
        // Re-based rather than sliced: a `Data` slice keeps the original
        // indices, and the next pass measures from `startIndex`.
        buffer = Data(buffer[end...])
        return body
    }

    private struct Identified: Decodable {
        let id: Int?
    }

    /// The child's own environment, `COPILOT_*` left alone: `COPILOT_HOME` is
    /// which account is being asked about, and `AgentHome` already reads the
    /// store of that same one.
    private static func environment(binary: String) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = TerminalCLI.searchPath(
            for: binary, inheriting: environment["PATH"]
        )
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
        /// that well before the round trip to GitHub comes back — which is why
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
