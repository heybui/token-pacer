import Foundation

/// Reads `~/.claude/projects/<slug>/<uuid>.jsonl`.
///
/// Claude Code publishes no rate-limit state in its logs, so `limits` is always
/// nil here and the percentage has to be inferred — see `CeilingEstimator`.
actor ClaudeCodeSource: UsageSource {
    nonisolated let id = SourceID.claude

    private let root: URL
    private var scanner = LogScanner()

    private let cutoff: Date?
    private let changed: ChangeGate?
    private var lastScan = Date.distantPast

    /// A full scan runs at least this often whatever the gate says.
    ///
    /// FSEvents can drop events — a busy volume, a watcher started mid-write. A
    /// dropped one has to cost a minute of staleness, not the rest of the
    /// session, so the timer stays as the floor underneath it.
    private static let scanAtLeastEvery: TimeInterval = 60

    init(
        root: URL = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude/projects"),
        retention: TimeInterval? = TimeInterval(Aggregator.historyDays) * 24 * 3600,
        changed: ChangeGate? = nil
    ) {
        self.root = root
        self.cutoff = retention.map { Date().addingTimeInterval(-$0) }
        self.changed = changed
    }

    /// Nothing written and the floor not yet up: skip the walk.
    ///
    /// The events are what the scan is for, and there are none — but `activity`
    /// is a running answer, not a fresh reading, so the last one still stands and
    /// the ring does not blink off between beats of work.
    private func canSkipScan(at now: Date) -> Bool {
        guard let changed, !changed() else { return false }
        return now.timeIntervalSince(lastScan) < Self.scanAtLeastEvery
    }

    func restore(cursors: [String: JSONLReader.Cursor], seen: Set<String>) {
        scanner.restore(cursors: cursors, seen: seen)
    }

    func cursors() -> [String: JSONLReader.Cursor] { scanner.cursors }

    func poll() throws -> SourceSnapshot {
        let now = Date()
        guard !canSkipScan(at: now) else {
            return SourceSnapshot(source: .claude, events: [], limits: nil, activity: scanner.activity)
        }
        lastScan = now
        let events = try scanner.scan(root: root, since: cutoff, decode: Self.decode)
        return SourceSnapshot(source: .claude, events: events, limits: nil, activity: scanner.activity)
    }

    static func decode(_ line: Data, file: URL) -> [UsageEvent] {
        // Skip the prompts and tool output before JSONDecoder sees them. Matching
        // the bare word, not `"type":"assistant"`, because JSON whitespace is not
        // guaranteed; a false positive only costs one wasted decode.
        guard line.containsBytes(of: "assistant"),
              let row = try? JSONDecoder().decode(Line.self, from: line),
              row.type == "assistant",
              let usage = row.message?.usage,
              let stamp = row.timestamp.flatMap(ISO8601.parse)
        else { return [] }

        let counts = TokenCounts(
            input: usage.input_tokens ?? 0,
            output: usage.output_tokens ?? 0,
            cacheWrite: usage.cache_creation_input_tokens ?? 0,
            cacheRead: usage.cache_read_input_tokens ?? 0,
            reasoning: usage.output_tokens_details?.thinking_tokens ?? 0
        )
        guard counts.total > 0 else { return [] }

        // message.id alone repeats across a resumed session's replayed history;
        // pairing it with requestId is what actually identifies one API call.
        let key = [row.message?.id, row.requestId]
            .compactMap(\.self)
            .joined(separator: "#")
        guard !key.isEmpty else { return [] }

        return [UsageEvent(
            id: "claude:" + key,
            source: .claude,
            timestamp: stamp,
            model: row.message?.model,
            project: row.cwd.map { URL(fileURLWithPath: $0).lastPathComponent },
            sessionID: row.sessionId,
            counts: counts
        )]
    }

    /// Only the fields we need. Everything else in the record is ignored, which
    /// is what keeps this resilient to the format growing.
    private struct Line: Decodable {
        let type: String?
        let timestamp: String?
        let cwd: String?
        let sessionId: String?
        let requestId: String?
        let message: Message?

        struct Message: Decodable {
            let id: String?
            let model: String?
            let usage: Usage?
        }

        struct Usage: Decodable {
            let input_tokens: Int?
            let output_tokens: Int?
            let cache_creation_input_tokens: Int?
            let cache_read_input_tokens: Int?
            let output_tokens_details: Details?

            struct Details: Decodable { let thinking_tokens: Int? }
        }
    }
}
