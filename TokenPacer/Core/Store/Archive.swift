import Foundation
import os

/// What has to outlive the process.
///
/// The app was entirely stateless across launches, which cost more than it
/// looked: the refresh floor restarted with the process, so during development —
/// where a rebuild kills the app every few minutes — every launch spawned another
/// CLI, and the last reading was thrown away with it.
struct ArchivedState: Codable, Sendable {
    /// Bumped when a field's meaning changes. A state file from a newer version
    /// is ignored rather than guessed at.
    ///
    /// 3: the limits no longer come from the usage endpoint but from the CLI's
    /// own `/usage` panel, so the anchors and the calibration a version-2 file
    /// carries describe a reading this build cannot make. The event archive is a
    /// separate file and keeps its cursors, so this costs no cold start.
    static let currentVersion = 3

    var version = currentVersion
    var pollers: [SourceID: PanelPoller] = [:]
    /// The last reading itself, not just the tracker around it. Without it a
    /// relaunch has an anchor but nothing to report, so the pill has no figure
    /// at all until the next request is due — ten minutes of a blank, right
    /// after launch, for no reason.
    var limits: [SourceID: RateLimits] = [:]
    /// Why the last reading failed, if it did.
    ///
    /// The backoff outlives a launch and the reason used to not, so a relaunch
    /// inside the failure window restored "wait ten minutes" without restoring
    /// anything to show for it: a row reading "—", no message under it, and —
    /// because the refresh button is drawn for a complaint — nothing to press
    /// either. Optional so a version-3 file written before this field still
    /// decodes; it is a new fact about the same reading, not a changed one.
    var limitsErrors: [SourceID: String]?
    /// The build that wrote this file, as `1.1.2 (267)`.
    ///
    /// A backoff earned by one build is not evidence against the next: the
    /// failure it counts is usually the very bug the update fixed. Restored
    /// across an upgrade it held the fixed build to the broken one's schedule —
    /// up to an hour of a blank row before the first read. Optional, so a file
    /// from before this field loads, and reads as written by some other build.
    var appVersion: String?
    var savedAt = Date.now
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
    var savedAt = Date.now
}

/// One JSON file in Application Support. No database: this is a few hundred
/// bytes that are rewritten after a network call, not a log.
struct Archive: Sendable {
    var url: URL

    static let `default` = Archive(
        url: FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "TokenPacer/state.json")
    )

    func load() -> ArchivedState? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            let state = try JSONDecoder.archive.decode(ArchivedState.self, from: data)
            // Exact, not "no newer than": an older file is what a bump exists to
            // reject. This state re-measures itself within one refresh, so
            // dropping it costs ten minutes. The *events* archive keeps the
            // looser guard — rebuilding that costs a 700MB cold start.
            guard state.version == ArchivedState.currentVersion else {
                Log.ingest.notice("archive version \(state.version, privacy: .public) is not \(ArchivedState.currentVersion, privacy: .public), ignored")
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
        archived.savedAt = Date.now
        write(archived, to: eventsURL, pretty: false)
    }

    func save(_ state: ArchivedState) {
        var state = state
        state.savedAt = Date.now
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
