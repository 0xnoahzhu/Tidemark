import Foundation
import os

/// Shared state saved locally so capture keeps attributing requests and detecting first contact when
/// PostgreSQL is unreachable at launch: the app catalog and every app's inventory. (A file of an earlier version
/// also holds mute patterns, which decoding ignores: Tidemark has no mutes.)
struct CaptureStateSnapshot: Codable, Sendable {
    var savedAt: Date
    /// Every app, archived ones included.
    var apps: [MonitoredApp]
    /// appID → `domain:x` / `ip:x` (the form `CaptureKnownHosts(loaded:)` reads).
    var known: [AppID: Set<String>]
}

/// `HostSourceTouch` as stored in the sidecar file.
struct CaptureSourceRecord: Codable, Hashable, Sendable {
    var kind: HostKind
    var value: String
    var deviceID: DeviceID
    var sourcePath: String
    var sourceTitle: String
    var appID: AppID?
    var bundlePath: String?
    var seenAt: Date
    var requestDelta: Int64
    var geo: GeoInfo?

    init(_ touch: HostSourceTouch) {
        kind = touch.kind
        value = touch.value
        deviceID = touch.deviceID
        sourcePath = touch.sourcePath
        sourceTitle = touch.sourceTitle
        appID = touch.appID
        bundlePath = touch.bundlePath
        seenAt = touch.seenAt
        requestDelta = touch.requestDelta
        geo = touch.geo
    }

    var touch: HostSourceTouch {
        HostSourceTouch(kind: kind, value: value, deviceID: deviceID, sourcePath: sourcePath, sourceTitle: sourceTitle,
                        appID: appID, bundlePath: bundlePath, seenAt: seenAt, requestDelta: requestDelta, geo: geo)
    }
}

/// First-contact work (inventory entries, alert drafts, touches, sources, process chains, alerts) that
/// was still queued when Tidemark quit without a database; written after the next launch's spool replay.
struct CaptureAuxiliaryFile: Codable, Sendable {
    var chains: [CaptureWriteBuffer.ChainWrite] = []
    var newHosts: [AppHost] = []
    var drafts: [CaptureAlertDraft] = []
    var touches: [AppHost] = []
    var sources: [CaptureSourceRecord] = []
    var alerts: [AlertItem] = []

    init(_ batch: CaptureWriteBuffer.Batch) {
        chains = batch.chains
        newHosts = batch.newHosts
        drafts = batch.drafts
        touches = batch.touches
        sources = batch.sources.map(CaptureSourceRecord.init)
        alerts = batch.alerts
    }

    var batch: CaptureWriteBuffer.Batch {
        var batch = CaptureWriteBuffer.Batch()
        batch.chains = chains
        batch.newHosts = newHosts
        batch.drafts = drafts
        batch.touches = touches
        batch.sources = sources.map(\.touch)
        batch.alerts = alerts
        return batch
    }

    mutating func append(_ other: CaptureAuxiliaryFile, limit: Int) {
        chains = Array((chains + other.chains).prefix(limit))
        newHosts = Array((newHosts + other.newHosts).prefix(limit))
        drafts = Array((drafts + other.drafts).prefix(limit))
        touches = Array((touches + other.touches).prefix(limit))
        sources = Array((sources + other.sources).prefix(limit))
        alerts = Array((alerts + other.alerts).prefix(limit))
    }
}

/// Files kept next to the spool segments: `shared-state.json` (the last loaded shared state) and
/// `auxiliary.json` (first-contact work waiting for the database). Neither name ends in `.jsonl`, so
/// the spool never mistakes them for segments.
struct CaptureSidecar: Sendable {
    let directory: URL
    /// Cap per queue in `auxiliary.json`.
    let auxiliaryLimit: Int

    private static let log = Logger(subsystem: "io.tidemark.Tidemark", category: "capture")

    init(directory: URL, auxiliaryLimit: Int = 50_000) {
        self.directory = directory
        self.auxiliaryLimit = auxiliaryLimit
    }

    var snapshotURL: URL { directory.appending(path: "shared-state.json", directoryHint: .notDirectory) }
    var auxiliaryURL: URL { directory.appending(path: "auxiliary.json", directoryHint: .notDirectory) }

    func saveSnapshot(_ snapshot: CaptureStateSnapshot) {
        write(snapshot, to: snapshotURL)
    }

    func loadSnapshot() -> CaptureStateSnapshot? {
        read(CaptureStateSnapshot.self, from: snapshotURL)
    }

    /// Adds `batch`'s auxiliary work to `auxiliary.json` (request rows are ignored; they go to the spool).
    func saveAuxiliary(_ batch: CaptureWriteBuffer.Batch) {
        guard !batch.auxiliaryIsEmpty else { return }
        var file = read(CaptureAuxiliaryFile.self, from: auxiliaryURL) ?? CaptureAuxiliaryFile(CaptureWriteBuffer.Batch())
        file.append(CaptureAuxiliaryFile(batch), limit: auxiliaryLimit)
        write(file, to: auxiliaryURL)
    }

    /// Reads and deletes `auxiliary.json`.
    func takeAuxiliary() -> CaptureWriteBuffer.Batch? {
        guard FileManager.default.fileExists(atPath: auxiliaryURL.path(percentEncoded: false)) else { return nil }
        let file = read(CaptureAuxiliaryFile.self, from: auxiliaryURL)
        try? FileManager.default.removeItem(at: auxiliaryURL)
        guard let batch = file?.batch, !batch.auxiliaryIsEmpty else { return nil }
        return batch
    }

    private func write<T: Encodable>(_ value: T, to url: URL) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(value).write(to: url, options: .atomic)
        } catch {
            Self.log.error("Could not save \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    private func read<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            Self.log.error("Ignoring unreadable \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
