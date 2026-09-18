import Foundation
import Testing
@testable import TokenPacer

/// Writes a registry directory the way Claude Code writes one: `<pid>.json` per
/// session, with the `.key` files it keeps beside them.
private func registry(_ entries: [(pid: Int32, kind: String, status: String, wroteAt: Double)]) -> URL {
    let root = URL.temporaryDirectory.appending(path: "registry-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    for entry in entries {
        let json = """
        {"pid":\(entry.pid),"sessionId":"f1b6bfef-0bd6-4ccf-8a9c-88ed21735324",\
        "cwd":"/Users/x/token-pacer","name":"the border work","kind":"\(entry.kind)",\
        "status":"\(entry.status)","updatedAt":\(entry.wroteAt),"statusUpdatedAt":\(entry.wroteAt)}
        """
        try! Data(json.utf8).write(to: root.appending(path: "\(entry.pid).json"))
        try! Data("secret".utf8).write(to: root.appending(path: "\(entry.pid).abc123.key"))
    }
    return root
}

private let now = Date().timeIntervalSince1970 * 1000

/// The badge counts background jobs with work in flight. An interactive session
/// that is busy is already on screen in the terminal running it, and a job that
/// is idle is not doing anything — neither belongs in the figure.
@Test func registryCountsOnlyWorkingBackgroundJobs() {
    let root = registry([
        (pid: 101, kind: "bg", status: "busy", wroteAt: now),
        (pid: 102, kind: "bg", status: "idle", wroteAt: now - 1000),
        (pid: 103, kind: "interactive", status: "busy", wroteAt: now - 2000),
        (pid: 104, kind: "interactive", status: "waiting", wroteAt: now - 3000),
    ])
    let sessions = SessionRegistry.read(root: root) { _, _ in true }
    #expect(sessions.count == 4)
    #expect(sessions.count(where: \.isRunningJob) == 1)
    // Newest change first: the panel and the badge both read this order.
    #expect(sessions.map(\.pid) == [101, 102, 103, 104])
    #expect(sessions.first?.name == "the border work")
}

/// The file outlives its process, and a dead one left at `waiting` would light
/// the badge for ever.
@Test func registryDropsSessionsWhoseProcessIsGone() {
    let root = registry([
        (pid: 101, kind: "bg", status: "busy", wroteAt: now),
        (pid: 102, kind: "bg", status: "busy", wroteAt: now),
    ])
    let sessions = SessionRegistry.read(root: root) { pid, _ in pid == 101 }
    #expect(sessions.map(\.pid) == [101])
}

/// A status this build has never heard of is a newer CLI. Dropping the session
/// says "nothing is running", which is the safe half of being wrong.
@Test func registryIgnoresAnUnknownStatus() {
    let root = registry([(pid: 101, kind: "bg", status: "compacting", wroteAt: now)])
    #expect(SessionRegistry.read(root: root) { _, _ in true }.isEmpty)
}

@Test func registryIsEmptyWhenClaudeCodeHasNeverRun() {
    let missing = URL.temporaryDirectory.appending(path: "no-such-registry-\(UUID().uuidString)")
    #expect(SessionRegistry.read(root: missing) { _, _ in true }.isEmpty)
}

/// This process is alive, and it wrote nothing — but it certainly started before
/// "a moment ago", which is the whole of the recycled-PID check.
@Test func livenessAcceptsThisProcess() {
    #expect(SessionRegistry.isAlive(pid: ProcessInfo.processInfo.processIdentifier, wroteAt: Date()))
}

/// A stale file claiming a process that started long after it was last written:
/// the PID was recycled, and this is not the session that wrote it.
@Test func livenessRejectsAPidRecycledAfterTheFileWasWritten() {
    let pid = ProcessInfo.processInfo.processIdentifier
    #expect(!SessionRegistry.isAlive(pid: pid, wroteAt: Date(timeIntervalSince1970: 1)))
}

/// A kind this build has never heard of — a cloud session, whatever comes next —
/// is read and kept, but it is not a background job on this machine and does not
/// reach the badge.
@Test func registryKeepsAnUnknownKindOutOfTheCount() {
    let root = registry([(pid: 101, kind: "cloud", status: "busy", wroteAt: now)])
    let sessions = SessionRegistry.read(root: root) { _, _ in true }
    #expect(sessions.count == 1)
    #expect(sessions.count(where: \.isRunningJob) == 0)
}
