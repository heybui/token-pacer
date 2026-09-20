import Foundation

/// Has anything under a source's root changed since the last poll?
///
/// Discovery is what a poll costs — walking the tree and stat-ing every log runs
/// whether or not a byte was written. Something outside Core watches the
/// filesystem and answers this. Nil means nothing is watching, and the scan runs
/// every tick as it always did.
typealias ChangeGate = @Sendable () -> Bool

/// One local CLI's logs. Two conformances today; the shapes differ enough that
/// the protocol earns its keep.
protocol UsageSource: Actor {
    nonisolated var id: SourceID { get }
    func poll() throws -> SourceSnapshot

    /// Byte offsets from the last run, so a relaunch reads only what was appended
    /// rather than 700MB of history. `seen` is rebuilt from the archived events
    /// rather than stored twice.
    func restore(cursors: [String: JSONLReader.Cursor], seen: Set<String>)
    func cursors() -> [String: JSONLReader.Cursor]
}

/// What the newest log line says about right now.
///
/// A usage record is only written when an exchange *completes*, so "tokens were
/// logged recently" goes quiet during exactly the stretch the user most wants to
/// see something: a long turn spent thinking, or a five-minute build running
/// under a tool call. Nothing on disk says "an agent is working" — no lock file,
/// no flag; `~/.claude/ide/*.lock` and the `claude` process both outlive a turn
/// by hours. The only live signal is the shape of the newest conversational line.
struct LogActivity: Equatable, Sendable {
    /// Newest line of any kind, bookkeeping included. Drives the quiet window.
    var lastLineAt: Date
    var lastLineType: String?
    /// Newest line that opened or closed a turn, and which of the two it was.
    /// Nil until a source has marked one.
    var turnAt: Date?
    var turnEnded = false

    /// The lines that open and close a turn, in both formats. Two thirds of a
    /// session log is bookkeeping — `ai-title`, `mode`, `queue-operation`,
    /// `attachment`, `item_completed` — so only these four answer the question.
    ///
    /// Claude marks a turn with the conversation itself: a `user` line opens
    /// one, an `assistant` line that did not stop for a tool closes it. Codex
    /// says so outright, one level down, in `payload.type`.
    static let turnMarkers: Set<String> = ["user", "assistant", "task_started", "task_complete"]

    /// A prompt or a tool result with no answer yet, or an assistant line that
    /// stopped to run a tool. Both mean work is happening with nothing logged.
    var isAwaitingResponse: Bool { turnAt != nil && !turnEnded }
}

/// Shared plumbing: cursors plus dedupe. A value type, so a source can mutate its
/// own state inside the decode closure without overlapping access to itself.
struct LogScanner {
    private var reader = JSONLReader()
    private var seen = Set<String>()

    /// `seen` only has to catch history replayed into a *new* file on resume;
    /// cursors already guarantee each line is read once.
    /// ponytail: flat cap, swap for a time-windowed set if a heavy user trips it.
    private static let seenLimit = 50_000

    /// One reading per log file. A machine runs several sessions at once and
    /// they are not one stream: the newest line belongs to whichever session was
    /// quickest, and the turn in flight is as often another's.
    private(set) var activityByFile: [URL: LogActivity] = [:]

    /// The liveliest session, which is not the loudest one. A turn in flight
    /// wins over one that has ended however recently the finished session wrote
    /// — bookkeeping from a session that just stopped used to hide the session
    /// that was still working.
    var activity: LogActivity? {
        let all = activityByFile.values
        return all.filter(\.isAwaitingResponse).max { $0.lastLineAt < $1.lastLineAt }
            ?? all.max { $0.lastLineAt < $1.lastLineAt }
    }

    /// Sessions with a turn open right now.
    ///
    /// Capped at the same in-flight window the dot uses: a CLI killed mid-turn
    /// leaves its last line looking like work that never finished, and a log
    /// that has said nothing for a quarter of an hour is not a job in progress.
    func working(at now: Date) -> Int {
        activityByFile.values.count {
            $0.isAwaitingResponse
                && now.timeIntervalSince($0.lastLineAt) < SnapshotBuilder.inFlightWindow
        }
    }

    mutating func restore(cursors: [String: JSONLReader.Cursor], seen: Set<String>) {
        reader.archived = cursors
        self.seen = seen
    }

    var cursors: [String: JSONLReader.Cursor] { reader.archived }

    private struct LineMeta: Decodable {
        let type: String?
        let timestamp: String?
        /// `tool_use` means the model stopped to run something and is coming
        /// back; anything else means it handed the turn back.
        let message: Message?
        /// Codex nests the kind of line one level down, and leaves the top-level
        /// `type` saying only which stream it belongs to — `event_msg`.
        let payload: Payload?

        struct Message: Decodable { let stop_reason: String? }
        struct Payload: Decodable { let type: String? }

        /// What kind of line this is, whichever level its format states it at.
        /// Claude's lines carry no payload, so the top level answers there.
        var kind: String? { payload?.type ?? type }

        var endsTurn: Bool {
            kind == "task_complete"
                || (kind == "assistant" && message?.stop_reason != "tool_use")
        }
    }

    /// How far back through a poll's new lines to look for a turn marker. A
    /// finished turn is followed by a short flurry of bookkeeping, never a long
    /// one — but Codex writes a line per tool call and per reasoning block, and
    /// at 16 a busy second's worth of them hid the `task_complete` behind them,
    /// which leaves a finished turn looking like one still in flight. The scan
    /// stops at the first marker it meets, so this is only the worst case.
    private static let turnScan = 64

    mutating func scan(
        root: URL,
        since: Date? = nil,
        decode: (Data, URL) -> [UsageEvent]
    ) throws -> [UsageEvent] {
        var events: [UsageEvent] = []
        for file in JSONLReader.logFiles(under: root, modifiedAfter: since) {
            guard let lines = try? reader.newLines(in: file) else { continue }
            // Only the last line of each file, and only the two fields: a `user`
            // line carries the whole prompt, and decoding every one of them would
            // undo the byte prefilter that keeps a cold start cheap.
            if let last = lines.last, let meta = try? JSONDecoder().decode(LineMeta.self, from: last),
               let stamp = meta.timestamp.flatMap(ISO8601.parse),
               stamp > (activityByFile[file]?.lastLineAt ?? .distantPast) {
                activityByFile[file] = LogActivity(
                    lastLineAt: stamp, lastLineType: meta.type,
                    turnAt: activityByFile[file]?.turnAt,
                    turnEnded: activityByFile[file]?.turnEnded ?? false
                )
            }
            for line in lines.suffix(Self.turnScan).reversed() {
                guard let meta = try? JSONDecoder().decode(LineMeta.self, from: line),
                      let kind = meta.kind, LogActivity.turnMarkers.contains(kind),
                      let stamp = meta.timestamp.flatMap(ISO8601.parse)
                else { continue }
                if stamp > (activityByFile[file]?.turnAt ?? .distantPast) {
                    activityByFile[file]?.turnAt = stamp
                    activityByFile[file]?.turnEnded = meta.endsTurn
                }
                break
            }
            for line in lines {
                for event in decode(line, file) where !seen.contains(event.id) {
                    seen.insert(event.id)
                    events.append(event)
                }
            }
        }
        if seen.count > Self.seenLimit { seen.removeAll(keepingCapacity: true) }
        prune(at: Date.now)
        return events.sorted { $0.timestamp < $1.timestamp }
    }

    /// A month of retained logs is a month of files, and all but the last few
    /// are answered questions. Keep every session that could still be working,
    /// and the newest reading whatever its age — the dot asks for that one by
    /// name, and on a quiet machine it is the only one there is.
    private mutating func prune(at now: Date) {
        guard let newest = activityByFile.max(by: { $0.value.lastLineAt < $1.value.lastLineAt })?.key
        else { return }
        activityByFile = activityByFile.filter {
            $0.key == newest
                || now.timeIntervalSince($0.value.lastLineAt) < SnapshotBuilder.inFlightWindow
        }
    }
}
