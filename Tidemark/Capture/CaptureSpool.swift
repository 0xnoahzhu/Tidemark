import Foundation

/// Request rows kept on disk while PostgreSQL is unreachable.
///
/// Rows are JSON lines in numbered segment files (`000001.jsonl`, `000002.jsonl`, …) under
/// `~/Library/Application Support/Tidemark/spool/`. Appends go to the newest segment; replay reads the
/// oldest one, and once the database accepted its rows the segment is deleted. When the spool grows past
/// `limit` rows the oldest rows are dropped.
///
/// Creating a spool touches nothing on disk; the existing segments are scanned on first use, so a large
/// spool left by an outage is counted by whoever uses it (the capture pipeline, off the main actor).
struct CaptureSpool {
    private struct Segment {
        var index: Int
        var lines: Int
    }

    let directory: URL
    /// Maximum rows kept; the oldest are dropped beyond it.
    var limit: Int
    let segmentSize: Int
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

    init(directory: URL = CaptureSpool.defaultDirectory, limit: Int, segmentSize: Int = 10_000) {
        self.directory = directory
        self.limit = max(1, limit)
        self.segmentSize = max(1, segmentSize)
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

    /// Appends rows (oldest first) and drops the oldest rows beyond `limit`.
    mutating func append(_ rows: [RequestRecord]) throws {
        guard !rows.isEmpty else { return }
        loadIfNeeded()
        let encoder = JSONEncoder()
        var pending = rows[...]
        while !pending.isEmpty {
            if segments.last?.index != activeIndex || (segments.last?.lines ?? 0) >= segmentSize {
                if let last = segments.last, last.index >= activeIndex { activeIndex = last.index + 1 }
                segments.append(Segment(index: activeIndex, lines: 0))
            }
            let room = segmentSize - segments[segments.count - 1].lines
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
        try trimToLimit()
    }

    /// Rows of the oldest segment, sealing it first so new appends go elsewhere. Unreadable lines are skipped.
    mutating func oldestSegment() -> (id: Int, rows: [RequestRecord])? {
        loadIfNeeded()
        guard let first = segments.first else { return nil }
        if first.index == activeIndex { activeIndex += 1 }
        let decoder = JSONDecoder()
        guard let data = try? Data(contentsOf: Self.url(directory, first.index)) else { return (first.index, []) }
        let rows = data.split(separator: 0x0A).compactMap { try? decoder.decode(RequestRecord.self, from: Data($0)) }
        return (first.index, rows)
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

    // MARK: Private

    private mutating func trimToLimit() throws {
        while rowCount > limit, let first = segments.first {
            let excess = rowCount - limit
            if first.lines <= excess {
                removeSegment(first.index)
                continue
            }
            // Keep the newest lines of the oldest segment.
            let url = Self.url(directory, first.index)
            let data = try Data(contentsOf: url)
            let lines = data.split(separator: 0x0A, omittingEmptySubsequences: true)
            var kept = Data()
            for line in lines.dropFirst(excess) {
                kept.append(contentsOf: line)
                kept.append(0x0A)
            }
            try kept.write(to: url, options: .atomic)
            segments[0].lines = lines.count - excess
            rowCount -= min(excess, lines.count)
        }
    }

    private static func url(_ directory: URL, _ index: Int) -> URL {
        directory.appending(path: String(format: "%06d.jsonl", index), directoryHint: .notDirectory)
    }

    private static func append(_ data: Data, to url: URL) throws {
        if !FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
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
