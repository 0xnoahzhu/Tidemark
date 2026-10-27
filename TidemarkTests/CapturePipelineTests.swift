import Foundation
import Testing
@testable import Tidemark

@Suite(.timeLimit(.minutes(1)))
struct CapturePipelineTests {
    let device = UUID()
    let ownExecutable = "/Applications/Tidemark.app/Contents/MacOS/Tidemark"
    let boot = Date(timeIntervalSince1970: 1_792_000_000)
    /// Later than any internal timer start, so intervals have always elapsed.
    let base = Date.now.addingTimeInterval(5)

    /// Raycast (540) → node (1388)
    var processes: CaptureFakeProcesses {
        CaptureFakeProcesses([
            LiveProcess(pid: 540, parentPID: 1, name: "Raycast", path: "/Applications/Raycast.app/Contents/MacOS/Raycast", startTime: boot),
            LiveProcess(pid: 1388, parentPID: 540, name: "node", path: "/Users/me/Library/Application Support/com.raycast.macos/node/bin/node",
                        startTime: boot.addingTimeInterval(5)),
        ])
    }

    func makePipeline(database: CaptureFakeDatabase, surge: CaptureFakeSurge, spoolDirectory: URL, probes: ProbeRegistry = ProbeRegistry(),
                      contactGrace: TimeInterval = 0.5) -> CapturePipeline {
        CapturePipeline(
            settings: CaptureSettings(deviceID: device, batchRows: 200, batchInterval: 1, ownExecutablePath: ownExecutable),
            database: database, surge: surge, processes: processes, classifier: CaptureFakeClassifier(), probes: probes,
            spool: CaptureSpool(directory: spoolDirectory, limit: 10_000), contactGrace: contactGrace
        )
    }

    /// Polls `condition` until it holds or the timeout passes.
    func eventually(_ timeout: Duration = .seconds(3), _ condition: () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return await condition()
    }

    func nodeRequest(id: Int64, host: String, remoteAddress: String?, completed: Bool = false) -> SurgeRequest {
        CaptureFixtures.request(id: id, host: host, processPath: "/Users/me/Library/Application Support/com.raycast.macos/node/bin/node",
                                pid: 1388, remoteAddress: remoteAddress, policy: "DIRECT", completed: completed)
    }

    @Test func recordsFirstContactAndWritesInOrder() async throws {
        let temp = CaptureTempDirectory()
        let database = CaptureFakeDatabase()
        let surge = CaptureFakeSurge()
        surge.update { $0.geo["104.18.22.110"] = SurgeGeoIP(address: "104.18.22.110", country: "US", asn: 13335, organization: "Cloudflare, Inc.") }
        let raycast = CaptureFixtures.app("Raycast", path: "/Applications/Raycast.app")
        await database.setKnown([raycast.id: ["backend.raycast.com"]])
        let pipeline = makePipeline(database: database, surge: surge, spoolDirectory: temp.url)
        await pipeline.setApps([raycast], paused: [])
        try await pipeline.loadKnownHosts()
        await pipeline.setDatabaseOnline(true)
        await pipeline.beginSession(1_000)

        await pipeline.ingest(nodeRequest(id: 1, host: "api.notion.com", remoteAddress: "104.18.22.110"), now: base)
        // GeoIP arrives asynchronously; the contact waits for it (or the grace period).
        #expect(await eventually { await pipeline.drainUpdate().records.contains { $0.geo != nil } })
        await pipeline.tick(now: base.addingTimeInterval(2))

        let chains = await database.chains
        #expect(chains.count == 1)
        #expect(chains.first?.appID == raycast.id)
        #expect(chains.first?.chain.map(\.name) == ["Raycast", "node"])

        let key = RequestKey(deviceID: device, session: 1_000, surgeID: 1)
        let written = await database.rows[key]
        #expect(written?.appID == raycast.id)
        #expect(written?.chain.count == 2)
        #expect(written?.bundlePath == "/Applications/Raycast.app")

        let hosts = await database.appHosts
        #expect(hosts.keys.sorted() == ["\(raycast.id.uuidString)|domain:api.notion.com", "\(raycast.id.uuidString)|ip:104.18.22.110"])

        let alerts = await database.alertsInserted
        #expect(alerts.count == 1)
        let alert = try #require(alerts.first)
        #expect(alert.scope == .site && alert.site == "notion.com" && alert.value == "api.notion.com")
        #expect(alert.geo?.display == "US · AS13335 Cloudflare")
        #expect(alert.processName == "node")
        #expect(alert.requestRowID == (await database.rowIDs[key]))
        #expect(alert.deviceID == device)

        let update = await pipeline.drainUpdate()
        #expect(update.alerts.map(\.id) == [alert.id])
        #expect(update.inventoryChanged == [raycast.id])
        #expect(update.records.first { $0.key == key }?.isNew == true)
        #expect(update.records.first { $0.key == key }?.rowID != nil)

        // The NEW flag is written on the next flush.
        await pipeline.tick(now: base.addingTimeInterval(4))
        #expect(await database.rows[key]?.isNew == true)

        let sources = await database.sources
        #expect(Set(sources.map(\.value)) == ["api.notion.com", "104.18.22.110"])
    }

    @Test func anotherMacWinningTheDomainLeavesOnlyTheIPAlert() async throws {
        let temp = CaptureTempDirectory()
        let database = CaptureFakeDatabase()
        let surge = CaptureFakeSurge()
        let raycast = CaptureFixtures.app("Raycast", path: "/Applications/Raycast.app")
        await database.preinsert(AppHost(appID: raycast.id, kind: .domain, value: "api.linear.app", site: "linear.app", firstSeen: boot,
                                         lastSeen: boot, requestCount: 1, processName: "node", policy: nil, geo: nil, isDirect: false, hosts: []))
        let pipeline = makePipeline(database: database, surge: surge, spoolDirectory: temp.url, contactGrace: 0)
        await pipeline.setApps([raycast], paused: [])
        try await pipeline.loadKnownHosts()
        await pipeline.setDatabaseOnline(true)

        await pipeline.ingest(nodeRequest(id: 5, host: "api.linear.app", remoteAddress: "10.0.0.8"), now: base)
        await pipeline.tick(now: base.addingTimeInterval(2))
        #expect(await database.appHosts.count == 2, "the IP is still new for this Mac")
        let alerts = await database.alertsInserted
        #expect(alerts.map(\.scope) == [.ip], "the other Mac alerted on the domain; this Mac's new IP alerts on its own")
        #expect(alerts.first?.value == "10.0.0.8" && alerts.first?.host == "api.linear.app")
    }

    @Test func pausedAppsAndArchivedAppsDontAlert() async throws {
        let temp = CaptureTempDirectory()
        let database = CaptureFakeDatabase()
        let raycast = CaptureFixtures.app("Raycast", path: "/Applications/Raycast.app")
        let pipeline = makePipeline(database: database, surge: CaptureFakeSurge(), spoolDirectory: temp.url, contactGrace: 0)
        await pipeline.setApps([raycast], paused: [raycast.id])
        try await pipeline.loadKnownHosts()
        await pipeline.setDatabaseOnline(true)

        await pipeline.ingest(nodeRequest(id: 1, host: "api.linear.app", remoteAddress: "10.0.0.8"), now: base)
        await pipeline.tick(now: base.addingTimeInterval(2))
        #expect(await database.appHosts.isEmpty)
        #expect(await database.alertsInserted.isEmpty)
        #expect(await database.rows.values.first?.appID == raycast.id, "paused apps still own their requests")
    }

    @Test func spoolsWhileOfflineAndReplaysInOrder() async throws {
        let temp = CaptureTempDirectory()
        let database = CaptureFakeDatabase()
        let pipeline = makePipeline(database: database, surge: CaptureFakeSurge(), spoolDirectory: temp.url)
        await pipeline.setDatabaseOnline(true)
        await database.setFailing(true)

        for id in 1...3 { await pipeline.ingest(CaptureFixtures.request(id: Int64(id), host: "h\(id).com", processPath: "/usr/bin/curl", remoteAddress: "10.0.0.\(id)", completed: true), now: base) }
        await pipeline.tick(now: base.addingTimeInterval(2))
        let failure = await pipeline.drainUpdate()
        #expect(failure.databaseFailure != nil)
        #expect(failure.bufferedRows == 3)
        #expect(await pipeline.isOnline == false)

        for id in 4...5 { await pipeline.ingest(CaptureFixtures.request(id: Int64(id), host: "h\(id).com", processPath: "/usr/bin/curl", remoteAddress: "10.0.0.\(id)", completed: true), now: base.addingTimeInterval(3)) }
        await pipeline.tick(now: base.addingTimeInterval(5))
        #expect(await pipeline.bufferedRows == 5)
        #expect(await database.writes.isEmpty)

        await database.setFailing(false)
        await pipeline.setDatabaseOnline(true)
        await pipeline.tick(now: base.addingTimeInterval(7))
        #expect(await database.writes.map(\.key.surgeID) == [1, 2, 3, 4, 5])
        let after = await pipeline.drainUpdate()
        #expect(after.bufferedRows == 0)
        #expect(after.rowsWritten == 5)
    }

    @Test func rewritesActiveRequestsPeriodicallyAndOnCompletion() async throws {
        let temp = CaptureTempDirectory()
        let database = CaptureFakeDatabase()
        let pipeline = makePipeline(database: database, surge: CaptureFakeSurge(), spoolDirectory: temp.url)
        await pipeline.setDatabaseOnline(true)

        var request = CaptureFixtures.request(id: 9, host: "example.com", processPath: "/usr/bin/curl", remoteAddress: "10.0.0.9")
        await pipeline.ingest(request, now: base)
        await pipeline.tick(now: base)
        #expect(await database.writes.count == 1, "written when first seen")

        request.inBytes = 4096
        await pipeline.ingest(request, now: base.addingTimeInterval(1))
        await pipeline.tick(now: base.addingTimeInterval(2))
        #expect(await database.writes.count == 1, "active rows wait about 10 s")
        await pipeline.tick(now: base.addingTimeInterval(11))
        #expect(await database.writes.count == 2)
        #expect(await database.writes.last?.inBytes == 4096)

        request.completed = true
        request.completedDate = request.startDate.map { $0 + 12 }
        await pipeline.ingest(request, now: base.addingTimeInterval(12))
        await pipeline.tick(now: base.addingTimeInterval(13.5))
        #expect(await database.writes.count == 3)
        #expect(await database.writes.last?.state == .completed)

        // Identical updates after completion write nothing.
        await pipeline.ingest(request, now: base.addingTimeInterval(14))
        await pipeline.tick(now: base.addingTimeInterval(16))
        #expect(await database.writes.count == 3)
    }

    @Test func resolvesProxiedHostnamesThroughSurge() async throws {
        let temp = CaptureTempDirectory()
        let surge = CaptureFakeSurge()
        surge.update { $0.dns["api.github.com"] = ["140.82.121.5"] }
        let pipeline = makePipeline(database: CaptureFakeDatabase(), surge: surge, spoolDirectory: temp.url)

        await pipeline.ingest(CaptureFixtures.request(id: 1, host: "api.github.com", processPath: "/usr/bin/git", remoteAddress: "23.254.139.175 (Proxy)"), now: base)
        #expect(await eventually { await pipeline.drainUpdate().records.contains { $0.remoteIP == "140.82.121.5" } })

        // Cached by TTL: the next request for the host needs no lookup.
        await pipeline.ingest(CaptureFixtures.request(id: 2, host: "api.github.com", processPath: "/usr/bin/git", remoteAddress: "23.254.139.175 (Proxy)"), now: base)
        let update = await pipeline.drainUpdate()
        #expect(update.records.first { $0.key.surgeID == 2 }?.remoteIP == "140.82.121.5")
        #expect(surge.snapshot.dnsLookups == ["api.github.com"])
    }

    @Test func usesSurgesDNSCache() async {
        let temp = CaptureTempDirectory()
        let surge = CaptureFakeSurge()
        surge.update { $0.dnsCache = [SurgeDNSRecord(domain: "registry.npmjs.org", addresses: ["104.16.27.34"], expires: base.addingTimeInterval(300))] }
        let pipeline = makePipeline(database: CaptureFakeDatabase(), surge: surge, spoolDirectory: temp.url)
        await pipeline.refreshDNSCache(now: base)
        await pipeline.ingest(CaptureFixtures.request(id: 1, host: "registry.npmjs.org", processPath: "/usr/local/bin/node", remoteAddress: "1.2.3.4 (Proxy)"), now: base)
        let record = await pipeline.drainUpdate().records.first
        #expect(record?.remoteIP == "104.16.27.34")
        #expect(record?.remoteIPSource == .surgeCache && record?.remoteIPResolvedAt == base, "first seen in Surge's cache now")
        #expect(surge.snapshot.dnsLookups.isEmpty)
    }

    @Test func neverUsesAnAnswerSurgesCacheHoldsPastItsExpiry() async throws {
        let temp = CaptureTempDirectory()
        let surge = CaptureFakeSurge()
        surge.update {
            $0.dnsCache = [
                // Expired an hour ago: Surge still lists it.
                SurgeDNSRecord(domain: "api.github.com", addresses: ["140.82.112.5"], expires: base.addingTimeInterval(-3_600)),
                SurgeDNSRecord(domain: "proxy.example.net", addresses: ["203.0.113.40"], isLocal: true),
                SurgeDNSRecord(domain: "github.com", addresses: ["140.82.112.3"], expires: base.addingTimeInterval(20)),
            ]
            $0.dns["api.github.com"] = ["140.82.112.6"]
            $0.dns["github.com"] = ["140.82.112.4"]
        }
        let pipeline = makePipeline(database: CaptureFakeDatabase(), surge: surge, spoolDirectory: temp.url)
        await pipeline.refreshDNSCache(now: base)
        func request(_ id: Int64, _ host: String) -> SurgeRequest {
            CaptureFixtures.request(id: id, host: host, processPath: "/usr/bin/git", remoteAddress: "203.0.113.10 (Proxy)")
        }

        // The expired answer is looked up afresh, and the request says so.
        await pipeline.ingest(request(1, "api.github.com"), now: base)
        var latest: [Int64: RequestRecord] = [:]
        #expect(await eventually {
            for record in await pipeline.drainUpdate().records { latest[record.key.surgeID] = record }
            return latest[1]?.remoteIP != nil
        })
        #expect(latest[1]?.remoteIP == "140.82.112.6" && latest[1]?.remoteIPSource == .tidemarkLookup)
        #expect(latest[1]?.remoteIPResolvedAt != nil)
        #expect(surge.snapshot.dnsLookups == ["api.github.com"])

        // A static mapping of Surge's profile has no resolution time and never expires.
        await pipeline.ingest(request(2, "proxy.example.net"), now: base.addingTimeInterval(86_400))
        // A cached answer is used until its expiry, not after.
        await pipeline.ingest(request(3, "github.com"), now: base.addingTimeInterval(10))
        for record in await pipeline.drainUpdate().records { latest[record.key.surgeID] = record }
        #expect(latest[2]?.remoteIP == "203.0.113.40" && latest[2]?.remoteIPSource == .surgeCache && latest[2]?.remoteIPResolvedAt == nil)
        #expect(latest[3]?.remoteIP == "140.82.112.3" && latest[3]?.remoteIPSource == .surgeCache)
        await pipeline.ingest(request(4, "github.com"), now: base.addingTimeInterval(21))
        #expect(await eventually {
            for record in await pipeline.drainUpdate().records { latest[record.key.surgeID] = record }
            return latest[4]?.remoteIP != nil
        })
        #expect(latest[4]?.remoteIP == "140.82.112.4" && latest[4]?.remoteIPSource == .tidemarkLookup)

        // Surge's record beats what Tidemark resolved: the address of a DIRECT connection, reported once it is set up.
        var direct = request(1, "api.github.com")
        direct.remoteAddress = "140.82.112.6"
        direct.setupCompletedDate = 1_792_871_000.25
        await pipeline.ingest(direct, now: base.addingTimeInterval(1))
        let updated = try #require(await pipeline.drainUpdate().records.first { $0.key.surgeID == 1 })
        #expect(updated.remoteIP == "140.82.112.6" && updated.remoteIPSource == .surge)
        #expect(updated.remoteIPResolvedAt == Date(timeIntervalSince1970: 1_792_871_000.25))
    }

    @Test func looksUpAHostWhoseCachedAnswerHasNoExpiry() async {
        let temp = CaptureTempDirectory()
        let surge = CaptureFakeSurge()
        surge.update {
            // No `expiresTime` Tidemark can read (another Surge version, say): not an answer that holds forever.
            $0.dnsCache = [SurgeDNSRecord(domain: "api.github.com", addresses: ["140.82.112.5"])]
            $0.dns["api.github.com"] = ["140.82.112.6"]
        }
        let pipeline = makePipeline(database: CaptureFakeDatabase(), surge: surge, spoolDirectory: temp.url)
        await pipeline.refreshDNSCache(now: base)
        await pipeline.ingest(CaptureFixtures.request(id: 1, host: "api.github.com", processPath: "/usr/bin/git", remoteAddress: "203.0.113.10 (Proxy)"),
                              now: base)
        var record: RequestRecord?
        #expect(await eventually {
            record = await pipeline.drainUpdate().records.last { $0.remoteIP != nil } ?? record
            return record != nil
        })
        #expect(record?.remoteIP == "140.82.112.6" && record?.remoteIPSource == .tidemarkLookup)
        #expect(surge.snapshot.dnsLookups == ["api.github.com"])
    }

    @Test func aLookedUpAnswerLastsAsLongAsSurgesCacheHoldsIt() async throws {
        let temp = CaptureTempDirectory()
        let surge = CaptureFakeSurge()
        // Surge's `dns lookup` reports `expires-in` 0, so Tidemark's own entry gets a minute.
        surge.update { $0.dns["api.anthropic.com"] = ["160.79.104.10"] }
        let pipeline = makePipeline(database: CaptureFakeDatabase(), surge: surge, spoolDirectory: temp.url)
        func request(_ id: Int64) -> SurgeRequest {
            CaptureFixtures.request(id: id, host: "api.anthropic.com", processPath: "/usr/local/bin/claude", remoteAddress: "203.0.113.10 (Proxy)")
        }
        var latest: [Int64: RequestRecord] = [:]
        func drain() async {
            for record in await pipeline.drainUpdate().records { latest[record.key.surgeID] = record }
        }

        await pipeline.ingest(request(1), now: base)
        #expect(await eventually {
            await drain()
            return latest[1]?.remoteIP != nil
        })
        #expect(latest[1]?.remoteIPSource == .tidemarkLookup)
        let lookedUpAt = try #require(latest[1]?.remoteIPResolvedAt)

        // Surge's cache holds the lookup's answer for five minutes. The host is requested every 30 s, well past
        // Tidemark's own minute, with a `dump dns` read between requests.
        surge.update { $0.dnsCache = [SurgeDNSRecord(domain: "api.anthropic.com", addresses: ["160.79.104.10"], expires: base.addingTimeInterval(300))] }
        for step in 1...9 {
            await pipeline.refreshDNSCache(now: base.addingTimeInterval(Double(step) * 30 - 15))
            await pipeline.ingest(request(Int64(step + 1)), now: base.addingTimeInterval(Double(step) * 30))
        }
        await drain()
        #expect(surge.snapshot.dnsLookups == ["api.anthropic.com"], "one lookup per TTL of the answer, not one a minute")
        #expect((2...10).allSatisfy { latest[$0]?.remoteIPSource == .tidemarkLookup && latest[$0]?.remoteIPResolvedAt == lookedUpAt },
                "still the answer of Tidemark's lookup")

        // Once Surge's answer expires, the host is looked up again.
        await pipeline.refreshDNSCache(now: base.addingTimeInterval(305))
        await pipeline.ingest(request(20), now: base.addingTimeInterval(310))
        #expect(await eventually { surge.snapshot.dnsLookups == ["api.anthropic.com", "api.anthropic.com"] })
    }

    @Test func anAnswerTidemarksLookupCausedStaysTidemarksUntilSurgeResolvesItAgain() async throws {
        let temp = CaptureTempDirectory()
        let surge = CaptureFakeSurge()
        surge.update { $0.dns["api.anthropic.com"] = ["160.79.104.10"] }
        let pipeline = makePipeline(database: CaptureFakeDatabase(), surge: surge, spoolDirectory: temp.url)
        func request(_ id: Int64) -> SurgeRequest {
            CaptureFixtures.request(id: id, host: "api.anthropic.com", processPath: "/usr/local/bin/claude", remoteAddress: "203.0.113.10 (Proxy)")
        }
        var latest: [Int64: RequestRecord] = [:]
        func drain() async {
            for record in await pipeline.drainUpdate().records { latest[record.key.surgeID] = record }
        }
        await pipeline.ingest(request(1), now: base)
        #expect(await eventually {
            await drain()
            return latest[1]?.remoteIP != nil
        })
        // Surge's `dns` event of that lookup.
        let event = SurgeDNSEvent(domain: "api.anthropic.com", server: "https://cloudflare-dns.com/dns-query", interface: "", data: ["160.79.104.10"])
        let eventAt = Date.now
        await pipeline.recordDNSAnswer(event, now: eventAt)

        // No read while Tidemark's own minute lasted (`dump dns` failed meanwhile): the answer Surge still caches is
        // the lookup's, and says so.
        surge.update { $0.dnsCache = [SurgeDNSRecord(domain: "api.anthropic.com", addresses: ["160.79.104.10"], expires: base.addingTimeInterval(300))] }
        await pipeline.refreshDNSCache(now: base.addingTimeInterval(120))
        await pipeline.ingest(request(2), now: base.addingTimeInterval(130))
        await drain()
        #expect(latest[2]?.remoteIPSource == .tidemarkLookup && latest[2]?.remoteIPResolvedAt == eventAt)

        // Surge resolves the host again for a request of its own: the same addresses are Surge's from then on.
        await pipeline.recordDNSAnswer(event, now: base.addingTimeInterval(200))
        surge.update { $0.dnsCache = [SurgeDNSRecord(domain: "api.anthropic.com", addresses: ["160.79.104.10"], expires: base.addingTimeInterval(600))] }
        await pipeline.refreshDNSCache(now: base.addingTimeInterval(230))
        await pipeline.ingest(request(3), now: base.addingTimeInterval(240))
        await drain()
        #expect(latest[3]?.remoteIPSource == .surgeCache && latest[3]?.remoteIPResolvedAt == base.addingTimeInterval(200))
        #expect(surge.snapshot.dnsLookups == ["api.anthropic.com"])
    }

    @Test func keepsSurgesDetailsAcrossEventsAndWritesThem() async throws {
        let temp = CaptureTempDirectory()
        let database = CaptureFakeDatabase()
        let pipeline = makePipeline(database: database, surge: CaptureFakeSurge(), spoolDirectory: temp.url)
        await pipeline.setDatabaseOnline(true)
        await pipeline.beginSession(1_000)
        let recorded = try #require(try CaptureMappingTests.recorded()[61456])

        // The creation event carries no notes; the reset shows only in the last update's notes.
        var created = recorded
        created.notes = nil
        created.completed = false
        created.completedDate = nil
        created.status = "Active"
        await pipeline.ingest(created, now: base)
        await pipeline.ingest(recorded, now: base.addingTimeInterval(1))
        // A late `dump recent` snapshot from before the end changes nothing.
        await pipeline.ingest(created, backfill: true, now: base.addingTimeInterval(2))
        await pipeline.tick(now: base.addingTimeInterval(3))

        let row = try #require(await database.rows[RequestKey(deviceID: device, session: 1_000, surgeID: 61456)])
        #expect(row.state == .completed && row.endReason == "TCP error: Connection reset" && row.endedWithError)
        #expect(row.entryMode == 40 && row.modified == false)
    }

    @Test func recordsDNSAnswersCompletedByTheNextDumpDNSRead() async throws {
        let temp = CaptureTempDirectory()
        let database = CaptureFakeDatabase()
        let surge = CaptureFakeSurge()
        // `dump dns` as it read after the events (Surge Mac 6.10).
        let dump = try SurgeOutputParser.dnsCache(from: SurgeFixtures.data("surge-dump-dns-answers.json"), command: "dump dns")
        surge.update {
            $0.dnsCache = dump
            $0.dns["proxycheck.io"] = ["104.26.8.187", "104.26.9.187", "172.67.75.219"]
        }
        let pipeline = makePipeline(database: database, surge: surge, spoolDirectory: temp.url)
        await pipeline.setDatabaseOnline(true)
        let events = try SurgeFixtures.lines("surge-watch-dns.jsonl").compactMap { line -> SurgeDNSEvent? in
            if case .dns(let event) = SurgeLineParser.event(from: line) { return event }
            return nil
        }
        let start = Date.now

        // Tidemark looks up the proxied host itself: Surge's answer to that lookup is marked as Tidemark's.
        await pipeline.ingest(CaptureFixtures.request(id: 1, host: "proxycheck.io", processPath: ownExecutable, remoteAddress: "203.0.113.10 (Proxy)"),
                              now: start)
        #expect(await eventually {
            let inFlight = await pipeline.dnsInFlight
            return surge.snapshot.dnsLookups == ["proxycheck.io"] && !inFlight.contains("proxycheck.io")
        })
        for event in events { await pipeline.recordDNSAnswer(event, now: start.addingTimeInterval(0.2)) }
        var unmatched = events[1]
        unmatched.domain = "Resolved-Again.example."
        await pipeline.recordDNSAnswer(unmatched, now: start.addingTimeInterval(0.3))

        // Nothing is written before a read completes the answers.
        await pipeline.tick(now: start.addingTimeInterval(1))
        #expect(await database.dnsAnswersSaved.isEmpty)
        await pipeline.refreshDNSCache(now: start.addingTimeInterval(20))
        await pipeline.tick(now: start.addingTimeInterval(21))
        let saved = await database.dnsAnswersSaved
        #expect(saved.map(\.domain) == ["proxycheck.io", "www.qualcomm.cn"])
        let proxycheck = try #require(saved.first)
        #expect(proxycheck.byTidemark && proxycheck.deviceID == device)
        #expect(proxycheck.resolvedAt == start.addingTimeInterval(0.2) && proxycheck.server == "https://cloudflare-dns.com/dns-query")
        #expect(proxycheck.interface == nil && proxycheck.addresses == ["104.26.8.187", "104.26.9.187", "172.67.75.219"])
        #expect(proxycheck.log == "318.73ms Receive an A answer from https://cloudflare-dns.com/dns-query")
        #expect(proxycheck.timeCostMs.map { abs($0 - 318.75) < 0.001 } == true)
        #expect(proxycheck.expiresAt == Date(timeIntervalSince1970: 1793009567.9200711))
        let qualcomm = try #require(saved.last)
        #expect(!qualcomm.byTidemark, "Surge resolved it for someone else")
        #expect(qualcomm.path == "www.qualcomm.cn -> www.qualcomm.cn.cdn.cloudflare.net -> 172.64.144.37, 104.18.43.219")

        // An answer no read matches is written as its event had it, a little over a minute later.
        await pipeline.tick(now: start.addingTimeInterval(60))
        #expect(await database.dnsAnswersSaved.count == 2)
        await pipeline.tick(now: start.addingTimeInterval(80))
        let late = try #require(await database.dnsAnswersSaved.last)
        #expect(await database.dnsAnswersSaved.count == 3)
        #expect(late.domain == "resolved-again.example" && late.path == nil && late.expiresAt == nil && !late.byTidemark)
    }

    @Test func asksTheBusyProxyNodesForTheirErrorsOnceAMinute() async throws {
        let temp = CaptureTempDirectory()
        let database = CaptureFakeDatabase()
        let surge = CaptureFakeSurge()
        let recorded = try SurgeOutputParser.proxyRuntimeStatus(from: SurgeFixtures.data("surge-proxy-runtime-status.json"), command: "proxy-runtime-status")
        let hashes = ["US-Hysteria2": "POLICY::2ed45e4c", "JP-Snell": "POLICY::c7f4fe8c", "SG-Snell": "POLICY::0d10272d", "HK-AnyTLS": "POLICY::c9be5557"]
        surge.update {
            $0.lineHashes = hashes
            for hash in hashes.values { $0.runtimeStatus[hash] = SurgeProxyRuntimeStatus(type: "Snell", errors: []) }
            $0.runtimeStatus["POLICY::2ed45e4c"] = SurgeProxyRuntimeStatus(type: "Hysteria 2", errors: Array(recorded.errors.suffix(2)))
            $0.dns["api.github.com"] = ["140.82.112.6"]
        }
        let pipeline = makePipeline(database: database, surge: surge, spoolDirectory: temp.url)
        await pipeline.setDatabaseOnline(true)
        func traffic(_ first: Int64, count: Int64 = 1, via node: String, at now: Date) async {
            for id in first..<(first + count) {
                var request = CaptureFixtures.request(id: id, host: "api.github.com", processPath: "/usr/bin/git", remoteAddress: "203.0.113.10 (Proxy)",
                                                      policy: node)
                request.notes = ["10:00:00.000001 [Rule] Policy decision path: AI -> \(node)"]
                await pipeline.ingest(request, now: now)
            }
        }
        func asked(_ node: String) -> String { "proxy-runtime-status \(hashes[node] ?? node)" }

        // Fifty requests through one node, and DIRECT ones: no surge-cli process per request (one lookup for the host).
        await traffic(1, count: 50, via: "US-Hysteria2", at: base)
        await traffic(100, count: 5, via: "DIRECT", at: base)
        #expect(await eventually { surge.snapshot.dnsLookups == ["api.github.com"] })
        #expect(surge.snapshot.proxyCommands.isEmpty)

        // First minute: the line hashes, then the node's errors.
        await pipeline.pollProxyErrors(now: base.addingTimeInterval(30))
        #expect(surge.snapshot.proxyCommands == ["dump traffic", asked("US-Hysteria2")])
        await pipeline.tick(now: base.addingTimeInterval(31))
        let saved = await database.proxyErrorsSaved
        #expect(saved.map(\.targetHost) == ["encrypted-tbn0.gstatic.com", "collector.github.com"])
        #expect(saved.allSatisfy { $0.policy == "US-Hysteria2" && $0.lineHash == "POLICY::2ed45e4c" && $0.deviceID == device && $0.error == "Stream closed" })

        // Every busy node is asked each minute, the one asked least recently first. A node lists its last errors every
        // time: only a new one is written.
        let fresh = SurgeProxyRuntimeStatus.ProxyError(message: "Stream closed", time: base.addingTimeInterval(80), targetHost: "api.github.com")
        surge.update { $0.runtimeStatus["POLICY::2ed45e4c"]?.errors.insert(fresh, at: 0) }
        await traffic(51, via: "US-Hysteria2", at: base.addingTimeInterval(80))
        await traffic(200, via: "JP-Snell", at: base.addingTimeInterval(85))
        await pipeline.pollProxyErrors(now: base.addingTimeInterval(90))
        #expect(surge.snapshot.proxyCommands.suffix(2) == [asked("JP-Snell"), asked("US-Hysteria2")])
        await pipeline.tick(now: base.addingTimeInterval(91))
        #expect(await database.proxyErrorsSaved.count == 3)
        #expect(await database.proxyErrorsSaved.last?.at == fresh.time)

        // More busy nodes than processes a minute (a load-balance group, say): three a minute, each in turn.
        for (offset, node) in ["US-Hysteria2", "JP-Snell", "SG-Snell", "HK-AnyTLS"].enumerated() {
            await traffic(300 + Int64(offset), via: node, at: base.addingTimeInterval(140))
        }
        await pipeline.pollProxyErrors(now: base.addingTimeInterval(150))
        #expect(surge.snapshot.proxyCommands.suffix(3) == [asked("HK-AnyTLS"), asked("SG-Snell"), asked("JP-Snell")])
        await pipeline.pollProxyErrors(now: base.addingTimeInterval(160))
        #expect(surge.snapshot.proxyCommands.suffix(3).first == asked("US-Hysteria2"), "the one left out goes first")
        #expect(surge.snapshot.proxyCommands.count == 10)

        // No requests through a proxy for a minute: nothing to ask.
        await pipeline.pollProxyErrors(now: base.addingTimeInterval(400))
        #expect(surge.snapshot.proxyCommands.count == 10)

        // A node Surge cannot report on (no line hash, unknown by name) waits ten minutes.
        await traffic(400, via: "Gone-Node", at: base.addingTimeInterval(1_000))
        await pipeline.pollProxyErrors(now: base.addingTimeInterval(1_010))
        #expect(surge.snapshot.proxyCommands.suffix(2) == ["dump traffic", "proxy-runtime-status Gone-Node"])
        await traffic(401, via: "Gone-Node", at: base.addingTimeInterval(1_050))
        await pipeline.pollProxyErrors(now: base.addingTimeInterval(1_070))
        #expect(surge.snapshot.proxyCommands.count == 12)
    }

    @Test func asksAProxyNodeByAFreshLineHashAndQueuesEachErrorOnce() async throws {
        let temp = CaptureTempDirectory()
        let database = CaptureFakeDatabase()
        let surge = CaptureFakeSurge()
        let recorded = try SurgeOutputParser.proxyRuntimeStatus(from: SurgeFixtures.data("surge-proxy-runtime-status.json"), command: "proxy-runtime-status")
        let status = SurgeProxyRuntimeStatus(type: "Hysteria 2", errors: Array(recorded.errors.prefix(3)))
        surge.update {
            // `dump traffic` lists no hash for the node yet; a node of the profile also answers by its name.
            $0.runtimeStatus["US-Hysteria2"] = status
            $0.dns["api.github.com"] = ["140.82.112.6"]
        }
        let pipeline = makePipeline(database: database, surge: surge, spoolDirectory: temp.url)
        await pipeline.setDatabaseOnline(true)
        func traffic(_ id: Int64, at seconds: TimeInterval) async {
            await pipeline.ingest(CaptureFixtures.request(id: id, host: "api.github.com", processPath: "/usr/bin/git",
                                                          remoteAddress: "203.0.113.10 (Proxy)", policy: "US-Hysteria2"),
                                  now: base.addingTimeInterval(seconds))
        }
        func poll(at seconds: TimeInterval) async { await pipeline.pollProxyErrors(now: base.addingTimeInterval(seconds)) }

        // Asked by name, as `dump traffic` lists no hash for it.
        await traffic(1, at: 0)
        await poll(at: 10)
        #expect(surge.snapshot.proxyCommands == ["dump traffic", "proxy-runtime-status US-Hysteria2"])

        // Ten minutes on, `dump traffic` lists its hash and the node is asked by it: the errors it lists again are its
        // own, already queued.
        surge.update {
            $0.lineHashes = ["US-Hysteria2": "POLICY::2ed45e4c"]
            $0.runtimeStatus["POLICY::2ed45e4c"] = status
        }
        await traffic(2, at: 690)
        await poll(at: 700)
        #expect(surge.snapshot.proxyCommands.suffix(2) == ["dump traffic", "proxy-runtime-status POLICY::2ed45e4c"])
        await pipeline.tick(now: base.addingTimeInterval(701))
        #expect(await database.proxyErrorsSaved.count == 3, "each error once")
        #expect(await database.proxyErrorsSaved.allSatisfy { $0.policy == "US-Hysteria2" && $0.lineHash == "US-Hysteria2" })

        // A policy-path subscription update gives the node another hash, and Surge no longer knows the old one. That
        // hash was read ten minutes ago or more: the next minute reads them again and asks by the new one.
        let fresh = SurgeProxyRuntimeStatus.ProxyError(message: "Stream closed", time: base.addingTimeInterval(1_300), targetHost: "api.github.com")
        surge.update {
            $0.lineHashes = ["US-Hysteria2": "POLICY::9f3a77c1"]
            $0.runtimeStatus["POLICY::2ed45e4c"] = nil
            $0.runtimeStatus["POLICY::9f3a77c1"] = SurgeProxyRuntimeStatus(type: "Hysteria 2", errors: [fresh] + status.errors)
        }
        await traffic(3, at: 1_350)
        await poll(at: 1_360)
        await traffic(4, at: 1_400)
        await poll(at: 1_420)
        #expect(surge.snapshot.proxyCommands.suffix(3) == ["proxy-runtime-status POLICY::2ed45e4c", "dump traffic", "proxy-runtime-status POLICY::9f3a77c1"])
        await pipeline.tick(now: base.addingTimeInterval(1_421))
        #expect(await database.proxyErrorsSaved.count == 4)
        #expect(await database.proxyErrorsSaved.last.map { $0.at == fresh.time && $0.lineHash == "POLICY::9f3a77c1" } == true)

        // A profile reload may change every hash: they are read again at once.
        surge.update {
            $0.lineHashes = ["US-Hysteria2": "POLICY::5be0d218"]
            $0.runtimeStatus["POLICY::5be0d218"] = SurgeProxyRuntimeStatus(type: "Hysteria 2", errors: [fresh] + status.errors)
        }
        let (stream, continuation) = AsyncThrowingStream<SurgeEvent, Error>.makeStream()
        continuation.yield(.reload)
        continuation.finish()
        try await pipeline.consume(stream)
        await traffic(5, at: 1_450)
        await poll(at: 1_480)
        #expect(surge.snapshot.proxyCommands.suffix(2) == ["dump traffic", "proxy-runtime-status POLICY::5be0d218"])
        await pipeline.tick(now: base.addingTimeInterval(1_481))
        #expect(await database.proxyErrorsSaved.count == 4)
    }

    @Test func matchesProbeConnectionsBySourcePort() async throws {
        let temp = CaptureTempDirectory()
        let database = CaptureFakeDatabase()
        let probes = ProbeRegistry()
        let session = UUID()
        probes.begin(sessionID: session, startedAt: base)
        probes.connectionOpened(host: "github.com", at: base)
        probes.registerUpstream(port: 50_001, host: "github.com")
        let pipeline = makePipeline(database: database, surge: CaptureFakeSurge(), spoolDirectory: temp.url, probes: probes)
        await pipeline.setDatabaseOnline(true)

        let own = CaptureFixtures.request(id: 3, host: "github.com", processPath: ownExecutable, remoteAddress: "20.205.243.166", sourcePort: 50_001)
        let other = CaptureFixtures.request(id: 4, host: "github.com", processPath: ownExecutable, remoteAddress: "20.205.243.166", sourcePort: 50_002)
        await pipeline.ingest(own, now: base)
        await pipeline.ingest(other, now: base)
        let update = await pipeline.drainUpdate()
        #expect(update.records.first { $0.key.surgeID == 3 }?.probeSessionID == session)
        #expect(update.records.first { $0.key.surgeID == 4 }?.probeSessionID == nil)
        #expect(probes.snapshot().hosts.first?.ips == ["20.205.243.166"])

        await pipeline.tick(now: base.addingTimeInterval(2))
        let sources = await database.sources
        #expect(sources.count == 2, "only the non-probe request lands in the global inventory from the pipeline")
    }

    @Test func pausingRecordingDropsEvents() async {
        let temp = CaptureTempDirectory()
        let pipeline = makePipeline(database: CaptureFakeDatabase(), surge: CaptureFakeSurge(), spoolDirectory: temp.url)
        await pipeline.setRecording(false)
        let request = CaptureFixtures.request(id: 1, host: "a.com", processPath: "/usr/bin/curl")
        await pipeline.ingest(request, now: base)
        #expect(await pipeline.drainUpdate().records.isEmpty)

        await pipeline.setRecording(true)
        await pipeline.ingest(request, now: base)
        #expect(await pipeline.drainUpdate().records.isEmpty, "requests first seen while paused stay ignored")
        await pipeline.ingest(CaptureFixtures.request(id: 2, host: "b.com", processPath: "/usr/bin/curl"), now: base)
        let update = await pipeline.drainUpdate()
        #expect(update.records.map(\.key.surgeID) == [2])
        #expect(update.newRequests == 1)
    }

    @Test func pausingStillEndsRequestsRecordedBefore() async {
        let temp = CaptureTempDirectory()
        let database = CaptureFakeDatabase()
        let pipeline = makePipeline(database: database, surge: CaptureFakeSurge(), spoolDirectory: temp.url)
        await pipeline.setDatabaseOnline(true)
        await pipeline.ingest(CaptureFixtures.request(id: 1, host: "a.com", processPath: "/usr/bin/curl"), now: base)
        await pipeline.tick(now: base.addingTimeInterval(1))
        await pipeline.setRecording(false)

        var finished = CaptureFixtures.request(id: 1, host: "a.com", processPath: "/usr/bin/curl", completed: true)
        finished.inBytes = 9_999
        await pipeline.ingest(finished, now: base.addingTimeInterval(2))
        await pipeline.ingest(CaptureFixtures.request(id: 2, host: "b.com", processPath: "/usr/bin/curl"), now: base.addingTimeInterval(2))
        await pipeline.tick(now: base.addingTimeInterval(3))

        let row = await database.rows[RequestKey(deviceID: device, session: 0, surgeID: 1)]
        #expect(row?.state == .completed, "its row does not stay active until the next reconnect")
        #expect(row?.completedAt == Date(timeIntervalSince1970: 1_792_871_001))
        #expect(row?.inBytes == 0, "nothing else is recorded while paused")
        #expect(await database.rows.count == 1, "requests first seen while paused stay ignored")
    }

    @Test func aPolicyThatArrivesLaterIsWrittenSoon() async {
        let temp = CaptureTempDirectory()
        let database = CaptureFakeDatabase()
        let pipeline = makePipeline(database: database, surge: CaptureFakeSurge(), spoolDirectory: temp.url)
        await pipeline.setDatabaseOnline(true)
        var undecided = CaptureFixtures.request(id: 1, host: "a.com", processPath: "/usr/bin/curl")
        undecided.policyName = nil
        undecided.notes = []
        await pipeline.ingest(undecided, now: base)
        await pipeline.tick(now: base.addingTimeInterval(1))
        let key = RequestKey(deviceID: device, session: 0, surgeID: 1)
        #expect(await database.rows[key]?.policyPath.isEmpty == true)

        await pipeline.ingest(CaptureFixtures.request(id: 1, host: "a.com", processPath: "/usr/bin/curl", policy: "AI -> HK-01"),
                              now: base.addingTimeInterval(1.5))
        await pipeline.tick(now: base.addingTimeInterval(3.2))
        #expect(await database.rows[key]?.policyPath == ["AI", "HK-01"], "History shows the policy within seconds, not after the 10 s rewrite")
    }

    @Test func anIPThatArrivesWithTheCompletionIsCountedOnce() async throws {
        let temp = CaptureTempDirectory()
        let database = CaptureFakeDatabase()
        let raycast = CaptureFixtures.app("Raycast", path: "/Applications/Raycast.app")
        await database.setKnown([raycast.id: ["api.notion.com"]])
        let pipeline = makePipeline(database: database, surge: CaptureFakeSurge(), spoolDirectory: temp.url, contactGrace: 30)
        await pipeline.setApps([raycast], paused: [])
        try await pipeline.loadKnownHosts()
        await pipeline.setDatabaseOnline(true)

        // Proxied: no IP yet, so the contact waits for one.
        await pipeline.ingest(nodeRequest(id: 1, host: "api.notion.com", remoteAddress: "23.254.139.175 (Proxy)"), now: base)
        await pipeline.ingest(nodeRequest(id: 1, host: "api.notion.com", remoteAddress: "10.0.0.8", completed: true), now: base.addingTimeInterval(1))
        await pipeline.tick(now: base.addingTimeInterval(2))

        #expect(Set(await database.appHosts.values.map(\.value)) == ["10.0.0.8"])
        #expect(await database.touches.filter { $0.kind == .ip }.isEmpty, "the new IP is inserted once, not touched as well")
        #expect(await database.touches.filter { $0.kind == .domain }.count == 1)
    }

    @Test func backfillIsNotCountedAsNewTraffic() async {
        let temp = CaptureTempDirectory()
        let pipeline = makePipeline(database: CaptureFakeDatabase(), surge: CaptureFakeSurge(), spoolDirectory: temp.url)
        await pipeline.ingestBackfill([
            CaptureFixtures.request(id: 2, host: "b.com", processPath: "/usr/bin/curl", completed: true),
            CaptureFixtures.request(id: 1, host: "a.com", processPath: "/usr/bin/curl", completed: true),
        ], now: base)
        let update = await pipeline.drainUpdate()
        #expect(update.newRequests == 0)
        #expect(update.fresh.count == 2)
    }

    @Test func countsEachAppsNewRequests() async {
        let temp = CaptureTempDirectory()
        let raycast = CaptureFixtures.app("Raycast", path: "/Applications/Raycast.app")
        let pipeline = makePipeline(database: CaptureFakeDatabase(), surge: CaptureFakeSurge(), spoolDirectory: temp.url)
        await pipeline.setApps([raycast], paused: [])
        await pipeline.ingestBackfill([nodeRequest(id: 1, host: "backend.raycast.com", remoteAddress: "76.76.21.21", completed: true)], now: base)
        await pipeline.ingest(nodeRequest(id: 2, host: "api.notion.com", remoteAddress: "104.18.22.110"), now: base)
        await pipeline.ingest(nodeRequest(id: 3, host: "api.linear.app", remoteAddress: "10.0.0.8"), now: base)
        await pipeline.ingest(CaptureFixtures.request(id: 4, host: "a.com", processPath: "/usr/bin/curl"), now: base)
        let update = await pipeline.drainUpdate()
        #expect(update.newRequests == 3)
        #expect(update.newRequestsByApp == [raycast.id: 2], "node counts for Raycast, which launched it; backfill and curl are left out")
    }

    @Test func newlyMonitoredAppsAttributeLiveRequests() async throws {
        let temp = CaptureTempDirectory()
        let database = CaptureFakeDatabase()
        let pipeline = makePipeline(database: database, surge: CaptureFakeSurge(), spoolDirectory: temp.url, contactGrace: 0)
        try await pipeline.loadKnownHosts()
        await pipeline.setDatabaseOnline(true)
        await pipeline.ingestBackfill([nodeRequest(id: 1, host: "backend.raycast.com", remoteAddress: "76.76.21.21", completed: true)], now: base)
        _ = await pipeline.drainUpdate()

        let raycast = CaptureFixtures.app("Raycast", path: "/Applications/Raycast.app", createdAt: .now)
        await pipeline.setApps([raycast], paused: [])
        let update = await pipeline.drainUpdate()
        #expect(update.records.first?.appID == raycast.id)
        await pipeline.tick(now: base.addingTimeInterval(2))
        #expect(await database.alertsInserted.isEmpty, "traffic from before the app was added is history, not first contact")
    }
}
