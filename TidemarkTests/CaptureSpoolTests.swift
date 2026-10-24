import Foundation
import Testing
@testable import Tidemark

struct CaptureSpoolTests {
    let device = UUID()

    func rows(_ ids: ClosedRange<Int64>) -> [RequestRecord] {
        ids.map { id in
            RequestRecord(
                key: RequestKey(deviceID: device, session: 7, surgeID: id), rowID: nil, startedAt: Date(timeIntervalSince1970: 1_792_000_000 + Double(id)),
                setupCompletedAt: nil, completedAt: nil, method: "HTTPS", host: "h\(id).example.com", port: 443, url: nil,
                remoteIP: "203.0.113.\(id % 250)", remoteAddress: nil, geo: GeoInfo(countryCode: "US", asn: 1, organization: "X"),
                policyPath: ["AI", "US"], rule: "FINAL", state: .completed, inBytes: id, outBytes: 1, pid: 3, processPath: "/usr/bin/curl",
                bundlePath: "/usr/bin/curl", chain: [ProcessLink(name: "curl", pid: 3, path: "/usr/bin/curl", startTime: nil)], appID: nil,
                localAddress: nil, interface: "en0", notes: ["12:00:00.000001 [Rule] Rule matched: FINAL"], isNew: false, writtenAt: nil,
                probeSessionID: nil
            )
        }
    }

    @Test func roundTripsRowsInOrder() throws {
        let temp = CaptureTempDirectory()
        var spool = CaptureSpool(directory: temp.url, limit: 1000, segmentSize: 4)
        try spool.append(rows(1...10))
        let written = spool.count
        #expect(written == 10)

        var replayed: [RequestRecord] = []
        while let segment = spool.oldestSegment() {
            replayed.append(contentsOf: segment.rows)
            spool.removeSegment(segment.id)
        }
        #expect(replayed == rows(1...10))
        let drained = spool.isEmpty
        #expect(drained)
    }

    @Test func survivesARelaunch() throws {
        let temp = CaptureTempDirectory()
        do {
            var spool = CaptureSpool(directory: temp.url, limit: 1000, segmentSize: 3)
            try spool.append(rows(1...5))
        }
        var reopened = CaptureSpool(directory: temp.url, limit: 1000, segmentSize: 3)
        let found = reopened.count
        #expect(found == 5)
        try reopened.append(rows(6...6))
        var ids: [Int64] = []
        while let segment = reopened.oldestSegment() {
            ids += segment.rows.map(\.key.surgeID)
            reopened.removeSegment(segment.id)
        }
        #expect(ids == [1, 2, 3, 4, 5, 6])
    }

    @Test func dropsTheOldestRowsBeyondTheLimit() throws {
        let temp = CaptureTempDirectory()
        var spool = CaptureSpool(directory: temp.url, limit: 5, segmentSize: 3)
        try spool.append(rows(1...4))
        try spool.append(rows(5...8))
        let kept = spool.count
        #expect(kept == 5)
        var ids: [Int64] = []
        while let segment = spool.oldestSegment() {
            ids += segment.rows.map(\.key.surgeID)
            spool.removeSegment(segment.id)
        }
        #expect(ids == [4, 5, 6, 7, 8])
    }

    @Test func trimsWholeSegmentsWithoutRewritingFiles() throws {
        let temp = CaptureTempDirectory()
        var spool = CaptureSpool(directory: temp.url, limit: 100, segmentSize: 50)
        try spool.append(rows(1...150))
        let kept = spool.count
        #expect(kept == 100)
        var ids: [Int64] = []
        while let segment = spool.oldestSegment() {
            ids += segment.rows.map(\.key.surgeID)
            spool.removeSegment(segment.id)
        }
        #expect(ids == Array(51...150))
    }

    @Test func skipsAnUnreadableSegment() throws {
        let temp = CaptureTempDirectory()
        var spool = CaptureSpool(directory: temp.url, limit: 1000, segmentSize: 3)
        try spool.append(rows(1...6))
        let first = temp.url.appending(path: "000001.jsonl")
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: first.path(percentEncoded: false))
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: temp.url.appending(path: "000001.unreadable").path(percentEncoded: false)) }

        let opened = spool.openOldestSegment()
        let segment = try #require(opened)
        #expect(CaptureSpool.decode(segment.lines[...]).map(\.key.surgeID) == [4, 5, 6])
        let left = spool.count
        #expect(left == 3)
        #expect(FileManager.default.fileExists(atPath: temp.url.appending(path: "000001.unreadable").path(percentEncoded: false)), "kept aside")
    }

    @Test func keepsRejectedRowsAside() throws {
        let temp = CaptureTempDirectory()
        var spool = CaptureSpool(directory: temp.url, limit: 1000)
        spool.quarantine(rows(1...2))
        spool.quarantine(rows(3...3))
        let text = try String(contentsOf: spool.quarantineURL, encoding: .utf8)
        #expect(text.split(separator: "\n").count == 3)
        let empty = spool.isEmpty
        #expect(empty, "rejected rows are not replayed")
    }

    @Test func savesSharedStateAndFirstContactWork() throws {
        let temp = CaptureTempDirectory()
        let sidecar = CaptureSidecar(directory: temp.url)
        let app = CaptureFixtures.app("Raycast", path: "/Applications/Raycast.app")
        sidecar.saveSnapshot(CaptureStateSnapshot(savedAt: .distantPast, apps: [app], mutes: ["*.example.com"], known: [app.id: ["domain:a.com"]]))
        let snapshot = try #require(sidecar.loadSnapshot())
        #expect(snapshot.apps == [app] && snapshot.mutes == ["*.example.com"] && snapshot.known == [app.id: ["domain:a.com"]])

        var batch = CaptureWriteBuffer.Batch()
        batch.newHosts = [AppHost(appID: app.id, kind: .domain, value: "a.com", site: "a.com", firstSeen: .distantPast, lastSeen: .distantPast,
                                  requestCount: 1, processName: "node", policy: nil, geo: nil, isDirect: false, hosts: [], firstDeviceID: device)]
        batch.sources = [HostSourceTouch(kind: .domain, value: "a.com", deviceID: device, sourcePath: "/usr/bin/curl", sourceTitle: "curl",
                                         appID: app.id, bundlePath: nil, seenAt: .distantPast, requestDelta: 1, geo: nil)]
        sidecar.saveAuxiliary(batch)
        sidecar.saveAuxiliary(batch)
        let restored = try #require(sidecar.takeAuxiliary())
        #expect(restored.newHosts.count == 2 && restored.newHosts.first?.firstDeviceID == device)
        #expect(restored.sources.first?.sourcePath == "/usr/bin/curl")
        #expect(sidecar.takeAuxiliary() == nil, "taken once")
    }

    @Test func appendsDuringReplayGoToANewSegment() throws {
        let temp = CaptureTempDirectory()
        var spool = CaptureSpool(directory: temp.url, limit: 100, segmentSize: 50)
        try spool.append(rows(1...3))
        let oldest = spool.oldestSegment()
        let segment = try #require(oldest)
        try spool.append(rows(4...5))
        spool.removeSegment(segment.id)
        let left = spool.count
        #expect(left == 2)
        let remaining = spool.oldestSegment()?.rows.map(\.key.surgeID)
        #expect(remaining == [4, 5])
    }
}
