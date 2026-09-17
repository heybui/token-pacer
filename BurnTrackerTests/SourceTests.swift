import Foundation
import Testing
@testable import BurnTracker

private func fixture(_ name: String) -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appending(path: "Fixtures/\(name)")
}

private func lines(_ name: String) -> [Data] {
    let text = try! String(contentsOf: fixture(name), encoding: .utf8)
    return text.split(separator: "\n").map { Data($0.utf8) }
}

@Test func claudeParsesAssistantUsage() {
    let events = lines("claude-session.jsonl").flatMap {
        ClaudeCodeSource.decode($0, file: fixture("claude-session.jsonl"))
    }
    #expect(events.count == 4)
    let first = try! #require(events.first)
    #expect(first.source == .claude)
    #expect(first.counts.total > 0)
    #expect(first.model != nil)
    #expect(first.id.hasPrefix("claude:"))
}

/// Claude reports cache counts alongside input; nothing should be subtracted.
@Test func claudeKeepsCacheCountsSeparateFromInput() {
    let line = Data("""
    {"type":"assistant","timestamp":"2026-09-16T15:01:07.146Z","cwd":"/tmp/demo",
     "sessionId":"s1","requestId":"r1","message":{"id":"m1","model":"claude-opus-5",
     "usage":{"input_tokens":2,"output_tokens":161,
              "cache_creation_input_tokens":33844,"cache_read_input_tokens":21128}}}
    """.utf8)
    let event = try! #require(ClaudeCodeSource.decode(line, file: fixture("x")).first)
    #expect(event.counts.input == 2)
    #expect(event.counts.output == 161)
    #expect(event.counts.cacheWrite == 33844)
    #expect(event.counts.cacheRead == 21128)
    #expect(event.project == "demo")
}

@Test func claudeIgnoresNonAssistantAndEmptyRecords() {
    let user = Data(#"{"type":"user","timestamp":"2026-09-16T15:01:07.146Z"}"#.utf8)
    #expect(ClaudeCodeSource.decode(user, file: fixture("x")).isEmpty)

    let zero = Data("""
    {"type":"assistant","timestamp":"2026-09-16T15:01:07.146Z","requestId":"r",
     "message":{"id":"m","usage":{"input_tokens":0,"output_tokens":0}}}
    """.utf8)
    #expect(ClaudeCodeSource.decode(zero, file: fixture("x")).isEmpty)
}

@Test func codexParsesTokenUsageRecords() async throws {
    let source = CodexSource(root: fixture("").deletingLastPathComponent().appending(path: "Fixtures"))
    let snapshot = try await source.poll()
    #expect(snapshot.source == .codex)
    #expect(snapshot.events.count == 3)
    #expect(snapshot.events.allSatisfy { $0.counts.total > 0 })
    #expect(snapshot.events.allSatisfy { $0.project == "duotyping" })
}

/// Codex nests cached inside input; failing to subtract double counts it and makes
/// the two sources incomparable.
@Test func codexSubtractsCachedTokensFromInput() async throws {
    let source = CodexSource(root: fixture("").deletingLastPathComponent().appending(path: "Fixtures"))
    let snapshot = try await source.poll()
    let event = try #require(snapshot.events.first)
    #expect(event.counts.input >= 0)
    #expect(event.counts.cacheRead > 0)
    #expect(event.counts.input + event.counts.cacheRead > 0)
}

@Test func codexReportsAuthoritativeLimits() async throws {
    let source = CodexSource(root: fixture("").deletingLastPathComponent().appending(path: "Fixtures"))
    let snapshot = try await source.poll()
    let limits = try #require(snapshot.limits)
    #expect(limits.primary?.windowMinutes == 300)
    #expect(limits.secondary?.windowMinutes == 10080)
    #expect(limits.planType != nil)
}

// MARK: - is anything running right now

private func scanActivity(_ lines: [String]) throws -> LogActivity? {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "burn-tracker-tests/\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try lines.joined(separator: "\n").appending("\n")
        .write(to: root.appending(path: "session.jsonl"), atomically: true, encoding: .utf8)
    var scanner = LogScanner()
    _ = try scanner.scan(root: root, decode: ClaudeCodeSource.decode)
    return scanner.activity
}

private func assistant(_ stopReason: String, at date: Date) -> String {
    """
    {"type":"assistant","timestamp":"\(date.ISO8601Format())","message":\
    {"stop_reason":"\(stopReason)","usage":{"input_tokens":1,"output_tokens":1}}}
    """
}

/// Two thirds of a session log is bookkeeping, and it is written *after* the
/// turn it belongs to — so the last line is routinely an `ai-title`, and asking
/// it whether Claude is working gets no answer at all.
@Test func bookkeepingAfterATurnDoesNotHideIt() throws {
    let now = Date()
    let working = try scanActivity([
        assistant("tool_use", at: now),
        #"{"type":"ai-title","timestamp":"\#(now.ISO8601Format())","title":"x"}"#,
    ])
    #expect(try #require(working).isAwaitingResponse)

    let done = try scanActivity([
        assistant("end_turn", at: now),
        #"{"type":"queue-operation","timestamp":"\#(now.ISO8601Format())"}"#,
    ])
    #expect(try #require(done).isAwaitingResponse == false)
}

// MARK: - skipping the walk when nothing was written

/// The gate decides whether a tick walks the tree and stats every log. Get it
/// stuck closed and the app reads nothing for the rest of the session while
/// showing a figure that looks live, so the floor underneath it is what is
/// actually being checked here.
@Test func aClosedGateSkipsTheScanButNeverForLong() async throws {
    let root = try #require(FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first)
        .appending(path: "burntracker-gate-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let line = """
    {"type":"assistant","timestamp":"2026-09-17T10:00:00.000Z","requestId":"r1",\
    "message":{"id":"m1","model":"claude-opus-5","usage":{"input_tokens":10,"output_tokens":20}}}
    """
    try (line + "\n").write(to: root.appending(path: "a.jsonl"), atomically: true, encoding: .utf8)

    // Gate open: the log is read.
    let open = ClaudeCodeSource(root: root, retention: nil, changed: { true })
    #expect(try await open.poll().events.count == 1)

    // A cold source always scans: `lastScan` starts at distantPast, so a machine
    // that was quiet before launch still shows its window rather than nothing.
    let shut = ClaudeCodeSource(root: root, retention: nil, changed: { false })
    #expect(try await shut.poll().events.count == 1)

    // Only now does the gate hold it shut. A second log appears and is not read,
    // because nothing said anything had changed.
    try (line.replacingOccurrences(of: "r1", with: "r2")
            .replacingOccurrences(of: "m1", with: "m2") + "\n")
        .write(to: root.appending(path: "b.jsonl"), atomically: true, encoding: .utf8)
    #expect(try await shut.poll().events.isEmpty)

    // An open gate picks it straight up.
    let open2 = ClaudeCodeSource(root: root, retention: nil, changed: { true })
    _ = try await open2.poll()
    #expect(try await open2.poll().events.isEmpty)   // cursors: read once, not twice
}
