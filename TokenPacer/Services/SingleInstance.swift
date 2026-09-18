import Foundation

/// Refuses to start a second copy.
///
/// LaunchServices already blocks a second launch of the same *bundle*, but that
/// does nothing for a binary run straight from `.build/`, which is the common way
/// to end up with two pills stacked in the notch.
///
/// The lock is a file lock held for the process lifetime. The kernel drops it when
/// the process goes away — including on a crash or a kill -9 — so there is no
/// stale lock to clean up and no pid file to go wrong.
enum SingleInstance {
    /// Never closed on purpose: closing it would release the lock.
    private nonisolated(unsafe) static var descriptor: CInt = -1

    static var defaultLockURL: URL {
        URL.applicationSupportDirectory
            .appending(path: "TokenPacer")
            .appending(path: "instance.lock")
    }

    /// True when this process may run. False means another copy already holds it.
    @discardableResult
    static func acquire(at url: URL = defaultLockURL) -> Bool {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )

        let fd = open(url.path, O_CREAT | O_RDWR, 0o644)
        // If the lock file itself cannot be opened, start anyway: refusing to run
        // over a locking problem is worse than the duplicate it would prevent.
        guard fd >= 0 else { return true }

        // Close-on-exec, or the lock outlives the app that took it.
        //
        // This app spawns the user's own CLI to read its `/usage` panel, and a
        // spawned child inherits every descriptor that is not marked this way.
        // A CLI still running when the app goes away keeps the lock open on its
        // behalf — so the app refuses to start again, against a process that is
        // not it, until that orphan exits. Seen for real: TokenPacer quit, a
        // `claude` process it had spawned held the descriptor with ppid 1, and
        // every relaunch printed "Token Pacer is already running".
        fcntl(fd, F_SETFD, FD_CLOEXEC)

        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            return false
        }
        descriptor = fd
        return true
    }

    /// Testing seam: drops the lock this process holds.
    static func release() {
        guard descriptor >= 0 else { return }
        flock(descriptor, LOCK_UN)
        close(descriptor)
        descriptor = -1
    }
}
