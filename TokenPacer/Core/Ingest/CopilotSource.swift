import Foundation
import SQLite3

/// Reads `~/.copilot/open-sessions-state.json`, which is everything Copilot
/// writes down about what it is doing.
///
/// Not a usage source in the sense the other two are. Copilot states its spend
/// in its own `/usage` panel, so there are no events here and no limits — the
/// panel carries both, and this carries the one fact a panel cannot: whether a
/// session is answering right now.
///
/// It does keep a token log, and this reads it: `session-store.db` has an
/// `assistant_usage_events` row per request — model, the four counts, and the
/// AIU it cost — joined to `sessions` for the repository it ran in. A live
/// SQLite file in WAL mode, so it is opened read-only and stepped through from
/// the last row id rather than scanned as lines.
///
/// ```json
/// "e0a9f75e-…": { "schemaVersion": 1, "openedAt": "…", "refreshedAt": "…", "working": false }
/// ```
///
/// Two things the file does not have, and what stands in for them. Nothing ever
/// removes an entry — the oldest on the machine this was written against was two
/// days old — and this file names no pid, so an entry is believed only while its
/// own `refreshedAt` is recent, on the same in-flight cap the dot uses for every
/// other provider. (`session-state/<id>/inuse.<pid>.lock` does name one, one
/// directory over, if this ever needs to be surer than a timestamp.)
actor CopilotSource: UsageSource {
    nonisolated let id = SourceID.copilot

    private let file: URL
    /// Copilot's own store. Opened read-only, never written to, and only when
    /// it has moved.
    private let store: URL
    /// The last `assistant_usage_events.id` turned into an event. Archived
    /// through the cursor the protocol already persists — an offset into a file
    /// and a row id in a table are the same promise: start after this.
    private var lastRowID: Int64 = 0
    /// Newest mtime of the store and its write-ahead log as of the last query.
    /// Copilot writes into the WAL, so the database file alone does not move.
    private var queriedAt: Date?
    private let cutoff: Date?
    /// The file's own modification date, as of the last decode. Re-reading
    /// seventeen kilobytes of JSON five times a minute for an answer that only
    /// changes when somebody types is a stat's worth of work too much.
    private var decodedAt: Date?
    private var sessions: [Session] = []

    private struct Session {
        let refreshedAt: Date
        let isWorking: Bool
    }

    init(
        file: URL = AgentHome.copilot.appending(path: "open-sessions-state.json"),
        store: URL = AgentHome.copilot.appending(path: "session-store.db"),
        retention: TimeInterval? = TimeInterval(Aggregator.historyDays) * 24 * 3600
    ) {
        self.file = file
        self.store = store
        self.cutoff = retention.map { Date.now.addingTimeInterval(-$0) }
    }

    /// The sessions file is the whole state and is read fresh; the store is
    /// resumed from its last row.
    func restore(cursors: [String: JSONLReader.Cursor], seen: Set<String>) {
        lastRowID = Int64(cursors[store.path]?.offset ?? 0)
    }

    func cursors() -> [String: JSONLReader.Cursor] {
        [store.path: JSONLReader.Cursor(offset: UInt64(lastRowID), inode: 0)]
    }

    func poll() throws -> SourceSnapshot {
        let modified = try? file.resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate
        if modified != decodedAt {
            decodedAt = modified
            sessions = Self.decode(file)
        }

        let now = Date.now
        let live = sessions.filter {
            now.timeIntervalSince($0.refreshedAt) < SnapshotBuilder.inFlightWindow
        }
        let working = live.filter(\.isWorking)

        // Only the flag, never the entry's existence: this app's own `/usage`
        // run opens a Copilot session and writes one, and a dot that blinks
        // every time the app reads a figure is worse than one that never lights.
        return SourceSnapshot(
            source: .copilot, events: usage(), limits: nil, workingSessions: working.count
        )
    }

    // MARK: - the request log

    /// Every request logged since the last row read.
    ///
    /// `input_tokens` is the whole prompt — cache reads and writes included, as
    /// the row's own `token_details_json` spells out: three fresh input tokens
    /// inside a 103,398-token prompt. Subtracting them is what makes this
    /// comparable with the other two providers, exactly as Codex needs.
    private func usage() -> [UsageEvent] {
        // `-wal`, not `.wal`: SQLite names it by appending to the whole path.
        let moved = [store, URL(filePath: store.path + "-wal")]
            .compactMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]) }
            .compactMap(\.contentModificationDate)
            .max()
        guard moved != queriedAt else { return [] }
        queriedAt = moved

        var db: OpaquePointer?
        guard sqlite3_open_v2(store.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return []
        }
        defer { sqlite3_close(db) }

        // A store rebuilt from scratch starts its ids again, so a cursor past
        // the end means the table is not the one it was read from.
        if let highest = single(db, "SELECT MAX(id) FROM assistant_usage_events"),
           highest < lastRowID {
            lastRowID = 0
        }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, Self.query, -1, &statement, nil) == SQLITE_OK else { return [] }
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

            let cacheRead = Int(sqlite3_column_int64(statement, 4))
            let cacheWrite = Int(sqlite3_column_int64(statement, 5))
            let counts = TokenCounts(
                input: max(0, Int(sqlite3_column_int64(statement, 2)) - cacheRead - cacheWrite),
                output: Int(sqlite3_column_int64(statement, 3)),
                cacheWrite: cacheWrite,
                cacheRead: cacheRead,
                // A subset of output here too. Display only, never weighted again.
                reasoning: Int(sqlite3_column_int64(statement, 6))
            )
            guard counts.total > 0 else { continue }

            events.append(UsageEvent(
                id: "copilot:\(rowID)",
                source: .copilot,
                timestamp: stamp,
                model: text(statement, 1),
                // `owner/name` when the session was opened in a repository,
                // which reads better than the last path component every other
                // source has to settle for.
                project: text(statement, 9) ?? text(statement, 10).map {
                    URL(filePath: $0).lastPathComponent
                },
                sessionID: text(statement, 8),
                counts: counts
            ))
        }
        return events
    }

    private static let query = """
        SELECT e.id, e.model, e.input_tokens, e.output_tokens,
               e.cache_read_tokens, e.cache_write_tokens, e.reasoning_tokens,
               e.created_at, e.session_id, s.repository, s.cwd
          FROM assistant_usage_events e
          LEFT JOIN sessions s ON s.id = e.session_id
         WHERE e.id > ? AND e.created_at >= ?
         ORDER BY e.id
        """

    /// SQLite must copy a bound string: the Swift one it points at is gone by
    /// the time the statement runs.
    private static let transient = unsafeBitCast(
        -1, to: sqlite3_destructor_type.self
    )

    /// Both spellings the column holds: the CLI writes ISO 8601, the schema's
    /// own default writes `datetime('now')`.
    private static func parse(_ text: String) -> Date? {
        ISO8601.parse(text) ?? ISO8601.parse(text.replacing(" ", with: "T") + "Z")
    }

    private func single(_ db: OpaquePointer?, _ sql: String) -> Int64? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        return sqlite3_step(statement) == SQLITE_ROW ? sqlite3_column_int64(statement, 0) : nil
    }

    /// Empty is absent. Copilot writes `''` rather than NULL in the columns it
    /// has nothing for, and an empty project name would be a row of its own in
    /// the panel's splits.
    private func text(_ statement: OpaquePointer?, _ column: Int32) -> String? {
        sqlite3_column_text(statement, column)
            .map { String(cString: $0) }
            .flatMap { $0.isEmpty ? nil : $0 }
    }

    private struct Entry: Decodable {
        let refreshedAt: String?
        let openedAt: String?
        let working: Bool?
    }

    /// A missing file is a Copilot that has never been run, not a failure: the
    /// panel says whether the CLI is there, and says it better.
    private static func decode(_ file: URL) -> [Session] {
        guard let data = try? Data(contentsOf: file),
              let entries = try? JSONDecoder().decode([String: Entry].self, from: data)
        else { return [] }

        return entries.values.compactMap { entry in
            guard let stamp = (entry.refreshedAt ?? entry.openedAt).flatMap(ISO8601.parse)
            else { return nil }
            return Session(refreshedAt: stamp, isWorking: entry.working == true)
        }
    }
}
