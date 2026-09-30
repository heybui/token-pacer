import Foundation

/// Reads `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`.
///
/// Unlike Claude, Codex states its own rate limits, so this source reports them
/// verbatim and the engine never has to guess.
actor CodexSource: UsageSource {
    nonisolated let id = SourceID.codex

    private let root: URL
    private var scanner = LogScanner()
    /// `session_meta` appears once at the top of a log; later polls of the same
    /// file resume past it, so the working directory has to be remembered.
    private var projectByFile: [URL: String] = [:]
    /// And the model with it. Codex states it on `turn_context`, at the head of
    /// each turn, and leaves it off the token records that follow — so every
    /// Codex event was filed under "unknown" in the panel's own splits.
    private var modelByFile: [URL: String] = [:]
    private var latestLimits: RateLimits?
    /// Whether a log writes `token_usage_record`. Codex before 0.153 did not,
    /// and stated each request only as the `last_token_usage` of a
    /// `token_count` — so six days of it were missing from the history grid.
    /// Sniffed once per file, from the file itself: a relaunch resumes past
    /// the first record, and the record always precedes its `token_count`.
    private var writesRecords: [URL: Bool] = [:]

    private let cutoff: Date?
    private let changed: ChangeGate?
    private var lastScan = Date.distantPast

    /// As Claude's: the watcher is a shortcut, never the only way a write is
    /// noticed. See `ClaudeCodeSource.scanAtLeastEvery`.
    private static let scanAtLeastEvery: TimeInterval = 60

    init(
        root: URL = AgentHome.codex.appending(path: "sessions"),
        retention: TimeInterval? = TimeInterval(Aggregator.historyDays) * 24 * 3600,
        changed: ChangeGate? = nil
    ) {
        self.root = root
        self.cutoff = retention.map { Date.now.addingTimeInterval(-$0) }
        self.changed = changed
    }

    func restore(cursors: [String: JSONLReader.Cursor], seen: Set<String>) {
        scanner.restore(cursors: cursors, seen: seen)
    }

    func cursors() -> [String: JSONLReader.Cursor] { scanner.cursors }

    func poll() throws -> SourceSnapshot {
        // A machine with Codex installed but unused still had its tree walked
        // every five seconds, for ever. The limits are the last reading either
        // way — nothing was written, so nothing has moved.
        let now = Date.now
        if let changed, !changed(), now.timeIntervalSince(lastScan) < Self.scanAtLeastEvery {
            return SourceSnapshot(
                source: .codex, events: [], limits: latestLimits,
                workingSessions: scanner.working(at: now)
            )
        }
        lastScan = now

        // Detached copy: `decode` mutates self, so the scanner cannot also be
        // held as an inout on self at the same time.
        var local = scanner
        let events = try local.scan(root: root, since: cutoff) { self.decode($0, file: $1) }
        scanner = local
        // Codex marks its turns outright — `task_started` … `task_complete` —
        // so the dot follows the turn rather than the last line written, and a
        // session mid-turn is a job the badge can count. Codex registers its
        // sessions nowhere: `~/.codex` holds a lock file per thread with nothing
        // in it, so the log is the only place that knows.
        return SourceSnapshot(
            source: .codex, events: events, limits: latestLimits,
            workingSessions: scanner.working(at: now)
        )
    }

    private static let interesting = [
        "token_usage_record", "token_count", "rate_limits", "session_meta", "turn_context",
    ]

    private func decode(_ line: Data, file: URL) -> [UsageEvent] {
        guard Self.interesting.contains(where: line.containsBytes(of:)),
              let row = try? JSONDecoder().decode(Line.self, from: line),
              let stamp = row.timestamp.flatMap(ISO8601.parse)
        else { return [] }

        switch row.type {
        case "session_meta":
            if let cwd = row.payload?.cwd {
                projectByFile[file] = URL(fileURLWithPath: cwd).lastPathComponent
            }
            return []

        case "turn_context":
            if projectByFile[file] == nil, let cwd = row.payload?.cwd {
                projectByFile[file] = URL(fileURLWithPath: cwd).lastPathComponent
            }
            // Overwritten rather than kept: `/model` mid-session is a new
            // `turn_context`, and the turns after it are that model's.
            if let model = row.payload?.model { modelByFile[file] = model }
            return []

        case "event_msg":
            // `token_count` carries the authoritative limits. Its usage is an
            // event only in a log that writes no `token_usage_record` — where
            // there is one, counting both would double every request.
            // Newest wins, not last-read wins. `logFiles` walks the tree in
            // `FileManager.enumerator` order, which is unspecified, so two
            // sessions writing at once published whichever file the walk
            // happened to finish on — and a cold start over 90 days of history
            // could end on a weekly window days old, whose reset is still in
            // the future and so is shown as current.
            if let limits = row.payload?.rate_limits,
               stamp > (latestLimits?.observedAt ?? .distantPast) {
                latestLimits = limits.normalised(observedAt: stamp)
            }
            return legacyUsage(row, at: stamp, file: file)

        case "token_usage_record":
            writesRecords[file] = true
            guard let payload = row.payload,
                  let usage = payload.usage,
                  let responseID = payload.response_id
            else { return [] }

            let counts = usage.counts
            guard counts.total > 0 else { return [] }

            return [UsageEvent(
                id: "codex:" + responseID,
                source: .codex,
                timestamp: stamp,
                // From the turn's own context line, since the record itself
                // carries no model at all.
                model: row.payload?.model ?? modelByFile[file],
                project: projectByFile[file],
                sessionID: payload.session_id,
                counts: counts
            )]

        default:
            return []
        }
    }

    /// A request as a `token_count` states it, for a log with no records.
    ///
    /// Keyed by the running total it brought the session to: Codex repeats a
    /// `token_count` when only the limits moved, and a repeat has the same
    /// total, so `seen` drops it.
    private func legacyUsage(_ row: Line, at stamp: Date, file: URL) -> [UsageEvent] {
        guard let info = row.payload?.info,
              let usage = info.last_token_usage,
              let total = info.total_token_usage?.total_tokens,
              !hasRecords(file)
        else { return [] }
        let counts = usage.counts
        guard counts.total > 0 else { return [] }

        return [UsageEvent(
            id: "codex:\(file.deletingPathExtension().lastPathComponent):\(total)",
            source: .codex,
            timestamp: stamp,
            model: modelByFile[file],
            project: projectByFile[file],
            sessionID: nil,
            counts: counts
        )]
    }

    private func hasRecords(_ file: URL) -> Bool {
        if let known = writesRecords[file] { return known }
        let found = (try? Data(contentsOf: file, options: .mappedIfSafe))?
            .containsBytes(of: "\"token_usage_record\"") ?? false
        writesRecords[file] = found
        return found
    }

    private struct Line: Decodable {
        let type: String?
        let timestamp: String?
        let payload: Payload?

        struct Payload: Decodable {
            let cwd: String?
            let model: String?
            let session_id: String?
            let response_id: String?
            let usage: Usage?
            let rate_limits: Limits?
            let info: Info?
        }

        struct Info: Decodable {
            let last_token_usage: Usage?
            let total_token_usage: Usage?
        }

        struct Usage: Decodable {
            let input_tokens: Int?
            let cached_input_tokens: Int?
            let cache_write_input_tokens: Int?
            let output_tokens: Int?
            let reasoning_output_tokens: Int?
            let total_tokens: Int?

            /// `cached_input_tokens` is a SUBSET of `input_tokens` here, unlike
            /// Claude. Subtracting is what makes the two sources comparable.
            var counts: TokenCounts {
                let cacheRead = cached_input_tokens ?? 0
                return TokenCounts(
                    input: max(0, (input_tokens ?? 0) - cacheRead),
                    output: output_tokens ?? 0,
                    cacheWrite: cache_write_input_tokens ?? 0,
                    cacheRead: cacheRead,
                    // Also a subset, of output. Display only; never weighted again.
                    reasoning: reasoning_output_tokens ?? 0
                )
            }
        }

        struct Limits: Decodable {
            let primary: Window?
            let secondary: Window?
            let plan_type: String?

            struct Window: Decodable {
                let used_percent: Double?
                let window_minutes: Int?
                let resets_at: Double?

                var normalised: RateLimitWindow? {
                    guard let used = used_percent,
                          let minutes = window_minutes,
                          let resets = resets_at
                    else { return nil }
                    return RateLimitWindow(
                        usedPercent: used,
                        windowMinutes: minutes,
                        resetsAt: Date(timeIntervalSince1970: resets)
                    )
                }
            }

            func normalised(observedAt: Date) -> RateLimits {
                RateLimits(
                    primary: primary?.normalised,
                    secondary: secondary?.normalised,
                    planType: plan_type,
                    observedAt: observedAt
                )
            }
        }
    }
}
