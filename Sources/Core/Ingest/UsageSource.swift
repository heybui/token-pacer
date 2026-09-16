import Foundation

/// One local CLI's logs. Two conformances today; the shapes differ enough that
/// the protocol earns its keep.
protocol UsageSource: Actor {
    nonisolated var id: SourceID { get }
    func poll() throws -> SourceSnapshot
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

    mutating func scan(
        root: URL,
        since: Date? = nil,
        decode: (Data, URL) -> [UsageEvent]
    ) throws -> [UsageEvent] {
        var events: [UsageEvent] = []
        for file in JSONLReader.logFiles(under: root, modifiedAfter: since) {
            guard let lines = try? reader.newLines(in: file) else { continue }
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
