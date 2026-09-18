import Foundation

/// A Claude Code session, as its own registry file describes it.
///
/// The CLI writes one `<pid>.json` under `~/.claude/sessions` per session it is
/// running and rewrites it whenever the session changes state. Everything here
/// is read from that file: nothing is inferred from a transcript, and nothing is
/// asked of the session itself.
struct AgentSession: Equatable, Sendable, Identifiable {
    /// What the session is doing, in the CLI's own words.
    ///
    /// `waiting` is the only one worth interrupting anybody for: the turn is
    /// over and the session is stopped until someone answers it. `busy` and
    /// `idle` both mean nothing is expected of the user.
    enum Status: String, Sendable { case busy, waiting, idle }

    /// How the session was started. A background job runs with no window of its
    /// own, which is the whole reason a notch has anything to say about it — an
    /// interactive one is already on screen, in the terminal that started it.
    /// Anything the CLI grows later (a cloud session, say) lands in `other` and
    /// is counted as nothing.
    enum Kind: String, Sendable { case bg, interactive, other }

    let pid: Int32
    let kind: Kind
    /// What the session calls itself — the CLI's auto-generated name, or the
    /// title it took from the first prompt.
    let name: String
    /// The session's working directory. Not used for filtering: a session
    /// waiting in another checkout is still waiting.
    let directory: String
    let status: Status
    /// When the session last wrote this file. Newest first is the only order the
    /// registry has — the files themselves carry no rank.
    let changedAt: Date

    var id: Int32 { pid }
    var isWaiting: Bool { status == .waiting }
    /// A background job with work in flight: nothing on screen says so.
    var isRunningJob: Bool { kind == .bg && status == .busy }
}

/// Reads every session Claude Code has registered on this machine.
///
/// Re-read whole rather than incrementally, and deliberately: eleven files of
/// half a kilobyte on a busy machine, and the question is "what is true now",
/// not "what has happened since". There is no cursor here for the same reason.
enum SessionRegistry {
    static var defaultRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude/sessions")
    }

    /// The fields this app has a use for. The file carries a dozen more —
    /// socket paths, peer features, a session id — and none of them belong in a
    /// notch. The `.key` files beside them are peer-messaging secrets and are
    /// never opened.
    private struct Entry: Decodable {
        let pid: Int32
        let kind: String?
        let name: String?
        let cwd: String?
        let status: String?
        /// Milliseconds since the epoch, both of them.
        let updatedAt: Double?
        let statusUpdatedAt: Double?

        var wroteAt: Date {
            Date(timeIntervalSince1970: max(updatedAt ?? 0, statusUpdatedAt ?? 0) / 1000)
        }
    }

    /// `liveness` is injected so the decoding can be tested without a matching
    /// process on the machine running the test.
    static func read(
        root: URL = defaultRoot,
        liveness: (Int32, Date) -> Bool = isAlive
    ) -> [AgentSession] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil
        )) ?? []
        let decoder = JSONDecoder()

        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { url -> AgentSession? in
                // A half-written file is not a failure worth reporting: the write
                // that is landing fires the watcher again a moment later.
                guard let data = try? Data(contentsOf: url),
                      let entry = try? decoder.decode(Entry.self, from: data),
                      // An unknown status is a newer CLI than this build knows.
                      // Dropping it says "nothing is waiting", which is the safe
                      // half of being wrong.
                      let status = entry.status.flatMap(AgentSession.Status.init(rawValue:)),
                      liveness(entry.pid, entry.wroteAt)
                else { return nil }

                return AgentSession(
                    pid: entry.pid,
                    kind: entry.kind.flatMap(AgentSession.Kind.init(rawValue:)) ?? .other,
                    name: entry.name ?? "session \(entry.pid)",
                    directory: entry.cwd ?? "",
                    status: status,
                    changedAt: entry.wroteAt
                )
            }
            .sorted { $0.changedAt > $1.changedAt }
    }

    /// Is the process this file names still the process that wrote it?
    ///
    /// A registry file outlives its session — the CLI does not always get to
    /// clean up after itself — and a dead one left at `waiting` would light the
    /// badge for the rest of the week.
    ///
    /// `kill(pid, 0)` answers "is there a process", not "is it *that* process":
    /// PIDs are recycled. The second half closes that. A recycled PID belongs to
    /// something that started after the old session died, and the old session
    /// wrote this file while it was still alive — so a process that started
    /// *after* the file was last written cannot be the one that wrote it.
    ///
    /// Comparing two epoch figures is the whole check. Reading the time from the
    /// file's own `procStart` string instead would have meant trusting whichever
    /// timezone the CLI happened to format it in, and being wrong about that
    /// hides live sessions rather than stale ones.
    static func isAlive(pid: Int32, wroteAt: Date) -> Bool {
        guard kill(pid, 0) == 0 || errno == EPERM else { return false }
        // No reading from the kernel: the liveness check stands alone. One badge
        // too many beats a badge that silently never appears.
        guard let started = processStart(pid) else { return true }
        return started <= wroteAt.addingTimeInterval(2)
    }

    /// When the kernel says this process started.
    private static func processStart(_ pid: Int32) -> Date? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let start = info.kp_proc.p_starttime
        return Date(timeIntervalSince1970: Double(start.tv_sec) + Double(start.tv_usec) / 1_000_000)
    }
}
