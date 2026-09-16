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
/// see something: a long turn spent thinking. Claude Code writes the user's turn
/// before the model answers, so a `user` line with nothing after it means a
/// response is being generated at this moment.
struct LogActivity: Equatable, Sendable {
    var lastLineAt: Date
    var lastLineType: String?

    var isAwaitingResponse: Bool { lastLineType == "user" }
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
    }

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
                activity = LogActivity(lastLineAt: stamp, lastLineType: meta.type)
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
