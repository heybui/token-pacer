import Foundation

/// Incremental line reader. Re-parsing every log on a 5s tick would read hundreds
/// of megabytes, so each file keeps a byte offset and only new bytes are decoded.
struct JSONLReader {
    struct Cursor: Equatable, Sendable, Codable {
        var offset: UInt64
        var inode: UInt64
    }

    private(set) var cursors: [URL: Cursor] = [:]

    /// Archived by path: a URL key would encode as an array, and the path is what
    /// identifies the file across launches anyway.
    var archived: [String: Cursor] {
        get { Dictionary(uniqueKeysWithValues: cursors.map { ($0.key.path, $0.value) }) }
        set { cursors = Dictionary(uniqueKeysWithValues: newValue.map { (URL(filePath: $0.key), $0.value) }) }
    }

    /// Complete lines appended since the last call.
    ///
    /// A log being written to can end mid-line, so anything after the final
    /// newline is left for next time rather than handed back as a truncated
    /// record. A changed inode (rotation) or a shrunken file (truncation) resets
    /// the cursor to the start.
    mutating func newLines(in url: URL, fileManager: FileManager = .default) throws -> [Data] {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        let inode = (attributes[.systemFileNumber] as? UInt64) ?? 0
        let size = (attributes[.size] as? UInt64) ?? 0

        var cursor = cursors[url] ?? Cursor(offset: 0, inode: inode)
        if cursor.inode != inode || size < cursor.offset {
            cursor = Cursor(offset: 0, inode: inode)
        }
        guard size > cursor.offset else {
            cursors[url] = cursor
            return []
        }

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: cursor.offset)
        guard let data = try handle.readToEnd(), !data.isEmpty else { return [] }

        guard let lastNewline = data.lastIndex(of: 0x0A) else {
            return []   // no complete line yet; leave the cursor where it was
        }
        cursor.offset += UInt64(lastNewline) + 1
        cursors[url] = cursor

        // Annotated, and called rather than passed: `Sequence` and `Collection`
        // both declare this `split`, and `Data.init` names three overloads that
        // all fit, so neither resolves on its own. The copy is load bearing —
        // a slice keeps its parent's indices, and a decoder reads those.
        return data[..<lastNewline]
            .split(separator: 0x0A, omittingEmptySubsequences: true)
            .map { (line: Data.SubSequence) in Data(line) }
    }

    /// Every `.jsonl` under a root, or empty if the root doesn't exist.
    ///
    /// `modifiedAfter` skips logs older than the retention window outright: on a
    /// machine with years of history most files can never contribute an event,
    /// and opening them is the bulk of a cold start.
    static func logFiles(
        under root: URL,
        modifiedAfter: Date? = nil,
        fileManager: FileManager = .default
    ) -> [URL] {
        guard let walker = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        return walker.compactMap { $0 as? URL }
            .filter { $0.pathExtension == "jsonl" }
            .filter { url in
                guard let cutoff = modifiedAfter else { return true }
                let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate
                return (modified ?? .distantFuture) >= cutoff
            }
    }
}

enum ISO8601 {
    // Value types, so they are Sendable — unlike ISO8601DateFormatter.
    private static let withFraction = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let plain = Date.ISO8601FormatStyle(includingFractionalSeconds: false)

    /// Both CLIs emit fractional seconds today, but neither documents it.
    static func parse(_ string: String) -> Date? {
        (try? withFraction.parse(string)) ?? (try? plain.parse(string))
    }
}

extension Data {
    /// Cheap substring test used to skip JSON decoding on lines that cannot
    /// possibly carry usage. Decoding every line of every log is what makes a
    /// cold start slow; most lines are prompts and tool output.
    func containsBytes(of needle: String) -> Bool {
        range(of: Data(needle.utf8)) != nil
    }
}
