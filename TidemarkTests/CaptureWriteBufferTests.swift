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

    /// A process two apps ran to one address is queued once per app, so each app's own row counts its own requests;
    /// `touchHostSources` adds them up for the shared row.
    @Test func keepsEachAppsSourcesOfAProcessApart() {
        var buffer = CaptureWriteBuffer(batchRows: 10, batchInterval: 1, now: start)
        let cursor = UUID(), raycast = UUID()
        func curl(_ app: AppID?, at seconds: TimeInterval) -> HostSourceTouch {
            HostSourceTouch(kind: .domain, value: "api.github.com", deviceID: device, sourcePath: "/usr/bin/curl", sourceTitle: "curl",
                            appID: app, bundlePath: nil, seenAt: start.addingTimeInterval(seconds), requestDelta: 1, geo: nil)
        }
        for touch in [curl(cursor, at: 1), curl(raycast, at: 2), curl(cursor, at: 3), curl(nil, at: 4), curl(cursor, at: 5)] {
            buffer.add(source: touch)
        }
        let sources = buffer.takeAll(now: start).sources
        #expect(sources.map(\.appID) == [cursor, raycast, nil])
        #expect(sources.map(\.requestDelta) == [3, 1, 1])
        #expect(sources[0].seenAt == start.addingTimeInterval(5))

        // Written: one shared row, under the app that used the process last, and one row per app.
        let writes = PostgresDatabase.hostSourceWrites(sources)
        #expect(writes.count == 1)
        #expect(writes.first?.source.touch.appID == cursor && writes.first?.source.touch.requestDelta == 5)
        #expect(Set(writes.first?.apps.map { "\($0.touch.appID!) \($0.touch.requestDelta)" } ?? []) == ["\(cursor) 3", "\(raycast) 1"])
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

    @Test func purgesADeletedApp() {
        var buffer = CaptureWriteBuffer(batchRows: 10, batchInterval: 1, now: start)
        let app = UUID()
        var linked = row(1)
        linked.appID = app
        linked.isNew = true
        buffer.add(request: linked)
        buffer.add(chain: [ProcessLink(name: "node", pid: 1, path: nil, startTime: start)], appID: app)
        let host = AppHost(appID: app, kind: .domain, value: "a.com", site: "a.com", firstSeen: start, lastSeen: start, requestCount: 1,
                           processName: "node", policy: nil, geo: nil, isDirect: false, hosts: [])
        let draft = CaptureAlertDraft(appID: app, kind: .domain, scope: .site, value: "a.com", site: "a.com", host: "a.com", ip: nil, geo: nil,
                                      processName: "node", isDirect: false, requestKey: linked.key)
        buffer.add(CaptureFirstContact(hosts: [host], touches: [host], alert: draft))
        buffer.add(source: HostSourceTouch(kind: .domain, value: "a.com", deviceID: device, sourcePath: "/x", sourceTitle: "x", appID: app,
                                           bundlePath: nil, seenAt: start, requestDelta: 1, geo: nil))

        buffer.purge(appID: app)
        let batch = buffer.takeAll(now: start)
        #expect(batch.requests.first?.appID == nil && batch.requests.first?.isNew == false)
        #expect(batch.chains.first?.appID == nil)
        #expect(batch.newHosts.isEmpty && batch.drafts.isEmpty && batch.touches.isEmpty)
        #expect(batch.sources.count == 1 && batch.sources[0].appID == nil)
    }

    @Test func capsInventoryEntriesTogetherWithTheirDrafts() {
        var buffer = CaptureWriteBuffer(batchRows: 10, batchInterval: 1, auxiliaryLimit: 3, now: start)
        let app = UUID()
        func contact(_ host: String) -> CaptureFirstContact {
            let key = RequestKey(deviceID: device, session: 1, surgeID: 1)
            let domain = AppHost(appID: app, kind: .domain, value: host, site: host, firstSeen: start, lastSeen: start, requestCount: 1,
                                 processName: "p", policy: nil, geo: nil, isDirect: false, hosts: [])
            var ip = domain
            ip.kind = .ip
            ip.value = "10.0.0.1"
            let draft = CaptureAlertDraft(appID: app, kind: .domain, scope: .site, value: host, site: host, host: host, ip: nil, geo: nil,
                                          processName: "p", isDirect: false, requestKey: key)
            return CaptureFirstContact(hosts: [domain, ip], touches: [], alert: draft)
        }
        buffer.add(contact("a.com"))
        buffer.add(contact("b.com"))
        let batch = buffer.takeAll(now: start)
        #expect(batch.newHosts.count == 2)
        #expect(batch.drafts.map(\.value) == ["a.com"], "no draft without its entries")
    }

    @Test func capsAuxiliaryQueues() {
        var buffer = CaptureWriteBuffer(batchRows: 10, batchInterval: 1, auxiliaryLimit: 2, now: start)
        for pid in 1...5 { buffer.add(chain: [ProcessLink(name: "p", pid: Int32(pid), path: nil, startTime: start)], appID: nil) }
        #expect(buffer.takeAll(now: start).chains.count == 2)
    }
}
