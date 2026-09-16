import Foundation
import Testing
@testable import BurnTracker

private let t0 = Date(timeIntervalSince1970: 1_789_000_000)

private func temporaryArchive() -> Archive {
    Archive(url: FileManager.default.temporaryDirectory
        .appending(path: "burn-tracker-tests/\(UUID().uuidString)/state.json"))
}

/// Calibration takes two anchors ten minutes apart. A process that restarts more
/// often than that — every rebuild during development — can never measure it.
@Test func calibrationSurvivesARelaunch() throws {
    var tracker = LiveLimitsTracker()
    tracker.anchored(LimitsAnchor(utilization: 10, observedAt: t0, resetsAt: nil), at: t0)
    tracker.record(weighted: 50_000)
    tracker.anchored(
        LimitsAnchor(utilization: 15, observedAt: t0.addingTimeInterval(600), resetsAt: nil),
        at: t0.addingTimeInterval(600)
    )
    #expect(tracker.calibration.weightedPerPercent == 10_000)

    let archive = temporaryArchive()
    archive.save(ArchivedState(trackers: [.claude: tracker], isPaused: true))

    let restored = try #require(archive.load())
    #expect(restored.trackers[.claude]?.calibration.weightedPerPercent == 10_000)
    #expect(restored.trackers[.claude]?.calibration.samples == 1)
    #expect(restored.isPaused)
}

/// Politeness to an undocumented endpoint cannot depend on uptime: a relaunch
/// used to reset the floor and fire a request straight away.
@Test func theRequestFloorSurvivesARelaunch() throws {
    var tracker = LiveLimitsTracker()
    tracker.anchored(LimitsAnchor(utilization: 10, observedAt: t0, resetsAt: nil), at: t0)

    let archive = temporaryArchive()
    archive.save(ArchivedState(trackers: [.claude: tracker]))
    var restored = try #require(archive.load()).trackers[.claude]!

    restored.record(weighted: 1000)
    #expect(restored.refreshReason(at: t0.addingTimeInterval(60)) == nil)
    #expect(restored.refreshReason(at: t0.addingTimeInterval(700)) != nil)
}

/// The count of "usage since the anchor" is rebuilt from the logs, never carried
/// over — the sources replay everything they hold on a cold start.
@Test func activitySinceTheAnchorIsNotArchived() throws {
    var tracker = LiveLimitsTracker()
    tracker.anchored(LimitsAnchor(utilization: 10, observedAt: t0, resetsAt: nil), at: t0)
    tracker.record(weighted: 90_000)

    let archive = temporaryArchive()
    archive.save(ArchivedState(trackers: [.claude: tracker]))

    let restored = try #require(archive.load()).trackers[.claude]
    #expect(restored?.weightedSinceAnchor == 0)
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
