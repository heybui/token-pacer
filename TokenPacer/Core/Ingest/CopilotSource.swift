import Foundation
import SQLite3

/// Reads what Copilot writes down about its requests and its sessions, from
/// three places, because no one of them has both.
///
/// **Usage** is `session-store.db`'s `assistant_usage_events`: a row per
/// request — model, the four counts, its own timestamp — joined to `sessions`
/// for the repository. Every client writes it, the CLI included, so it is the
/// only one of the three that can fill the history grid backwards.
///
/// It was dropped once for `data.db`'s running totals, on the evidence that it
/// had not been written since 11 Sep. It was written again after that, and it
/// holds every session `data.db` does, with the same input and output totals,
/// plus the CLI's own. A running total can only count growth after the app
/// first saw it; a row per request needs no such guess.
///
/// **Running** is either `data.db`'s `sessions.is_running`, or an open turn in
/// the CLI's `session-state/<id>/events.jsonl` — the CLI never puts its
/// sessions in `data.db`. Merged by session id; some sessions appear in both.
///
/// Not a usage source in the sense the other two are: Copilot states its spend
/// in its own `/usage` panel, so there are no limits here.
actor CopilotSource: UsageSource {
    nonisolated let id = SourceID.copilot

    /// A few hundred rows a month, read whole in a millisecond. Cheaper than a
    /// cursor that has to survive a store Copilot rebuilds.
    nonisolated var rereadsOnLaunch: Bool { true }

    /// The request log. Opened read-only, never written to, and only when it
    /// has moved.
    private let log: URL
    /// Where the running flag lives.
    private let store: URL
    /// Newest mtime of each database and its write-ahead log as of the last
    /// query. Copilot writes into the WAL, so the database file alone does not
    /// move.
    private var loggedAt: Date?
    private var storedAt: Date?
    private let cutoff: Date?
    /// The last `assistant_usage_events.id` turned into an event.
    private var lastRowID: Int64 = 0
    /// `updated_at` of every session the last query found running, by id.
    private var running: [String: Date] = [:]

    /// The CLI's per-session event logs. Read for turn markers only.
    private let sessions: URL
    private var scanner = LogScanner()
    private let changed: ChangeGate?
    private var lastScan = Date.distantPast

    /// As Claude's: the watcher is a shortcut, never the only way a write is
    /// noticed. See `ClaudeCodeSource.scanAtLeastEvery`.
    private static let scanAtLeastEvery: TimeInterval = 60

    init(
        log: URL = AgentHome.copilot.appending(path: "session-store.db"),
        store: URL = AgentHome.copilot.appending(path: "data.db"),
        sessions: URL = AgentHome.copilot.appending(path: "session-state"),
        retention: TimeInterval? = TimeInterval(Aggregator.historyDays) * 24 * 3600,
        changed: ChangeGate? = nil
    ) {
        self.log = log
        self.store = store
        self.sessions = sessions
        self.cutoff = retention.map { Date.now.addingTimeInterval(-$0) }
        self.changed = changed
    }

    /// Nothing: see `rereadsOnLaunch`.
    func restore(cursors: [String: JSONLReader.Cursor], seen: Set<String>) {}
    func cursors() -> [String: JSONLReader.Cursor] { [:] }

    func poll() throws -> SourceSnapshot {
        let now = Date.now

        var events: [UsageEvent] = []
        let logMoved = Self.modified(log)
        if logMoved != loggedAt {
            loggedAt = logMoved
            events = usage()
        }
        let storeMoved = Self.modified(store)
        if storeMoved != storedAt {
            storedAt = storeMoved
            running = flagged()
        }

        if changed?() ?? true || now.timeIntervalSince(lastScan) >= Self.scanAtLeastEvery {
            lastScan = now
            // Nothing to decode: usage comes from the request log.
            _ = try? scanner.scan(root: sessions, since: cutoff) { _, _ in [] }
        }

        // `is_running` outlives a crash — a session killed mid-turn keeps the
        // flag set — so it is believed only while its row is still moving, on
        // the same in-flight cap every other provider's dot uses. The scanner
        // applies that cap to the logs itself.
        let live = running.filter {
            now.timeIntervalSince($0.value) < SnapshotBuilder.inFlightWindow
        }.keys
        let logged = scanner.workingFiles(at: now).map {
            $0.deletingLastPathComponent().lastPathComponent
        }
        return SourceSnapshot(
            source: .copilot, events: events, limits: nil,
            workingSessions: Set(live).union(logged).count
        )
    }

    /// `-wal`, not `.wal`: SQLite names it by appending to the whole path.
    /// Fresh paths each time: `resourceValues(forKeys:)` caches what it read on
    /// the `URL` it read it from, so a stored one answers with the mtime it had
    /// when the app launched and the database is never re-read.
    private static func modified(_ database: URL) -> Date? {
        [database.path, database.path + "-wal"]
            .compactMap { try? FileManager.default.attributesOfItem(atPath: $0) }
            .compactMap { $0[.modificationDate] as? Date }
            .max()
    }

    // MARK: - The request log

    /// Every request logged since the last row read.
    ///
    /// `input_tokens` is the whole prompt — cache reads and writes included, as
    /// the row's own `token_details_json` spells out: 15 fresh tokens inside a
    /// 216,755-token prompt. Subtracting them is what makes this comparable
    /// with the other two providers, exactly as Codex needs.
    private func usage() -> [UsageEvent] {
        guard let db = Self.open(log) else { return [] }
        defer { sqlite3_close(db) }

        // A store rebuilt from scratch starts its ids again, so a cursor past
        // the end means the table is not the one it was read from.
        if let highest = single(db, "SELECT MAX(id) FROM assistant_usage_events"),
           highest < lastRowID {
            lastRowID = 0
        }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, Self.usageQuery, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, lastRowID)
        // Compared as a date alone: rows written by the schema's own default
        // are `2026-09-11 08:23:38`, not the ISO string the CLI writes, and ten
        // characters is all the two spellings agree on.
        let since = cutoff.map { String($0.formatted(.iso8601).prefix(10)) } ?? "0000-00-00"
        sqlite3_bind_text(statement, 2, since, -1, Self.transient)

        var events: [UsageEvent] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let rowID = sqlite3_column_int64(statement, 0)
            lastRowID = max(lastRowID, rowID)
            guard let stamp = text(statement, 7).flatMap(Self.parse) else { continue }

            let cacheRead = count(statement, 4)
            let cacheWrite = count(statement, 5)
            let counts = TokenCounts(
                input: max(0, count(statement, 2) - cacheRead - cacheWrite),
                output: count(statement, 3),
                cacheWrite: cacheWrite,
                cacheRead: cacheRead,
                // A subset of output here too. Display only, never weighted again.
                reasoning: count(statement, 6)
            )
            guard counts.total > 0 else { continue }

            events.append(UsageEvent(
                id: "copilot:\(rowID)",
                source: .copilot,
                timestamp: stamp,
                model: text(statement, 1),
                // `owner/name` when the session was opened in a repository,
                // which reads better than the folder name behind it.
                project: text(statement, 9) ?? text(statement, 10).flatMap(ProjectName.of),
                sessionID: text(statement, 8),
                counts: counts
            ))
        }
        return events
    }

    private static let usageQuery = """
        SELECT e.id, e.model, e.input_tokens, e.output_tokens,
               e.cache_read_tokens, e.cache_write_tokens, e.reasoning_tokens,
               e.created_at, e.session_id, s.repository, s.cwd
          FROM assistant_usage_events e
          LEFT JOIN sessions s ON s.id = e.session_id
         WHERE e.id > ? AND e.created_at >= ?
         ORDER BY e.id
        """

    /// Both spellings the column holds: the CLI writes ISO 8601, the schema's
    /// own default writes `datetime('now')`.
    private static func parse(_ text: String) -> Date? {
        ISO8601.parse(text) ?? ISO8601.parse(text.replacing(" ", with: "T") + "Z")
    }

    // MARK: - The running flag

    private func flagged() -> [String: Date] {
        guard let db = Self.open(store) else { return [:] }
        defer { sqlite3_close(db) }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, Self.runningQuery, -1, &statement, nil) == SQLITE_OK else { return [:] }
        defer { sqlite3_finalize(statement) }

        var running: [String: Date] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let session = text(statement, 0),
                  let stamp = text(statement, 1).flatMap(ISO8601.parse)
            else { continue }
            running[session] = stamp
        }
        return running
    }

    private static let runningQuery = "SELECT id, updated_at FROM sessions WHERE is_running = 1"

    // MARK: - SQLite

    /// SQLite must copy a bound string: the Swift one it points at is gone by
    /// the time the statement runs.
    private static let transient = unsafeBitCast(
        -1, to: sqlite3_destructor_type.self
    )

    /// A missing database is a Copilot that has never been run, not a failure:
    /// the panel says whether the CLI is there, and says it better.
    private static func open(_ database: URL) -> OpaquePointer? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(database.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        return db
    }

    private func single(_ db: OpaquePointer?, _ sql: String) -> Int64? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        return sqlite3_step(statement) == SQLITE_ROW ? sqlite3_column_int64(statement, 0) : nil
    }

    private func count(_ statement: OpaquePointer?, _ column: Int32) -> Int {
        Int(sqlite3_column_int64(statement, column))
    }

    /// Empty is absent. Copilot writes `''` rather than NULL in the columns it
    /// has nothing for, and an empty project name would be a row of its own in
    /// the panel's splits.
    private func text(_ statement: OpaquePointer?, _ column: Int32) -> String? {
        sqlite3_column_text(statement, column)
            .map { String(cString: $0) }
            .flatMap { $0.isEmpty ? nil : $0 }
    }
}
