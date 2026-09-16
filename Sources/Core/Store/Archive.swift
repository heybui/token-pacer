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

/// Events and cursors: the expensive half.
///
/// A cold start reads ~700MB of JSONL across 500-odd files because the byte
/// cursors start empty. Archiving the events the store already holds — and where
/// each file was left — turns that into one read of a few megabytes plus whatever
/// has been appended since. Kept in its own file: it is a thousand times the size
/// of the limits state and is written a thousand times less often.
struct ArchivedEvents: Codable, Sendable {
    static let currentVersion = 1

    struct PerSource: Codable, Sendable {
        var cursors: [String: JSONLReader.Cursor] = [:]
        var events: [UsageEvent] = []
    }

    var version = currentVersion
    var sources: [SourceID: PerSource] = [:]
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

    /// Sits beside the state file.
    var eventsURL: URL { url.deletingLastPathComponent().appending(path: "events.json") }

    func loadEvents() -> ArchivedEvents? {
        guard let data = try? Data(contentsOf: eventsURL) else { return nil }
        do {
            let archived = try JSONDecoder.archive.decode(ArchivedEvents.self, from: data)
            guard archived.version <= ArchivedEvents.currentVersion else { return nil }
            return archived
        } catch {
            // Re-reading the logs is slow, never wrong: a bad file costs a cold
            // start, not correctness.
            Log.ingest.error("event archive unreadable: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    func saveEvents(_ archived: ArchivedEvents) {
        var archived = archived
        archived.savedAt = Date()
        write(archived, to: eventsURL, pretty: false)
    }

    func save(_ state: ArchivedState) {
        var state = state
        state.savedAt = Date()
        write(state, to: url, pretty: true)
    }

    private func write(_ value: some Encodable, to url: URL, pretty: Bool) {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            // Atomic: a crash mid-write must not leave a half-written file that
            // the next launch then refuses.
            let encoder = pretty ? JSONEncoder.archive : JSONEncoder.compact
            try encoder.encode(value).write(to: url, options: .atomic)
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

private extension JSONEncoder {
    /// No whitespace for the big one; it is read by machines only.
    static let compact: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
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
