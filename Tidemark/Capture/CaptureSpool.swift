import Foundation
import os

/// Request rows kept on disk while PostgreSQL is unreachable.
///
/// Rows are JSON lines in numbered segment files (`000001.jsonl`, `000002.jsonl`, …) under
/// `~/Library/Application Support/Tidemark/spool/`. Appends go to the newest segment; replay reads the
/// oldest one, and once the database accepted its rows the segment is deleted. When the spool grows past
/// `limit` rows the oldest segments are dropped whole (the spool may exceed the limit by less than one
/// segment, so trimming never rewrites a file).
///
/// Rows the server permanently rejects are appended to `rejected.jsonl` instead of being discarded.
///
/// Creating a spool touches nothing on disk; the existing segments are scanned on first use, so a large
/// spool left by an outage is counted by whoever uses it (the capture pipeline, off the main actor).
struct CaptureSpool {
    private struct Segment {
        var index: Int
        var lines: Int
    }

    /// The raw lines of one segment, decoded chunk by chunk during replay.
    struct SegmentLines {
        var id: Int
        var lines: [Data]
    }

    private static let log = Logger(subsystem: "io.tidemark.Tidemark", category: "capture")

    let directory: URL
    /// Maximum rows kept; the oldest segments are dropped beyond it.
    var limit: Int
    /// Maximum lines per segment (also capped at a tenth of `limit`).
    let segmentSize: Int
    /// `rejected.jsonl` is started over when it grows past this many bytes.
    let quarantineLimit: Int
    private var segments: [Segment] = []
    /// Index of the segment new rows are appended to.
    private var activeIndex = 1
    private var loaded = false
    private var rowCount = 0

    static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appending(path: "Library/Application Support")
        return base.appending(path: "Tidemark/spool", directoryHint: .isDirectory)
    }

    init(directory: URL = CaptureSpool.defaultDirectory, limit: Int, segmentSize: Int = 10_000, quarantineLimit: Int = 64 << 20) {
        self.directory = directory
        self.limit = max(1, limit)
        self.segmentSize = max(1, segmentSize)
        self.quarantineLimit = max(1, quarantineLimit)
    }

    /// Rows currently on disk.
    var count: Int {
        mutating get {
            loadIfNeeded()
            return rowCount
        }
    }

    var isEmpty: Bool {
        mutating get { count == 0 }
    }

    /// File of rows the server refused (one JSON line each).
    var quarantineURL: URL { directory.appending(path: "rejected.jsonl", directoryHint: .notDirectory) }

    /// Scans the segments left by a previous run.
    private mutating func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false))) ?? []
        let indexes = names.compactMap { name -> Int? in
            guard name.hasSuffix(".jsonl") else { return nil }
            return Int(name.dropLast(6))
        }.sorted()
        for index in indexes {
            let lines = Self.lineCount(at: Self.url(directory, index))
            if lines > 0 {
                segments.append(Segment(index: index, lines: lines))
                rowCount += lines
            } else {
                try? FileManager.default.removeItem(at: Self.url(directory, index))
            }
        }
        activeIndex = (segments.last?.index ?? 0) + 1
    }

    /// Lines per segment: small limits get small segments so whole-segment trimming stays close to the limit.
    private var effectiveSegmentSize: Int { min(segmentSize, max(1, limit / 10)) }

    /// Appends rows (oldest first) and drops the oldest segments beyond `limit`.
    mutating func append(_ rows: [RequestRecord]) throws {
        guard !rows.isEmpty else { return }
        loadIfNeeded()
        let encoder = JSONEncoder()
        let size = effectiveSegmentSize
        var pending = rows[...]
        while !pending.isEmpty {
            if segments.last?.index != activeIndex || (segments.last?.lines ?? 0) >= size {
                if let last = segments.last, last.index >= activeIndex { activeIndex = last.index + 1 }
                segments.append(Segment(index: activeIndex, lines: 0))
            }
            let room = max(1, size - segments[segments.count - 1].lines)
            let chunk = pending.prefix(room)
            pending = pending.dropFirst(chunk.count)
            var data = Data()
            for row in chunk {
                data.append(try encoder.encode(row))
                data.append(0x0A)
            }
            try Self.append(data, to: Self.url(directory, activeIndex))
            segments[segments.count - 1].lines += chunk.count
            rowCount += chunk.count
        }
        trimToLimit()
    }

    /// The raw lines of the oldest segment, sealing it first so new appends go elsewhere. A segment that
    /// vanished is forgotten; one that cannot be read is renamed to `*.unreadable` (kept for inspection)
    /// and skipped, so it never blocks the replay.
    mutating func openOldestSegment() -> SegmentLines? {
        loadIfNeeded()
        while let first = segments.first {
            if first.index == activeIndex { activeIndex += 1 }
            let url = Self.url(directory, first.index)
            do {
                let data = try Data(contentsOf: url, options: .alwaysMapped)
                let lines = data.split(separator: 0x0A, omittingEmptySubsequences: true)
                if lines.isEmpty {
                    removeSegment(first.index)
                    continue
                }
                return SegmentLines(id: first.index, lines: lines)
            } catch {
                if FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
                    Self.log.error("Spool segment \(first.index) is unreadable: \(error.localizedDescription, privacy: .public)")
                    let aside = url.deletingPathExtension().appendingPathExtension("unreadable")
                    try? FileManager.default.removeItem(at: aside)
                    try? FileManager.default.moveItem(at: url, to: aside)
                }
                rowCount -= first.lines
                segments.removeFirst()
            }
        }
        return nil
    }

    /// Decodes spooled lines; lines that are not valid rows are skipped.
    static func decode(_ lines: ArraySlice<Data>) -> [RequestRecord] {
        let decoder = JSONDecoder()
        return lines.compactMap { try? decoder.decode(RequestRecord.self, from: $0) }
    }

    /// Rows of the oldest segment (see `openOldestSegment`).
    mutating func oldestSegment() -> (id: Int, rows: [RequestRecord])? {
        guard let segment = openOldestSegment() else { return nil }
        return (segment.id, Self.decode(segment.lines[...]))
    }

    /// Deletes a replayed segment.
    mutating func removeSegment(_ id: Int) {
        guard let position = segments.firstIndex(where: { $0.index == id }) else { return }
        rowCount -= segments[position].lines
        segments.remove(at: position)
        try? FileManager.default.removeItem(at: Self.url(directory, id))
    }

    /// Deletes everything on disk.
    mutating func removeAll() {
        loadIfNeeded()
        for segment in segments { try? FileManager.default.removeItem(at: Self.url(directory, segment.index)) }
        segments.removeAll()
        rowCount = 0
    }

    /// Keeps rows the server refused in `rejected.jsonl` (started over past `quarantineLimit` bytes).
    mutating func quarantine(_ rows: [RequestRecord]) {
        guard !rows.isEmpty else { return }
        loadIfNeeded()
        let url = quarantineURL
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))[.size] as? Int) ?? 0
        if size > quarantineLimit {
            let previous = directory.appending(path: "rejected.1.jsonl", directoryHint: .notDirectory)
            try? FileManager.default.removeItem(at: previous)
            try? FileManager.default.moveItem(at: url, to: previous)
        }
        let encoder = JSONEncoder()
        var data = Data()
        for row in rows {
            guard let line = try? encoder.encode(row) else { continue }
            data.append(line)
            data.append(0x0A)
        }
        do {
            try Self.append(data, to: url)
        } catch {
            Self.log.error("Could not keep \(rows.count) rejected rows: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: Private

    /// Drops whole oldest segments while the rest still holds at least `limit` rows.
    private mutating func trimToLimit() {
        while segments.count > 1, let first = segments.first, rowCount - first.lines >= limit {
            removeSegment(first.index)
        }
    }

    private static func url(_ directory: URL, _ index: Int) -> URL {
        directory.appending(path: String(format: "%06d.jsonl", index), directoryHint: .notDirectory)
    }

    private static func append(_ data: Data, to url: URL) throws {
        if !FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
            // The directory may have been removed since the spool was scanned.
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
            return
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    private static func lineCount(at url: URL) -> Int {
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped) else { return 0 }
        return data.reduce(into: 0) { if $1 == 0x0A { $0 += 1 } }
    }
}
