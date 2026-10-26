import Foundation
import Testing
@testable import Tidemark

struct FoundationTests {
    @Test func splitsHostAndPort() {
        #expect(HostName.splitHostPort("api2.cursor.sh:443") == ("api2.cursor.sh", 443))
        #expect(HostName.splitHostPort("[2001:db8::1]:8443") == ("2001:db8::1", 8443))
        #expect(HostName.splitHostPort("149.154.175.60:443") == ("149.154.175.60", 443))
    }

    @Test func detectsIPLiterals() {
        #expect(HostName.isIPAddress("183.3.226.35"))
        #expect(HostName.isIPAddress("2001:db8::1"))
        #expect(!HostName.isIPAddress("api.github.com"))
        #expect(!HostName.isIPAddress("999.1.1.1"))
    }

    @Test func formatsGeo() {
        let geo = GeoInfo(countryCode: "us", asn: 13335, organization: "Cloudflare, Inc.")
        #expect(geo.display == "US · AS13335 Cloudflare")
        #expect(GeoInfo.shortOrganization("Amazon.com, Inc.") == "Amazon")
        #expect(GeoInfo.shortOrganization("Anthropic, PBC") == "Anthropic")
        #expect(GeoInfo.shortOrganization("Tencent Building, Kejizhongyi Avenue") == "Tencent Building")
    }

    @Test func parsesSurgeNotes() throws {
        let note = try #require(RequestTiming.parse(note: "12:07:22.102428 [TLS] TLS Client Hello SNI: api2.cursor.sh"))
        #expect(note.tag == "TLS")
        #expect(note.text == "TLS Client Hello SNI: api2.cursor.sh")
        #expect(abs(note.secondsOfDay - (12 * 3600 + 7 * 60 + 22.102428)) < 0.0001)
    }

    @Test func timesTheDesignsPhasesOncePerKind() throws {
        // Surge sniffs the TLS Client Hello, evaluates the rule, then hands the connection to a connector.
        let start = Calendar.current.startOfDay(for: .now).addingTimeInterval(12 * 3600 + 46 * 60 + 59.906)
        let record = RequestRecord(
            key: RequestKey(deviceID: UUID(), session: 1, surgeID: 1), rowID: nil, startedAt: start,
            setupCompletedAt: start.addingTimeInterval(0.004), completedAt: start.addingTimeInterval(0.104),
            method: "HTTPS", host: "api.anthropic.com", port: 443, url: nil, remoteIP: nil, remoteAddress: nil, geo: nil,
            policyPath: [], rule: nil, state: .completed, inBytes: 0, outBytes: 0, pid: nil, processPath: nil,
            bundlePath: nil, chain: [], appID: nil, localAddress: nil, interface: nil,
            notes: [
                "12:46:59.906000 [Connection] Incoming proxy protocol: HTTP",
                "12:46:59.908000 [TLS] TLS Client Hello SNI: api.anthropic.com",
                "12:46:59.909000 [Rule] Policy decision path: AI -> AT&T-RackNerd-Hysteria2",
                "12:46:59.909500 [Connector] Master connector is now ready",
            ],
            isNew: false, writtenAt: nil, probeSessionID: nil
        )
        let phases = RequestTiming.phases(for: record)
        // No Rule phase: the rule counts as Connect. The wait for the Client Hello comes first.
        #expect(phases.map(\.kind) == [.clientHello, .connect, .transfer])
        let hello = try #require(phases.first)
        #expect(abs(hello.duration - 0.002) < 0.0005)
        #expect(abs(phases[1].duration - 0.002) < 0.0005)
        #expect(abs(phases[2].duration - 0.1) < 0.0005)
    }

    @Test func formatsBytes() {
        #expect(Fmt.bytes(512) == "512 B")
        #expect(Fmt.bytes(15_770) == "15.4 KB")
        #expect(Fmt.bytes(1_258_291) == "1.2 MB")
    }
}

@MainActor
struct LiveStateOrderTests {
    private func record(_ id: Int64, _ startedAt: Date) -> RequestRecord {
        RequestRecord(key: RequestKey(deviceID: UUID(), session: 1, surgeID: id), rowID: nil, startedAt: startedAt,
                      setupCompletedAt: nil, completedAt: nil, method: "HTTPS", host: "example.com", port: 443, url: nil,
                      remoteIP: nil, remoteAddress: nil, geo: nil, policyPath: [], rule: nil, state: .active,
                      inBytes: 0, outBytes: 0, pid: nil, processPath: nil, bundlePath: nil, chain: [], appID: nil,
                      localAddress: nil, interface: nil, notes: [], isNew: false, writtenAt: nil, probeSessionID: nil)
    }

    @Test func keepsRowsNewestFirstWhenOlderRowsArriveLate() {
        let live = LiveState()
        let now = Date.now
        live.upsert([record(1, now), record(2, now.addingTimeInterval(-10))])
        live.upsert([record(3, now.addingTimeInterval(-5)), record(4, now.addingTimeInterval(5))])
        #expect(live.rows.map(\.key.surgeID) == [4, 1, 3, 2])
    }
}
