import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// CSV rendering of request rows (History › Export CSV).
enum RequestsCSV {
    /// Rows fetched per database round trip while exporting.
    static let pageSize = 5_000

    static let columns = [
        "started_at", "mac", "app", "process", "pid", "method", "host", "port", "remote_ip", "policy", "rule",
        "state", "in_bytes", "out_bytes", "duration_ms", "new", "url", "process_path", "row_id",
    ]

    static var header: String { columns.joined(separator: ",") + "\r\n" }

    /// One CSV line (RFC 4180, CRLF-terminated) for a request.
    static func line(for record: RequestRecord, appName: String?, deviceName: String?) -> String {
        let fields: [String] = [
            record.startedAt.formatted(timestampStyle),
            deviceName ?? "",
            appName ?? "",
            RequestsPresentation.processName(of: record) ?? "",
            record.pid.map(String.init) ?? "",
            record.method,
            record.host,
            record.port.map(String.init) ?? "",
            record.remoteIP ?? "",
            record.policyPath.joined(separator: " > "),
            record.rule ?? "",
            record.state.rawValue,
            String(record.inBytes),
            String(record.outBytes),
            record.duration.map { String(Int(($0 * 1000).rounded())) } ?? "",
            record.isNew ? "1" : "0",
            record.url ?? "",
            record.processPath ?? "",
            record.rowID.map(String.init) ?? "",
        ]
        return fields.map(escape).joined(separator: ",") + "\r\n"
    }

    /// The monitored app's name, else the name of the top-most bundle (as in the table's App column).
    static func appName(for record: RequestRecord, names: [AppID: String]) -> String? {
        if let id = record.appID, let name = names[id] { return name }
        guard let bundle = record.bundlePath, !bundle.isEmpty else { return nil }
        return URL(fileURLWithPath: bundle).deletingPathExtension().lastPathComponent
    }

    /// Quotes a field when it contains a comma, quote or line break, doubling embedded quotes.
    static func escape(_ field: String) -> String {
        guard field.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else { return field }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// `2026-10-24T14:32:27.130+08:00`
    private static let timestampStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true, timeZone: .current)
}

/// Everything the CSV writer needs, captured on the main actor when the export starts.
struct RequestsCSVSnapshot: Sendable {
    var query: RequestQuery
    var database: any TidemarkDatabase
    var appNames: [AppID: String]
    var deviceNames: [DeviceID: String]
}

/// The current History query as a document for `fileExporter`. Rows are streamed from PostgreSQL in pages
/// of `RequestsCSV.pageSize` while the file is written (see `RequestsCSVPager`), so exports of any size never
/// sit in memory.
final class RequestsCSVDocument: WritableDocument {
    static var writableContentTypes: [UTType] { [.commaSeparatedText] }

    private let snapshotValue: RequestsCSVSnapshot

    init(snapshot: RequestsCSVSnapshot) {
        snapshotValue = snapshot
    }

    func writer(configuration: sending WriteConfiguration) -> sending RequestsCSVWriter {
        RequestsCSVWriter()
    }

    @MainActor
    func snapshot(contentType: UTType) async throws -> sending RequestsCSVSnapshot {
        snapshotValue
    }
}

/// Writes a `RequestsCSVSnapshot` to disk, reporting progress per page.
struct RequestsCSVWriter: DocumentWriter {
    typealias Snapshot = RequestsCSVSnapshot

    @concurrent
    func write(snapshot: sending RequestsCSVSnapshot, to destination: sending URL, previous: sending RequestsCSVSnapshot?, progress: consuming Subprogress) async throws {
        var pager = RequestsCSVPager(query: snapshot.query, database: snapshot.database)
        let first = try await pager.first()
        // The total can be an estimate for very large results: progress never runs past it and is
        // completed when the last page is written.
        let total = max(Int(clamping: first.totalCount), first.rows.count)
        let manager = progress.start(totalCount: total)

        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }
        try handle.write(contentsOf: Data(RequestsCSV.header.utf8))

        var page = first.rows
        var reported = 0
        while !page.isEmpty {
            try Task.checkCancellation()
            var chunk = ""
            chunk.reserveCapacity(page.count * 160)
            for record in page {
                let app = RequestsCSV.appName(for: record, names: snapshot.appNames)
                chunk += RequestsCSV.line(for: record, appName: app, deviceName: snapshot.deviceNames[record.deviceID])
            }
            try handle.write(contentsOf: Data(chunk.utf8))
            let step = min(page.count, total - reported)
            manager.complete(count: step)
            reported += step

            guard let next = try await pager.next() else { break }
            page = next
        }
        if reported < total { manager.complete(count: total - reported) }
    }
}

/// Fetches an export's pages in newest-first order.
///
/// Each page continues from the last row written through `RequestQuery.before`, so requests recorded while
/// the export runs neither shift the pages nor repeat rows. A database that answers a cursor query with
/// rows that are not older than the cursor ignores it; the pager then continues with offsets. Either way only
/// rows strictly older than the last one written are returned, so no row is written twice.
struct RequestsCSVPager {
    private var query: RequestQuery
    private let database: any TidemarkDatabase
    /// Last row handed out; nil once it is unknown (the export ends).
    private var cursor: RequestCursor?
    /// Rows the database returned so far: the next page's offset when the cursor is ignored.
    private var fetched = 0
    private var lastPageFull = false
    private var usesCursor = true

    init(query: RequestQuery, database: any TidemarkDatabase, pageSize: Int = RequestsCSV.pageSize) {
        var query = query
        query.limit = pageSize
        query.offset = 0
        query.before = nil
        self.query = query
        self.database = database
    }

    /// The first page, with the total match count.
    mutating func first() async throws -> RequestPage {
        let page = try await database.queryRequests(query)
        accept(page.rows)
        cursor = RequestsCSV.cursor(after: page.rows)
        return page
    }

    /// The next page, or nil at the end.
    mutating func next() async throws -> [RequestRecord]? {
        while lastPageFull, let cursor {
            let rows: [RequestRecord]
            if usesCursor {
                query.before = cursor
                query.offset = 0
                let page = try await database.queryRequests(query).rows
                if let newest = page.first, !RequestsCSV.isOlder(newest, than: cursor) {
                    usesCursor = false
                    continue
                }
                rows = page
            } else {
                query.before = nil
                query.offset = fetched
                rows = try await database.queryRequests(query).rows
            }
            accept(rows)
            let fresh = rows.filter { RequestsCSV.isOlder($0, than: cursor) }
            if !fresh.isEmpty {
                self.cursor = RequestsCSV.cursor(after: fresh)
                return fresh
            }
        }
        return nil
    }

    private mutating func accept(_ rows: [RequestRecord]) {
        fetched += rows.count
        lastPageFull = rows.count == query.limit
    }
}

extension RequestsCSV {
    /// Keyset cursor at the last (oldest) row of a newest-first page; nil when that row has no row ID.
    static func cursor(after page: [RequestRecord]) -> RequestCursor? {
        guard let last = page.last, let rowID = last.rowID else { return nil }
        return RequestCursor(startedAt: last.startedAt, rowID: rowID)
    }

    /// `true` if `record` comes after `cursor` in the `(started_at, id)` newest-first order.
    static func isOlder(_ record: RequestRecord, than cursor: RequestCursor) -> Bool {
        if record.startedAt != cursor.startedAt { return record.startedAt < cursor.startedAt }
        guard let rowID = record.rowID else { return false }
        return rowID < cursor.rowID
    }
}
