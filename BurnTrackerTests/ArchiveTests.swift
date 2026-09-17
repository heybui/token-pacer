import Foundation
import Testing
@testable import BurnTracker

private let t0 = Date(timeIntervalSince1970: 1_789_000_000)

private func temporaryArchive() -> Archive {
    Archive(url: FileManager.default.temporaryDirectory
        .appending(path: "burn-tracker-tests/\(UUID().uuidString)/state.json"))
}

/// The floor cannot depend on uptime: a relaunch used to reset it, so a rebuild
/// every few minutes during development meant a `/usage` run every few minutes.
@Test func theRunFloorSurvivesARelaunch() throws {
    var poller = PanelPoller()
    poller.ran(at: t0)

    let archive = temporaryArchive()
    archive.save(ArchivedState(pollers: [.claude: poller], isPaused: true))

    let state = try #require(archive.load())
    var restored = try #require(state.pollers[.claude])
    #expect(state.isPaused)

    restored.record(weighted: 1000)
    #expect(restored.shouldRun(at: t0.addingTimeInterval(60)) == false)
    #expect(restored.shouldRun(at: t0.addingTimeInterval(400)))
}

/// Backoff is state worth keeping too: a CLI that failed twice before the last
/// quit should not be respawned immediately after the next launch.
@Test func backoffSurvivesARelaunch() throws {
    var poller = PanelPoller()
    poller.ran(at: t0)
    poller.record(weighted: 1000)
    poller.failed(at: t0)
    poller.failed(at: t0)

    let archive = temporaryArchive()
    archive.save(ArchivedState(pollers: [.claude: poller]))

    let state = try #require(archive.load())
    var restored = try #require(state.pollers[.claude])
    restored.record(weighted: 1000)
    #expect(restored.shouldRun(at: t0.addingTimeInterval(600)) == false)   // 4 × 5 min
    #expect(restored.shouldRun(at: t0.addingTimeInterval(1_300)))
}

/// The count of "usage since the last run" is rebuilt from the logs, never
/// carried over — the sources replay everything they hold on a cold start.
@Test func activitySinceTheLastRunIsNotArchived() throws {
    var poller = PanelPoller()
    poller.ran(at: t0)
    poller.record(weighted: 90_000)

    let archive = temporaryArchive()
    archive.save(ArchivedState(pollers: [.claude: poller]))

    let restored = try #require(archive.load()).pollers[.claude]
    #expect(restored?.pendingWeighted == 0)
    #expect(restored?.hasNewActivity == false)
}

@Test func aMissingOrCorruptArchiveIsNotAFailure() throws {
    let archive = temporaryArchive()
    #expect(archive.load() == nil)

    try FileManager.default.createDirectory(
        at: archive.url.deletingLastPathComponent(), withIntermediateDirectories: true
    )
    try Data("{ not json".utf8).write(to: archive.url)
    #expect(archive.load() == nil)
}

/// A file written by a newer build may mean something else by the same field.
@Test func aNewerArchiveIsIgnoredRatherThanGuessedAt() throws {
    let archive = temporaryArchive()
    var state = ArchivedState()
    state.version = ArchivedState.currentVersion + 1
    archive.save(state)

    #expect(archive.load() == nil)
}

// MARK: - the cold start

/// A source that counts how often its log was actually opened.
private actor CountingSource: UsageSource {
    nonisolated let id: SourceID
    private var scanner = LogScanner()
    private let root: URL
    private(set) var scans = 0

    init(id: SourceID = .claude, root: URL) {
        self.id = id
        self.root = root
    }

    func restore(cursors: [String: JSONLReader.Cursor], seen: Set<String>) {
        scanner.restore(cursors: cursors, seen: seen)
    }

    func cursors() -> [String: JSONLReader.Cursor] { scanner.cursors }

    func poll() throws -> SourceSnapshot {
        scans += 1
        let events = try scanner.scan(root: root, decode: ClaudeCodeSource.decode)
        return SourceSnapshot(source: id, events: events, limits: nil)
    }
}

private func writeLog(_ lines: [String], to directory: URL, named name: String) throws -> URL {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appending(path: name)
    try lines.joined(separator: "\n").appending("\n").write(to: url, atomically: true, encoding: .utf8)
    return url
}

private func line(id: String, output: Int, at date: Date) -> String {
    """
    {"type":"assistant","timestamp":"\(date.ISO8601Format())","cwd":"/tmp/demo",\
    "sessionId":"s","requestId":"\(id)","message":{"id":"m\(id)","model":"claude-opus-5",\
    "usage":{"input_tokens":10,"output_tokens":\(output)}}}
    """
}

/// The point of the exercise: a relaunch must not re-read the log corpus.
@MainActor
@Test func aRelaunchReadsOnlyWhatWasAppended() async throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "burn-tracker-tests/\(UUID().uuidString)")
    let log = try writeLog(
        [line(id: "1", output: 100, at: Date()), line(id: "2", output: 200, at: Date())],
        to: root, named: "session.jsonl"
    )
    let archive = temporaryArchive()

    let first = CountingSource(root: root)
    let store = UsageStore(sources: [first], interval: 3600, archive: archive)
    store.start()
    // Let the pump restore, poll and persist.
    try await Task.sleep(for: .milliseconds(200))
    store.stop()
    await store.flush()
    #expect(store.eventCount(.claude) == 2)

    // A new process over the same logs and the same archive.
    try FileHandle(forWritingTo: log).seekToEnd()
    try Data(line(id: "3", output: 300, at: Date()).appending("\n").utf8)
        .write(to: root.appending(path: "later.jsonl"))

    let second = CountingSource(root: root)
    let relaunched = UsageStore(sources: [second], interval: 3600, archive: archive)
    relaunched.start()
    try await Task.sleep(for: .milliseconds(200))
    relaunched.stop()

    // All three events are present, but the first two came from the archive: the
    // cursor means their bytes were never read again.
    #expect(relaunched.eventCount(.claude) == 3)

    // The cursor sits at the end of the file it never opened. (Compared by value:
    // the enumerator resolves /var to /private/var, so the key is not log.path.)
    let size = try FileHandle(forReadingFrom: log).seekToEnd()
    let cursors = await second.cursors()
    #expect(cursors.values.contains { $0.offset == size })
}

/// Replayed history in a new file must not be counted twice — the dedupe set is
/// rebuilt from the archived events rather than stored alongside them.
@MainActor
@Test func replayedHistoryIsStillDeduplicatedAfterARelaunch() async throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "burn-tracker-tests/\(UUID().uuidString)")
    _ = try writeLog([line(id: "1", output: 100, at: Date())], to: root, named: "session.jsonl")
    let archive = temporaryArchive()

    let store = UsageStore(sources: [CountingSource(root: root)], interval: 3600, archive: archive)
    store.start()
    try await Task.sleep(for: .milliseconds(200))
    store.stop()
    await store.flush()

    // A resumed session replays the same exchange into a different file.
    _ = try writeLog([line(id: "1", output: 100, at: Date())], to: root, named: "resumed.jsonl")

    let relaunched = UsageStore(sources: [CountingSource(root: root)], interval: 3600, archive: archive)
    relaunched.start()
    try await Task.sleep(for: .milliseconds(200))
    relaunched.stop()

    #expect(relaunched.eventCount(.claude) == 1)
}

/// Without the reading itself, a relaunch has nothing to report and the pill
/// drops to the inferred ceiling — a worse number — until the next run is due.
@Test func theLastReadingSurvivesARelaunch() throws {
    let limits = RateLimits(
        primary: RateLimitWindow(usedPercent: 25, windowMinutes: 300,
                                 resetsAt: t0.addingTimeInterval(3600)),
        secondary: RateLimitWindow(usedPercent: 17, windowMinutes: 10080,
                                   resetsAt: t0.addingTimeInterval(86400)),
        planType: "max", observedAt: t0,
        spend: Spend(used: Money(amountMinor: 1199, currency: "SGD", exponent: 2),
                     limit: nil, percent: 99, isEnabled: true)
    )
    let archive = temporaryArchive()
    archive.save(ArchivedState(limits: [.claude: limits]))

    let restored = try #require(archive.load()).limits[.claude]
    #expect(restored?.primary?.usedPercent == 25)
    #expect(restored?.secondary?.usedPercent == 17)      // the weekly figure, not "--"
    #expect(restored?.spend?.used.amountMinor == 1199)
    #expect(restored?.observedAt == t0)                  // still says how old it is
}
