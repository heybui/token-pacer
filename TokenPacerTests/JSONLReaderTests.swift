import Foundation
import Testing
@testable import TokenPacer

private func tempDir() -> URL {
    let url = FileManager.default.temporaryDirectory
        .appending(path: "tokenpacer-tests-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func write(_ text: String, to url: URL) {
    try! Data(text.utf8).write(to: url)
}

private func append(_ text: String, to url: URL) {
    let handle = try! FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try! handle.seekToEnd()
    try! handle.write(contentsOf: Data(text.utf8))
}

@Test func readsEachLineExactlyOnce() throws {
    let dir = tempDir()
    let file = dir.appending(path: "log.jsonl")
    write("{\"a\":1}\n{\"a\":2}\n", to: file)

    var reader = JSONLReader()
    #expect(try reader.newLines(in: file).count == 2)
    // Nothing appended: a second poll must not replay what it already read.
    #expect(try reader.newLines(in: file).isEmpty)

    append("{\"a\":3}\n", to: file)
    #expect(try reader.newLines(in: file).count == 1)
}

/// A log being written to can end mid-record. Handing that back would feed
/// JSONDecoder a truncated object every poll.
@Test func holdsBackAPartialTrailingLine() throws {
    let dir = tempDir()
    let file = dir.appending(path: "log.jsonl")
    write("{\"a\":1}\n{\"partial\"", to: file)

    var reader = JSONLReader()
    let first = try reader.newLines(in: file)
    #expect(first.count == 1)
    #expect(String(data: first[0], encoding: .utf8) == "{\"a\":1}")

    // Once the record is completed, it comes back whole rather than in halves.
    append(":true}\n", to: file)
    let second = try reader.newLines(in: file)
    #expect(second.count == 1)
    #expect(String(data: second[0], encoding: .utf8) == "{\"partial\":true}")
}

@Test func aFileWithNoCompleteLineYieldsNothing() throws {
    let dir = tempDir()
    let file = dir.appending(path: "log.jsonl")
    write("{\"never-finished\"", to: file)

    var reader = JSONLReader()
    #expect(try reader.newLines(in: file).isEmpty)
    // The cursor must not advance past bytes it never handed back.
    append(":1}\n", to: file)
    #expect(try reader.newLines(in: file).count == 1)
}

@Test func truncationRewindsTheCursor() throws {
    let dir = tempDir()
    let file = dir.appending(path: "log.jsonl")
    write("{\"a\":1}\n{\"a\":2}\n{\"a\":3}\n", to: file)

    var reader = JSONLReader()
    #expect(try reader.newLines(in: file).count == 3)

    write("{\"b\":1}\n", to: file)          // shorter than the old offset
    #expect(try reader.newLines(in: file).count == 1)
}

@Test func rotationRewindsTheCursor() throws {
    let dir = tempDir()
    let file = dir.appending(path: "log.jsonl")
    write("{\"a\":1}\n{\"a\":2}\n", to: file)

    var reader = JSONLReader()
    #expect(try reader.newLines(in: file).count == 2)

    // Same path, new inode, and long enough that a stale offset would hide lines.
    try FileManager.default.removeItem(at: file)
    write("{\"c\":1}\n{\"c\":2}\n{\"c\":3}\n", to: file)
    #expect(try reader.newLines(in: file).count == 3)
}

@Test func discoveryFindsNestedLogsAndIgnoresOtherFiles() throws {
    let dir = tempDir()
    let nested = dir.appending(path: "2026/09/16")
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    write("{}\n", to: nested.appending(path: "rollout.jsonl"))
    write("not a log", to: dir.appending(path: "notes.txt"))

    let found = JSONLReader.logFiles(under: dir)
    #expect(found.count == 1)
    #expect(found[0].lastPathComponent == "rollout.jsonl")
}

/// Cold start opens every file it is handed, so skipping logs older than the
/// retention window is what keeps a machine with years of history usable.
@Test func discoverySkipsLogsOlderThanTheCutoff() throws {
    let dir = tempDir()
    let old = dir.appending(path: "old.jsonl")
    let fresh = dir.appending(path: "fresh.jsonl")
    write("{}\n", to: old)
    write("{}\n", to: fresh)

    let longAgo = Date().addingTimeInterval(-90 * 24 * 3600)
    try FileManager.default.setAttributes([.modificationDate: longAgo], ofItemAtPath: old.path)

    let cutoff = Date().addingTimeInterval(-30 * 24 * 3600)
    let found = JSONLReader.logFiles(under: dir, modifiedAfter: cutoff)
    #expect(found.count == 1)
    #expect(found[0].lastPathComponent == "fresh.jsonl")
}

@Test func missingFileThrowsRatherThanReportingEmpty() {
    var reader = JSONLReader()
    let missing = tempDir().appending(path: "nope.jsonl")
    #expect(throws: (any Error).self) { try reader.newLines(in: missing) }
}
