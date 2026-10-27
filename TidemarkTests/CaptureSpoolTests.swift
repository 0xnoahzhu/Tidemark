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
        sidecar.saveSnapshot(CaptureStateSnapshot(savedAt: .distantPast, apps: [app], known: [app.id: ["domain:a.com"]]))
        let snapshot = try #require(sidecar.loadSnapshot())
        #expect(snapshot.apps == [app] && snapshot.known == [app.id: ["domain:a.com"]])

        // An earlier version also saved its mute patterns: the file still loads, without them.
        var saved = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: sidecar.snapshotURL)) as? [String: Any])
        saved["mutes"] = ["*.apple.com", "*.icloud.com", "*.mzstatic.com"]
        try JSONSerialization.data(withJSONObject: saved).write(to: sidecar.snapshotURL)
        let earlier = try #require(sidecar.loadSnapshot())
        #expect(earlier.apps == [app] && earlier.known == [app.id: ["domain:a.com"]])

        var batch = CaptureWriteBuffer.Batch()
        batch.newHosts = [AppHost(appID: app.id, kind: .domain, value: "a.com", site: "a.com", firstSeen: .distantPast, lastSeen: .distantPast,
                                  requestCount: 1, processName: "node", policy: nil, geo: nil, isDirect: false, hosts: [], firstDeviceID: device)]
        // Two apps' sources of one process stay apart, each app's row counting its own requests.
        let other = UUID()
        batch.sources = [other, app.id].map { appID in
            HostSourceTouch(kind: .domain, value: "a.com", deviceID: device, sourcePath: "/usr/bin/curl", sourceTitle: "curl",
                            appID: appID, bundlePath: nil, seenAt: .distantPast, requestDelta: 1, geo: nil)
        }
        sidecar.saveAuxiliary(batch)
        sidecar.saveAuxiliary(batch)
        let restored = try #require(sidecar.takeAuxiliary())
        #expect(restored.newHosts.count == 2 && restored.newHosts.first?.firstDeviceID == device)
        #expect(restored.sources.first?.sourcePath == "/usr/bin/curl")
        #expect(restored.sources.map(\.appID) == [other, app.id, other, app.id])
        #expect(sidecar.takeAuxiliary() == nil, "taken once")
    }

    /// A row as Tidemark 0.3 (schema 3) spooled it: `RequestRecord` without the request details of schema v4.
    static let previousBuildLine = #"""
    {"completedAt":814700301.8445439,"pid":21046,"interface":"en0","notes":["02:38:21.255251 [Connection] Handled by VIF","02:38:21.844495 [Connection] Disconnect: TCP error: Connection reset."],"remoteIP":"203.0.113.80","remoteAddress":"203.0.113.10 (Proxy)","inBytes":4135,"localAddress":"10.1.2.133:52068","url":"collect.moomoo.com:443","key":{"deviceID":"6F0C2A8E-1B7D-4E55-9A51-2C3D4E5F6071","session":1792921314590,"surgeID":61456},"policyPath":["AI","US-Hysteria2"],"state":"completed","geo":{"organization":"Cloudflare, Inc.","asn":13335,"countryCode":"US"},"port":443,"startedAt":814700301.2552519,"host":"collect.moomoo.com","setupCompletedAt":814700301.2568312,"rule":"Global · AI","chain":[{"startTime":814692800.5,"path":"\/Applications\/moomoo.app\/Contents\/MacOS\/moomoo","name":"moomoo","pid":21046}],"outBytes":1691,"bundlePath":"\/Applications\/moomoo.app","processPath":"\/Applications\/moomoo.app\/Contents\/MacOS\/moomoo","isNew":false,"method":"HTTPS"}
    """#

    @Test func replaysRowsThePreviousBuildSpooled() throws {
        let temp = CaptureTempDirectory()
        try Data((Self.previousBuildLine + "\n").utf8).write(to: temp.url.appending(path: "000001.jsonl"))
        var spool = CaptureSpool(directory: temp.url, limit: 1000)
        let found = spool.count
        #expect(found == 1)
        let oldest = spool.oldestSegment()
        let segment = try #require(oldest)
        let row = try #require(segment.rows.first, "a row without the new fields still decodes")
        #expect(row.key.surgeID == 61456 && row.host == "collect.moomoo.com" && row.state == .completed)
        #expect(row.startedAt == Date(timeIntervalSince1970: 1793007501.255252))
        #expect(row.chain.first?.name == "moomoo" && row.geo?.asn == 13335 && row.notes.count == 2)
        #expect(row.timing == nil && row.entryMode == nil && row.originalPolicy == nil && row.modified == nil)
        #expect(row.endReason == nil && row.remoteIPSource == nil && row.remoteIPResolvedAt == nil)

        // And a row of this build round-trips its details.
        var detailed = row
        detailed.timing = [RequestTimingRecord(name: "Rule Evaluating", duration: 0.0004)]
        detailed.entryMode = 40
        detailed.endReason = "TCP error: Connection reset"
        detailed.remoteIPSource = .tidemarkLookup
        detailed.remoteIPResolvedAt = row.startedAt
        try spool.append([detailed])
        spool.removeSegment(segment.id)
        let replayed = spool.oldestSegment()?.rows
        #expect(replayed == [detailed])
    }

    @Test func keepsDNSAnswersAcrossAQuitWithoutDatabase() throws {
        let temp = CaptureTempDirectory()
        let sidecar = CaptureSidecar(directory: temp.url)
        let earlier = UUID()
        var batch = CaptureWriteBuffer.Batch()
        batch.dnsAnswers = [DNSAnswer(deviceID: earlier, domain: "proxycheck.io", resolvedAt: Date(timeIntervalSince1970: 1_793_000_000),
                                      server: "https://cloudflare-dns.com/dns-query", addresses: ["104.26.8.187"], byTidemark: true)]
        sidecar.saveAuxiliary(batch)
        sidecar.saveAuxiliary(batch)
        let restored = try #require(sidecar.takeAuxiliary())
        #expect(restored.dnsAnswers.count == 2 && restored.dnsAnswers.first == batch.dnsAnswers.first)
        #expect(restored.recorded(as: device).dnsAnswers.allSatisfy { $0.deviceID == device }, "written under this Mac's current ID")
        #expect(restored.deviceIDs == [earlier])

        // A file of an earlier version has no DNS answers.
        batch = CaptureWriteBuffer.Batch()
        batch.sources = [HostSourceTouch(kind: .domain, value: "a.com", deviceID: device, sourcePath: "/usr/bin/curl", sourceTitle: "curl",
                                         appID: nil, bundlePath: nil, seenAt: .distantPast, requestDelta: 1, geo: nil)]
        sidecar.saveAuxiliary(batch)
        let saved = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: sidecar.auxiliaryURL)) as? [String: Any])
        #expect(saved["dnsAnswers"] == nil)
        #expect(sidecar.takeAuxiliary()?.sources.count == 1)
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
