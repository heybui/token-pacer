import Foundation
import Testing
@testable import TokenPacer

/// The gate is only as good as the stream behind it. Everything else about the
/// watcher is tested with an injected closure, which proves the plumbing and
/// nothing about FSEvents — and a stream that starts but never delivers would
/// look exactly like a quiet machine, with the figure frozen and no error.
@MainActor
@Test func theWatcherSeesAWriteUnderItsRoot() async throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "tokenpacer-watch-\(UUID().uuidString)")
    // Nested, because the logs are: FSEvents watches the tree, and a directory's
    // own mtime would never see this.
    let nested = root.appending(path: "a/b")
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let watcher = try #require(LogWatcher(root: root), "stream failed to start")
    // Starts dirty so a cold launch always scans; clear it to watch for a change.
    _ = watcher.consume()
    #expect(watcher.consume() == false)

    let log = nested.appending(path: "session.jsonl")
    try "{}\n".write(to: log, atomically: true, encoding: .utf8)

    #expect(await changed(watcher), "a new file under the root went unnoticed")

    // ...and again for an append, which is the case that actually matters: a
    // session file already exists and Claude Code adds to it for hours.
    _ = watcher.consume()
    let handle = try FileHandle(forWritingTo: log)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data("{}\n".utf8))
    try handle.close()

    #expect(await changed(watcher), "an append to an existing log went unnoticed")
}

/// FSEvents coalesces on a latency window, so the answer arrives late by design.
private func changed(_ watcher: LogWatcher, within seconds: Double = 8) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if watcher.consume() { return true }
        try? await Task.sleep(for: .milliseconds(100))
    }
    return false
}
