import Foundation
import SQLite3

/// Reads `~/.copilot/data.db`, where Copilot records what each session it has
/// opened has spent and whether that session is answering right now.
///
/// Not a usage source in the sense the other two are: Copilot states its spend
/// in its own `/usage` panel, so there are no limits here. This carries the
/// volume, the models and the projects the panel has no room for, and the one
/// fact a panel cannot give — a session in flight.
///
/// It used to read two other places, and Copilot went quiet in both.
/// `session-store.db`'s `assistant_usage_events` had a row per request and
/// stopped being written. `open-sessions-state.json` is still written, but only
/// once, at session open: `refreshedAt` never advances past `openedAt` and
/// `working` was false in all 109 entries on the machine this was rewritten
/// against, so a dot waiting for that flag could never light. Both facts moved
/// into one row per session here:
///
/// ```
/// sessions(id, model, updated_at, is_running,
///          total_input_tokens, total_output_tokens,
///          total_cached_tokens, total_reasoning_tokens)
/// ```
///
/// What that costs, stated plainly: these are **running totals**, not a row per
/// request. A session's growth between two polls becomes one event stamped
/// `updated_at`, so Copilot's sparkline and splits are as fine as the poll where
/// Claude's and Codex's are as fine as the request. Nothing finer is left on
/// disk. There is no cache-write column either, so a write is counted as plain
/// input rather than invented.
actor CopilotSource: UsageSource {
    nonisolated let id = SourceID.copilot

    /// Copilot's own store. Opened read-only, never written to, and only when
    /// it has moved.
    private let store: URL
    /// Newest mtime of the store and its write-ahead log as of the last query.
    /// Copilot writes into the WAL, so the database file alone does not move.
    private var queriedAt: Date?
    private let cutoff: Date?
    /// How much of each session has already been turned into events.
    private var emitted: [String: Totals] = [:]
    /// `updated_at` of every session the last query found running.
    private var running: [Date] = []

    init(
        store: URL = AgentHome.copilot.appending(path: "data.db"),
        retention: TimeInterval? = TimeInterval(Aggregator.historyDays) * 24 * 3600
    ) {
        self.store = store
        self.cutoff = retention.map { Date.now.addingTimeInterval(-$0) }
    }

    // MARK: - Resuming

    /// The protocol persists byte offsets, and a running total is not one — but
    /// the archived event ids come back through here, and an id *is* the
    /// watermark it moved its session to. That is enough to resume without a
    /// second store.
    func restore(cursors: [String: JSONLReader.Cursor], seen: Set<String>) {
        for id in seen {
            guard let mark = Self.watermark(in: id),
                  mark.totals.sum > (emitted[mark.session]?.sum ?? -1)
            else { continue }
            emitted[mark.session] = mark.totals
        }
    }

    /// Nothing: see `restore`.
    func cursors() -> [String: JSONLReader.Cursor] { [:] }

    func poll() throws -> SourceSnapshot {
        let now = Date.now
        // `-wal`, not `.wal`: SQLite names it by appending to the whole path.
        // Fresh `URL`s each time: `resourceValues(forKeys:)` caches what it read
        // on the instance it read it from, so a stored one answers with the
        // mtime it had when the app launched and the store is never re-read.
        let moved = [store.path, store.path + "-wal"]
            .compactMap { try? FileManager.default.attributesOfItem(atPath: $0) }
            .compactMap { $0[.modificationDate] as? Date }
            .max()

        var events: [UsageEvent] = []
        if moved != queriedAt {
            queriedAt = moved
            events = read()
        }

        return SourceSnapshot(
            source: .copilot, events: events, limits: nil,
            // `is_running` outlives a crash — a session killed mid-turn keeps
            // the flag set — so it is believed only while its row is still
            // moving, on the same in-flight cap every other provider's dot uses.
            workingSessions: running.count {
                now.timeIntervalSince($0) < SnapshotBuilder.inFlightWindow
            }
        )
    }

    // MARK: - The sessions table

    private func read() -> [UsageEvent] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(store.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return []
        }
        defer { sqlite3_close(db) }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, Self.query, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        let since = cutoff.map { $0.formatted(.iso8601) } ?? "0000"
        sqlite3_bind_text(statement, 1, since, -1, Self.transient)

        var events: [UsageEvent] = []
        running = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let session = text(statement, 0),
                  let stamp = text(statement, 2).flatMap(ISO8601.parse)
            else { continue }
            if sqlite3_column_int(statement, 3) == 1 { running.append(stamp) }

            let totals = Totals(
                input: count(statement, 4), output: count(statement, 5),
                cached: count(statement, 6), reasoning: count(statement, 7)
            )
            let previous = emitted[session]
            emitted[session] = totals
            // A session met for the first time is baselined, never counted: its
            // totals are however long it has been running, and landing a week of
            // tokens on today is worse than missing them. Everything after this
            // poll is growth, and growth is what an event is.
            guard let previous else { continue }

            let counts = totals.delta(since: previous).counts
            guard counts.total > 0 else { continue }

            events.append(UsageEvent(
                id: Self.identify(session, at: totals),
                source: .copilot,
                timestamp: stamp,
                model: text(statement, 1),
                // `owner/name` when the session was opened in a repository,
                // which reads better than the folder name behind it.
                project: text(statement, 8).flatMap { owner in
                    text(statement, 9).map { "\(owner)/\($0)" }
                } ?? text(statement, 10),
                sessionID: session,
                counts: counts
            ))
        }
        return events
    }

    /// One row per session, with whatever repository it was opened in.
    ///
    /// `GROUP BY` because the workspace join is 1:1 today and this does not
    /// depend on it staying that way: a session that grew two workspaces would
    /// otherwise be read twice in one pass.
    private static let query = """
        SELECT s.id, s.model, s.updated_at, s.is_running,
               s.total_input_tokens, s.total_output_tokens,
               s.total_cached_tokens, s.total_reasoning_tokens,
               p.github_owner, p.github_repo, p.name
          FROM sessions s
          LEFT JOIN workspaces w ON w.session_id = s.id
          LEFT JOIN projects   p ON p.id = w.project_id
         WHERE s.updated_at >= ?
         GROUP BY s.id
         ORDER BY s.updated_at
        """

    // MARK: - Watermarks

    /// Cumulative totals, exactly as a row states them.
    private struct Totals: Equatable {
        var input = 0
        var output = 0
        var cached = 0
        var reasoning = 0

        var sum: Int { input + output + cached + reasoning }

        /// Clamped: Copilot rewrites a session's row, and a fork or a rollback
        /// can leave a total lower than the one already counted.
        func delta(since previous: Totals) -> Totals {
            Totals(
                input: max(0, input - previous.input),
                output: max(0, output - previous.output),
                cached: max(0, cached - previous.cached),
                reasoning: max(0, reasoning - previous.reasoning)
            )
        }

        /// `total_cached_tokens` is part of `total_input_tokens`, as it was in
        /// the row-per-request table before it — 42,373 of a 42,375-token prompt
        /// on the session this was written against. Subtracting it is what makes
        /// the figure comparable with the other two providers.
        var counts: TokenCounts {
            TokenCounts(
                input: max(0, input - cached), output: output,
                cacheWrite: 0, cacheRead: cached,
                // A subset of output here too. Display only, never weighted again.
                reasoning: reasoning
            )
        }
    }

    private static func identify(_ session: String, at totals: Totals) -> String {
        "copilot:\(session):\(totals.input)-\(totals.output)-\(totals.cached)-\(totals.reasoning)"
    }

    /// A session whose events have all aged out of retention comes back unknown,
    /// and an unknown session is baselined rather than counted. An id this does
    /// not recognise — the row-per-request `copilot:<rowid>` that came before —
    /// is simply not a watermark.
    private static func watermark(in id: String) -> (session: String, totals: Totals)? {
        let parts = id.split(separator: ":")
        guard parts.count == 3, parts[0] == "copilot" else { return nil }
        let numbers = parts[2].split(separator: "-").compactMap { Int($0) }
        guard numbers.count == 4 else { return nil }
        return (
            String(parts[1]),
            Totals(input: numbers[0], output: numbers[1],
                   cached: numbers[2], reasoning: numbers[3])
        )
    }

    // MARK: - SQLite

    /// SQLite must copy a bound string: the Swift one it points at is gone by
    /// the time the statement runs.
    private static let transient = unsafeBitCast(
        -1, to: sqlite3_destructor_type.self
    )

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
