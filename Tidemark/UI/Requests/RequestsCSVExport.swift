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
            record.processName,
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
/// of `RequestsCSV.pageSize` while the file is written, so exports of any size never sit in memory.
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
        var query = snapshot.query
        query.limit = RequestsCSV.pageSize
        query.offset = 0

        let first = try await snapshot.database.queryRequests(query)
        let total = Int(clamping: first.totalCount)
        let manager = progress.start(totalCount: max(total, first.rows.count))

        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }
        try handle.write(contentsOf: Data(RequestsCSV.header.utf8))

        var page = first.rows
        while !page.isEmpty {
            try Task.checkCancellation()
            var chunk = ""
            chunk.reserveCapacity(page.count * 160)
            for record in page {
                let app = RequestsCSV.appName(for: record, names: snapshot.appNames)
                chunk += RequestsCSV.line(for: record, appName: app, deviceName: snapshot.deviceNames[record.deviceID])
            }
            try handle.write(contentsOf: Data(chunk.utf8))
            manager.complete(count: page.count)

            query.offset += page.count
            guard page.count == query.limit, Int64(query.offset) < first.totalCount else { break }
            page = try await snapshot.database.queryRequests(query).rows
        }
    }
}
