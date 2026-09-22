import Foundation
import SQLite3
import Testing
@testable import TokenPacer

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
        .appending(path: "token-pacer-tests/\(UUID().uuidString)")
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
        .appending(path: "tokenpacer-gate-\(UUID().uuidString)")
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

/// Codex marks its turns outright — `task_started` … `task_complete` — and the
/// quiet in between is the reason to. Measured on a real session: three turns in
/// five carried a silence longer than the twelve seconds the dot waits, one of
/// them 107 seconds, all of it with the model plainly working.
@Test func aCodexTurnIsInFlightThroughItsSilences() throws {
    let started = Date().addingTimeInterval(-107)
    let working = try scanActivity([
        #"{"type":"event_msg","timestamp":"\#(started.ISO8601Format())","payload":{"type":"task_started"}}"#,
        #"{"type":"response_item","timestamp":"\#(started.ISO8601Format())","payload":{"type":"reasoning"}}"#,
    ])
    #expect(try #require(working).isAwaitingResponse)

    let done = try scanActivity([
        #"{"type":"event_msg","timestamp":"\#(started.ISO8601Format())","payload":{"type":"task_started"}}"#,
        #"{"type":"event_msg","timestamp":"\#(Date().ISO8601Format())","payload":{"type":"task_complete"}}"#,
    ])
    #expect(try #require(done).isAwaitingResponse == false)
}

/// A burst of tool calls used to bury the `task_complete` behind more lines than
/// the scan looked at, which left a finished turn lit for the whole in-flight cap.
@Test func aFinishedCodexTurnIsFoundBehindABurstOfLines() throws {
    let now = Date()
    let noise = (0..<40).map { _ in
        #"{"type":"event_msg","timestamp":"\#(now.ISO8601Format())","payload":{"type":"item_completed"}}"#
    }
    let activity = try scanActivity(
        [#"{"type":"event_msg","timestamp":"\#(now.addingTimeInterval(-60).ISO8601Format())","payload":{"type":"task_started"}}"#]
            + [#"{"type":"event_msg","timestamp":"\#(now.ISO8601Format())","payload":{"type":"task_complete"}}"#]
            + noise
    )
    #expect(try #require(activity).isAwaitingResponse == false)
}

/// Writes one file per session under a root of its own, and scans them together.
private func scanSessions(_ sessions: [[String]]) throws -> LogScanner {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "token-pacer-tests/\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    for (index, lines) in sessions.enumerated() {
        try lines.joined(separator: "\n").appending("\n")
            .write(to: root.appending(path: "session-\(index).jsonl"),
                   atomically: true, encoding: .utf8)
    }
    var scanner = LogScanner()
    _ = try scanner.scan(root: root) { _, _ in [] }
    return scanner
}

private func codexLine(_ kind: String, at date: Date) -> String {
    #"{"type":"event_msg","timestamp":"\#(date.ISO8601Format())","payload":{"type":"\#(kind)"}}"#
}

/// Two sessions at once, and the one still working is not the one that wrote
/// last. Held as a single reading, the finished session's own `task_complete`
/// answered for both and put the dot out while the other was mid-turn.
@Test func aSessionStillWorkingIsNotHiddenByOneThatJustFinished() throws {
    let now = Date()
    let scanner = try scanSessions([
        [codexLine("task_started", at: now.addingTimeInterval(-90))],
        [codexLine("task_started", at: now.addingTimeInterval(-30)),
         codexLine("task_complete", at: now)],
    ])

    #expect(try #require(scanner.activity).isAwaitingResponse)
    #expect(scanner.working(at: now) == 1)
}

/// A CLI killed mid-turn leaves its last line looking like work in progress. It
/// would otherwise sit in the badge until the app was relaunched.
@Test func aTurnLeftOpenByACrashStopsBeingCounted() throws {
    let now = Date()
    let scanner = try scanSessions([
        [codexLine("task_started", at: now.addingTimeInterval(-20 * 60))],
    ])

    #expect(scanner.working(at: now) == 0)
}

/// Claude Code registers every session in a file of its own — kind, status and
/// a pid to check it is still alive. Counting its logs too would count each
/// session twice.
@Test func claudeLeavesTheCountingToItsOwnRegistry() async throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "token-pacer-tests/\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try assistant("tool_use", at: Date()).appending("\n")
        .write(to: root.appending(path: "session.jsonl"), atomically: true, encoding: .utf8)

    let snapshot = try await ClaudeCodeSource(root: root, retention: nil).poll()
    #expect(snapshot.workingSessions == 0)
}

/// The badge belongs to the provider the pill is reporting, like every other
/// figure in the row. Pinned to Codex with Codex idle, it was showing a count of
/// Claude sessions beside a Codex row — and a Claude turned off in Preferences
/// went on being counted at all.
@MainActor @Test func theBadgeCountsThePinnedProviderAndNoOther() {
    let busy = AgentSession(
        pid: 1, kind: .bg, name: "a job", directory: "/tmp",
        status: .busy, changedAt: Date()
    )
    let every = Set(SourceID.allCases)
    func working(_ source: SourceID, tracked: Set<SourceID> = every) -> Int {
        UsageStore.working(
            sessions: [busy], logs: [.codex: 2], for: source, tracked: tracked
        )
    }

    #expect(working(.claude) == 1)          // its registry, not its logs
    #expect(working(.codex) == 2)           // its logs, since it registers nothing
    #expect(working(.copilot) == 0)         // neither book has anything to say
    #expect(working(.claude, tracked: [.codex]) == 0)
}

/// Counts its polls, and takes long enough over one that a second refresh can
/// arrive while it is still inside it.
private actor SlowSource: UsageSource {
    nonisolated let id = SourceID.codex
    private(set) var polls = 0

    func restore(cursors: [String: JSONLReader.Cursor], seen: Set<String>) {}
    func cursors() -> [String: JSONLReader.Cursor] { [:] }

    func poll() throws -> SourceSnapshot {
        polls += 1
        Thread.sleep(forTimeInterval: 0.05)
        return SourceSnapshot(source: id, events: [], limits: nil)
    }
}

/// Writes push a refresh now, and they arrive in bursts. Two refreshes must not
/// run over each other, and the write that lands mid-refresh must not be
/// swallowed by the one already running — that is the write the pill is waiting
/// on, and the next tick is five seconds away.
@MainActor @Test func writesDuringARefreshCoalesceIntoExactlyOneMore() async throws {
    let source = SlowSource()
    let store = UsageStore(sources: [source], interval: 3600)

    async let first: Void = store.refreshSoon()
    try await Task.sleep(for: .milliseconds(10))
    async let second: Void = store.refreshSoon()
    async let third: Void = store.refreshSoon()
    _ = await (first, second, third)

    #expect(await source.polls == 2)
}

/// Codex states the model once per turn, on `turn_context`, and leaves it off
/// every token record that follows. Read from the record alone, the panel filed
/// a whole provider's history under "unknown".
@Test func codexTakesTheModelFromTheTurnItBelongsTo() async throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "token-pacer-tests/\(UUID().uuidString)/2026/09/21")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let stamp = Date().ISO8601Format()
    try """
    {"type":"turn_context","timestamp":"\(stamp)","payload":{"cwd":"/tmp/thing","model":"gpt-5.6-terra"}}
    {"type":"token_usage_record","timestamp":"\(stamp)","payload":{"response_id":"r1","session_id":"s1",\
    "usage":{"input_tokens":10,"output_tokens":5,"cached_input_tokens":2}}}
    {"type":"turn_context","timestamp":"\(stamp)","payload":{"cwd":"/tmp/thing","model":"gpt-5.6-sol"}}
    {"type":"token_usage_record","timestamp":"\(stamp)","payload":{"response_id":"r2","session_id":"s1",\
    "usage":{"input_tokens":10,"output_tokens":5,"cached_input_tokens":2}}}

    """.write(to: root.appending(path: "rollout-x.jsonl"), atomically: true, encoding: .utf8)

    let source = CodexSource(root: root.deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent())
    let events = try await source.poll().events
    #expect(events.count == 2)
    #expect(events.first?.model == "gpt-5.6-terra")
    // A `/model` mid-session moves the turns after it, not the ones before.
    #expect(events.last?.model == "gpt-5.6-sol")
    #expect(events.first?.project == "thing")
}

/// A schema-faithful `data.db`: what Copilot writes, in the columns it writes
/// it in.
private func copilotStore(_ rows: String) throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "token-pacer-tests/\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let store = root.appending(path: "data.db")

    var db: OpaquePointer?
    #expect(sqlite3_open(store.path, &db) == SQLITE_OK)
    let schema = """
        CREATE TABLE sessions (
            id TEXT PRIMARY KEY, model TEXT, is_running INTEGER NOT NULL DEFAULT 0,
            updated_at TEXT NOT NULL,
            total_input_tokens INTEGER NOT NULL DEFAULT 0,
            total_output_tokens INTEGER NOT NULL DEFAULT 0,
            total_cached_tokens INTEGER NOT NULL DEFAULT 0,
            total_reasoning_tokens INTEGER NOT NULL DEFAULT 0);
        CREATE TABLE projects (id TEXT PRIMARY KEY, name TEXT, github_owner TEXT, github_repo TEXT);
        CREATE TABLE workspaces (id TEXT PRIMARY KEY, session_id TEXT, project_id TEXT);
        INSERT INTO projects VALUES ('p1', 'thing', 'CoverGo', 'thing');
        INSERT INTO projects VALUES ('p2', 'loose-folder', '', '');
        \(rows)
        """
    #expect(sqlite3_exec(db, schema, nil, nil, nil) == SQLITE_OK)
    sqlite3_close(db)
    return store
}

private func copilotSession(
    _ id: String, running: Bool = false, minutesAgo: Double = 0, project: String? = nil,
    input: Int = 0, output: Int = 0, cached: Int = 0, reasoning: Int = 0
) -> String {
    let stamp = Date().addingTimeInterval(-minutesAgo * 60).ISO8601Format()
    var sql = """
        INSERT INTO sessions VALUES ('\(id)', 'gpt-6-astra', \(running ? 1 : 0), '\(stamp)',
            \(input), \(output), \(cached), \(reasoning));
        """
    if let project {
        sql += "INSERT INTO workspaces VALUES ('w-\(id)', '\(id)', '\(project)');"
    }
    return sql
}

/// Bumps a session's totals and its `updated_at`, the way Copilot does.
private func bump(
    _ store: URL, _ id: String, input: Int = 0, output: Int = 0,
    cached: Int = 0, reasoning: Int = 0
) throws {
    var db: OpaquePointer?
    #expect(sqlite3_open(store.path, &db) == SQLITE_OK)
    defer { sqlite3_close(db) }
    let sql = """
        UPDATE sessions SET total_input_tokens = \(input), total_output_tokens = \(output),
            total_cached_tokens = \(cached), total_reasoning_tokens = \(reasoning),
            updated_at = '\(Date().ISO8601Format())' WHERE id = '\(id)';
        """
    #expect(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
}

/// The dot follows `is_running`, and only while the row is still moving: the
/// flag outlives a session killed mid-turn, exactly as the `working` flag in
/// the file this replaced did.
@Test func copilotCountsOnlyTheSessionsItSaysAreRunning() async throws {
    let store = try copilotStore("""
        \(copilotSession("a", running: true, minutesAgo: 1))
        \(copilotSession("b", running: false, minutesAgo: 0))
        \(copilotSession("c", running: true, minutesAgo: 60))
        """)

    let snapshot = try await CopilotSource(store: store).poll()
    #expect(snapshot.workingSessions == 1)
    // Every session is met for the first time, so every one is baselined.
    #expect(snapshot.events.isEmpty)
    #expect(snapshot.limits == nil)
}

/// A machine that has never run Copilot has no such database, which is not an
/// error: the panel is what says whether the CLI is there.
@Test func aMissingCopilotStoreIsQuiet() async throws {
    let snapshot = try await CopilotSource(store: URL(filePath: "/nope/data.db")).poll()
    #expect(snapshot.workingSessions == 0)
    #expect(snapshot.events.isEmpty)
}

/// The border is the pill saying the machine is busy, so it answers to every
/// tracked provider — a job running under one you are not looking at is exactly
/// the one worth a light around the notch. The badge stays the pinned
/// provider's own count.
@MainActor @Test func theBorderRunsForAnyProviderAndTheBadgeForOne() {
    let busy = AgentSession(
        pid: 1, kind: .bg, name: "a job", directory: "/tmp",
        status: .busy, changedAt: Date()
    )
    let every = Set(SourceID.allCases)

    // Claude working, pill pinned to Codex: badge empty, border running.
    #expect(UsageStore.working(sessions: [busy], logs: [:], for: .codex, tracked: every) == 0)
    #expect(UsageStore.anyoneWorking(sessions: [busy], logs: [:], tracked: every))

    // And a provider nobody is tracking lights nothing.
    #expect(UsageStore.anyoneWorking(sessions: [busy], logs: [:], tracked: [.codex]) == false)
    #expect(UsageStore.anyoneWorking(sessions: [], logs: [.copilot: 2], tracked: every))
    #expect(UsageStore.anyoneWorking(sessions: [], logs: [.copilot: 0], tracked: every) == false)
}


// MARK: - Copilot's running totals

/// Copilot states a session's spend as running totals, rewritten in place. The
/// growth between two reads is the event; the totals themselves never are, or a
/// week of tokens would land on the day the app first saw the row.
@Test func copilotCountsGrowthRatherThanTotals() async throws {
    let store = try copilotStore(copilotSession(
        "s1", project: "p1", input: 103_398, output: 63, cached: 101_734
    ))
    let source = CopilotSource(store: store)

    // First sight of the session is a baseline, not 103,398 tokens today.
    #expect(try await source.poll().events.isEmpty)

    try bump(store, "s1", input: 203_398, output: 163, cached: 201_734, reasoning: 40)
    let events = try await source.poll().events
    #expect(events.count == 1)
    let event = try #require(events.first)
    #expect(event.model == "gpt-6-astra")
    // `owner/name` where the session has one — better than the folder name.
    #expect(event.project == "CoverGo/thing")
    // The delta, and cache is part of input upstream: 100,000 more input of
    // which 100,000 was cached leaves nothing fresh to charge.
    #expect(event.counts.input == 0)
    #expect(event.counts.cacheRead == 100_000)
    #expect(event.counts.output == 100)
    #expect(event.counts.reasoning == 40)

    // Nothing has been written since, so the database is never opened again.
    #expect(try await source.poll().events.isEmpty)
}

/// A session with no repository behind it falls back to the project's own name,
/// and one with no project at all has none.
@Test func copilotNamesAProjectOnlyWhenItHasOne() async throws {
    let store = try copilotStore("""
        \(copilotSession("s1", project: "p2", output: 1))
        \(copilotSession("s2", output: 1))
        """)
    let source = CopilotSource(store: store)
    _ = try await source.poll()

    try bump(store, "s1", output: 11)
    try bump(store, "s2", output: 11)
    let byID = Dictionary(
        uniqueKeysWithValues: try await source.poll().events.map { ($0.sessionID, $0.project) }
    )
    #expect(byID["s1"] == "loose-folder")
    #expect(byID["s2"] == .some(nil))
}

/// A relaunch has no memory of the watermark and no cursor to keep one in — the
/// archived event ids carry it, because an id *is* the totals it moved to.
@Test func copilotResumesFromTheWatermarkInItsEventIds() async throws {
    let store = try copilotStore(copilotSession("s1", project: "p1", output: 100))
    let source = CopilotSource(store: store)
    _ = try await source.poll()
    try bump(store, "s1", input: 10, output: 200, cached: 4, reasoning: 1)
    let first = try await source.poll().events
    #expect(first.count == 1)

    let resumed = CopilotSource(store: store)
    await resumed.restore(cursors: [:], seen: Set(first.map(\.id)))
    // Same totals as the id already claims: no growth, so no event — and no
    // replay of the 100 output tokens the first pass already counted.
    #expect(try await resumed.poll().events.isEmpty)

    try bump(store, "s1", input: 10, output: 250, cached: 4, reasoning: 1)
    #expect(try await resumed.poll().events.first?.counts.output == 50)
}

/// Copilot rewrites the row, so a fork or a rollback can leave a total lower
/// than the one already counted. A negative delta is not usage.
@Test func copilotNeverCountsARowThatWentBackwards() async throws {
    let store = try copilotStore(copilotSession("s1", output: 100))
    let source = CopilotSource(store: store)
    _ = try await source.poll()
    try bump(store, "s1", output: 20)
    #expect(try await source.poll().events.isEmpty)
}

/// `logFiles` walks the tree in `FileManager.enumerator` order, which is
/// unspecified. Two Codex sessions writing at once published whichever file the
/// walk happened to finish on, so the older of two readings of the same account
/// could be the one on screen.
@Test func theNewestCodexReadingWinsWhicheverFileItWasFoundIn() async throws {
    let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    func line(_ stamp: String, _ percent: Int) -> String {
        """
        {"timestamp":"\(stamp)","type":"event_msg","payload":{"type":"token_count",\
        "rate_limits":{"primary":{"used_percent":\(percent),"window_minutes":300,\
        "resets_at":\(Date.now.addingTimeInterval(3600).timeIntervalSince1970)}}}}
        """
    }
    // The newer reading in one file, the older in another. Whichever order the
    // walk yields them in, 80 is the account's figure.
    // The trailing newline matters: a line without one is a partial write, and
    // the reader correctly leaves it for the next poll.
    try (line("2026-09-22T10:00:09.000Z", 80) + "\n")
        .write(to: root.appending(path: "b.jsonl"), atomically: true, encoding: .utf8)
    try (line("2026-09-22T10:00:04.000Z", 78) + "\n")
        .write(to: root.appending(path: "a.jsonl"), atomically: true, encoding: .utf8)

    let source = CodexSource(root: root)
    let snapshot = try await source.poll()
    #expect(snapshot.limits?.primary?.usedPercent == 80)
}
