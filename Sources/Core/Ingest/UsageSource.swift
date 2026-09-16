import Foundation

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
    /// Newest line that is part of the conversation, and whether it closed the
    /// turn. Nil for sources that do not mark their turns (Codex).
    var turnAt: Date?
    var turnEnded = false

    /// Two thirds of a session log is bookkeeping — `ai-title`, `mode`,
    /// `queue-operation`, `attachment` — so only these two answer the question.
    static let conversational: Set<String> = ["user", "assistant"]

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

    /// The newest line seen across every log, whatever its type.
    private(set) var activity: LogActivity?

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

        struct Message: Decodable { let stop_reason: String? }

        var endsTurn: Bool { type == "assistant" && message?.stop_reason != "tool_use" }
    }

    /// How far back through a poll's new lines to look for a conversational one.
    /// A finished turn is followed by a short flurry of bookkeeping, never a long
    /// one.
    private static let turnScan = 16

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
               stamp > (activity?.lastLineAt ?? .distantPast) {
                activity = LogActivity(
                    lastLineAt: stamp, lastLineType: meta.type,
                    turnAt: activity?.turnAt, turnEnded: activity?.turnEnded ?? false
                )
            }
            // ponytail: newest turn across every log wins, so two sessions at
            // once report the livelier one. Per-session state if that ever bites.
            for line in lines.suffix(Self.turnScan).reversed() {
                guard let meta = try? JSONDecoder().decode(LineMeta.self, from: line),
                      let type = meta.type, LogActivity.conversational.contains(type),
                      let stamp = meta.timestamp.flatMap(ISO8601.parse)
                else { continue }
                if stamp > (activity?.turnAt ?? .distantPast) {
                    activity?.turnAt = stamp
                    activity?.turnEnded = meta.endsTurn
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
        return events.sorted { $0.timestamp < $1.timestamp }
    }
}
