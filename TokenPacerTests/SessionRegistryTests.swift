import Foundation
import Testing
@testable import TokenPacer

/// Writes a registry directory the way Claude Code writes one: `<pid>.json` per
/// session, with the `.key` files it keeps beside them.
private func registry(_ entries: [(pid: Int32, status: String, wroteAt: Double)]) -> URL {
    let root = URL.temporaryDirectory.appending(path: "registry-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    for entry in entries {
        let json = """
        {"pid":\(entry.pid),"sessionId":"f1b6bfef-0bd6-4ccf-8a9c-88ed21735324",\
        "cwd":"/Users/x/token-pacer","name":"the border work","kind":"interactive",\
        "status":"\(entry.status)","updatedAt":\(entry.wroteAt),"statusUpdatedAt":\(entry.wroteAt)}
        """
        try! Data(json.utf8).write(to: root.appending(path: "\(entry.pid).json"))
        try! Data("secret".utf8).write(to: root.appending(path: "\(entry.pid).abc123.key"))
    }
    return root
}

private let now = Date().timeIntervalSince1970 * 1000

@Test func registryCountsOnlyWaitingSessions() {
    let root = registry([
        (pid: 101, status: "waiting", wroteAt: now),
        (pid: 102, status: "busy", wroteAt: now - 1000),
        (pid: 103, status: "idle", wroteAt: now - 2000),
    ])
    let sessions = SessionRegistry.read(root: root) { _, _ in true }
    #expect(sessions.count == 3)
    #expect(sessions.count(where: \.isWaiting) == 1)
    // Newest change first: the panel and the badge both read this order.
    #expect(sessions.map(\.pid) == [101, 102, 103])
    #expect(sessions.first?.name == "the border work")
}

/// The file outlives its process, and a dead one left at `waiting` would light
/// the badge for ever.
@Test func registryDropsSessionsWhoseProcessIsGone() {
    let root = registry([
        (pid: 101, status: "waiting", wroteAt: now),
        (pid: 102, status: "waiting", wroteAt: now),
    ])
    let sessions = SessionRegistry.read(root: root) { pid, _ in pid == 101 }
    #expect(sessions.map(\.pid) == [101])
}

/// A status this build has never heard of is a newer CLI. Dropping the session
/// says "nothing is waiting", which is the safe half of being wrong.
@Test func registryIgnoresAnUnknownStatus() {
    let root = registry([(pid: 101, status: "compacting", wroteAt: now)])
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
