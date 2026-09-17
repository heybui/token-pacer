import Foundation
import Testing
@testable import BurnTracker

private func tempLock() -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appending(path: "burntracker-lock-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appending(path: "instance.lock")
}

@Test func theFirstProcessGetsTheLock() {
    let lock = tempLock()
    #expect(SingleInstance.acquire(at: lock))
    SingleInstance.release()
}

/// flock is held per open file description, so a second acquire is refused even
/// from inside the same process — which is what makes this testable at all.
@Test func aSecondAcquireIsRefusedWhileTheFirstIsHeld() {
    let lock = tempLock()
    #expect(SingleInstance.acquire(at: lock))
    #expect(SingleInstance.acquire(at: lock) == false)
    SingleInstance.release()
}

@Test func releasingLetsTheNextProcessIn() {
    let lock = tempLock()
    #expect(SingleInstance.acquire(at: lock))
    SingleInstance.release()
    #expect(SingleInstance.acquire(at: lock))
    SingleInstance.release()
}

/// Separate locks must not block each other, or one stray file would wedge
/// everything.
@Test func differentLockFilesAreIndependent() {
    let first = tempLock()
    #expect(SingleInstance.acquire(at: first))
    SingleInstance.release()
    #expect(SingleInstance.acquire(at: tempLock()))
    SingleInstance.release()
}

@Test func aMissingParentDirectoryIsCreated() {
    let nested = FileManager.default.temporaryDirectory
        .appending(path: "burntracker-\(UUID().uuidString)/deep/instance.lock")
    #expect(SingleInstance.acquire(at: nested))
    #expect(FileManager.default.fileExists(atPath: nested.path))
    SingleInstance.release()
}
