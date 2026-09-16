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
