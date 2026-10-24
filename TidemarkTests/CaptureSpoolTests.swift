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
