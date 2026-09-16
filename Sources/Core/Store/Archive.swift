import Foundation
import os

/// What has to outlive the process.
///
/// The app was entirely stateless across launches, which cost more than it
/// looked: calibration restarted from zero anchors every time — so during
/// development, where a rebuild kills the app every few minutes, the conversion
/// could never be measured at all — and the 10-minute floor restarted with it,
/// so a relaunch jumped the queue at an undocumented endpoint.
struct ArchivedState: Codable, Sendable {
    /// Bumped when a field's meaning changes. A state file from a newer version
    /// is ignored rather than guessed at.
    static let currentVersion = 1

    var version = currentVersion
    var trackers: [SourceID: LiveLimitsTracker] = [:]
    var isPaused = false
    var savedAt = Date()
}

/// One JSON file in Application Support. No database: this is a few hundred
/// bytes that are rewritten after a network call, not a log.
struct Archive: Sendable {
    var url: URL

    static let `default` = Archive(
        url: FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "BurnTracker/state.json")
    )

    func load() -> ArchivedState? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            let state = try JSONDecoder.archive.decode(ArchivedState.self, from: data)
            guard state.version <= ArchivedState.currentVersion else {
                Log.ingest.notice("archive from a newer version \(state.version, privacy: .public), ignored")
                return nil
            }
            return state
        } catch {
            // A truncated or hand-edited file is not worth failing a launch over.
            Log.ingest.error("archive unreadable: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    func save(_ state: ArchivedState) {
        var state = state
        state.savedAt = Date()
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            // Atomic: a crash mid-write must not leave a half-written state file
            // that the next launch then refuses.
            try JSONEncoder.archive.encode(state).write(to: url, options: .atomic)
        } catch {
            Log.ingest.error("archive unwritable: \(error.localizedDescription, privacy: .public)")
        }
    }
}

private extension JSONEncoder {
    static let archive: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()
}

private extension JSONDecoder {
    static let archive: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
