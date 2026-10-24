import Foundation
import Testing
@testable import Tidemark

struct CaptureWriteBufferTests {
    let device = UUID()
    let start = Date(timeIntervalSince1970: 1_792_000_000)

    func row(_ id: Int64, state: RequestState = .active) -> RequestRecord {
        RequestRecord(
            key: RequestKey(deviceID: device, session: 1, surgeID: id), rowID: nil, startedAt: start, setupCompletedAt: nil,
            completedAt: nil, method: "HTTPS", host: "h\(id).example.com", port: 443, url: nil, remoteIP: nil, remoteAddress: nil,
            geo: nil, policyPath: ["DIRECT"], rule: nil, state: state, inBytes: 0, outBytes: 0, pid: nil, processPath: nil,
            bundlePath: nil, chain: [], appID: nil, localAddress: nil, interface: nil, notes: [], isNew: false, writtenAt: nil,
            probeSessionID: nil
        )
    }

    @Test func flushesAfterBatchRows() {
        var buffer = CaptureWriteBuffer(batchRows: 3, batchInterval: 60, now: start)
        buffer.add(request: row(1))
        buffer.add(request: row(2))
        #expect(!buffer.shouldFlush(now: start))
        buffer.add(request: row(3))
        #expect(buffer.shouldFlush(now: start))
    }

    @Test func flushesAfterTheInterval() {
        var buffer = CaptureWriteBuffer(batchRows: 200, batchInterval: 1, now: start)
        #expect(!buffer.shouldFlush(now: start.addingTimeInterval(5)), "nothing queued")
        buffer.add(request: row(1))
        #expect(!buffer.shouldFlush(now: start.addingTimeInterval(0.5)))
        #expect(buffer.shouldFlush(now: start.addingTimeInterval(1)))
        _ = buffer.takeAll(now: start.addingTimeInterval(1))
        buffer.add(request: row(2))
        #expect(!buffer.shouldFlush(now: start.addingTimeInterval(1.5)), "the interval restarts with each flush")
    }

    @Test func coalescesRowsByKeyKeepingOrder() {
        var buffer = CaptureWriteBuffer(batchRows: 10, batchInterval: 1, now: start)
        buffer.add(request: row(1))
        buffer.add(request: row(2))
        buffer.add(request: row(1, state: .completed))
        #expect(buffer.requestCount == 2)
        let batch = buffer.takeAll(now: start)
        #expect(batch.requests.map(\.key.surgeID) == [1, 2])
        #expect(batch.requests.first?.state == .completed)
        #expect(buffer.isEmpty)
    }

    @Test func aggregatesTouchesAndSources() {
        var buffer = CaptureWriteBuffer(batchRows: 10, batchInterval: 1, now: start)
        let app = UUID()
        let touch = AppHost(appID: app, kind: .ip, value: "1.2.3.4", site: nil, firstSeen: start, lastSeen: start, requestCount: 1,
                            processName: "node", policy: "A", geo: nil, isDirect: false, hosts: ["a.com"])
        var later = touch
        later.lastSeen = start.addingTimeInterval(10)
        later.policy = "B"
        later.hosts = ["b.com"]
        buffer.add(touch: touch)
        buffer.add(touch: later)
        let source = HostSourceTouch(kind: .domain, value: "a.com", deviceID: device, sourcePath: "/usr/bin/curl", sourceTitle: "curl",
                                     appID: nil, bundlePath: nil, seenAt: start, requestDelta: 1, geo: nil)
        buffer.add(source: source)
        buffer.add(source: source)

        let batch = buffer.takeAll(now: start)
        #expect(batch.touches.count == 1)
        #expect(batch.touches[0].requestCount == 2)
        #expect(batch.touches[0].lastSeen == later.lastSeen)
        #expect(batch.touches[0].policy == "B")
        #expect(batch.touches[0].hosts == ["a.com", "b.com"])
        #expect(batch.sources.count == 1 && batch.sources[0].requestDelta == 2)
    }

    @Test func restoresAFailedBatchAheadOfNewWork() {
        var buffer = CaptureWriteBuffer(batchRows: 10, batchInterval: 1, now: start)
        buffer.add(chain: [ProcessLink(name: "a", pid: 1, path: nil, startTime: start)], appID: nil)
        let failed = buffer.takeAll(now: start)
        buffer.add(chain: [ProcessLink(name: "b", pid: 2, path: nil, startTime: start)], appID: nil)
        buffer.restore(failed)
        let batch = buffer.takeAll(now: start)
        #expect(batch.chains.map { $0.chain[0].name } == ["a", "b"])
    }

    @Test func capsAuxiliaryQueues() {
        var buffer = CaptureWriteBuffer(batchRows: 10, batchInterval: 1, auxiliaryLimit: 2, now: start)
        for pid in 1...5 { buffer.add(chain: [ProcessLink(name: "p", pid: Int32(pid), path: nil, startTime: start)], appID: nil) }
        #expect(buffer.takeAll(now: start).chains.count == 2)
    }
}
