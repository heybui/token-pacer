import CoreServices
import Foundation

/// A kernel-side watch over a log root, answering one question: has anything
/// under it changed since the last time we asked?
///
/// The poll's cost was never reading — cursors already make that incremental —
/// it was *discovery*. Every tick walked `~/.claude/projects` and stat'd every
/// log to find the one being written to, whether or not a byte had moved, all
/// night included.
///
/// Directory mtime cannot answer it. A directory's mtime moves when an entry is
/// created, deleted or renamed *directly inside it*; appending to an existing
/// file touches neither its directory nor any parent. Claude Code appends to one
/// session file for hours, which is exactly the case mtime is blind to.
///
/// Lives outside Core because FSEvents is CoreServices, and Core is Foundation
/// and `os` only.
final class LogWatcher: @unchecked Sendable {
    private let lock = NSLock()
    /// Starts dirty: the first poll has to scan, or a machine that is quiet at
    /// launch shows nothing until someone types.
    private var dirty = true
    private var stream: FSEventStreamRef?

    /// Coarse directory notifications, not per-file ones. All this has to decide
    /// is "scan or don't", and `kFSEventStreamCreateFlagFileEvents` would buy a
    /// callback per file to answer a question that takes one.
    ///
    /// A second of coalescing: the flag is all that happens here, and the 5s tick
    /// is what actually reads. `NoDefer` still delivers the first event of a
    /// burst at once, so typing is not a second behind.
    private static let latency: CFTimeInterval = 1.0

    init?(root: URL) {
        guard FileManager.default.fileExists(atPath: root.path) else { return nil }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<LogWatcher>.fromOpaque(info).takeUnretainedValue().markDirty()
        }

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault, callback, &context,
            [root.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            Self.latency,
            UInt32(kFSEventStreamCreateFlagNoDefer)
        ) else { return nil }

        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, DispatchQueue(label: "tokenpacer.logwatch"))
        FSEventStreamStart(stream)
        Log.usage.info("watching \(root.path, privacy: .public)")
    }

    deinit {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }

    private func markDirty() {
        lock.lock()
        dirty = true
        lock.unlock()
    }

    /// The sources a store polls, watched where a watch is possible.
    ///
    /// Held by the caller: the stream stops when the watcher is released, and a
    /// gate whose watcher has gone reports "nothing changed" for ever.
    @MainActor
    static func watchedSources() -> (sources: [any UsageSource], watchers: [LogWatcher]) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        // Watched independently: a machine with Codex installed but unused had
        // its tree walked every five seconds for ever, and one shared gate would
        // have woken both sources whenever either wrote.
        let claude = LogWatcher(root: home.appending(path: ".claude/projects"))
        let codex = LogWatcher(root: home.appending(path: ".codex/sessions"))

        // A root with no watcher falls back to scanning every tick, which is the
        // behaviour this replaced — it costs the CPU this saves, never accuracy.
        return (
            [
                ClaudeCodeSource(changed: Self.gate(claude)),
                CodexSource(changed: Self.gate(codex)),
            ],
            [claude, codex].compactMap(\.self)
        )
    }

    private static func gate(_ watcher: LogWatcher?) -> ChangeGate? {
        guard let watcher else { return nil }
        return { watcher.consume() }
    }

    /// True when something has changed since the last call, and clears.
    ///
    /// Clearing before the scan rather than after is deliberate: a write that
    /// lands mid-scan sets it again and is read on the next tick, where clearing
    /// afterwards would swallow it.
    func consume() -> Bool {
        lock.lock()
        defer { dirty = false; lock.unlock() }
        return dirty
    }
}
