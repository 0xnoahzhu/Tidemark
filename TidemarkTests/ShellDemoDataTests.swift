import Foundation
import Testing
@testable import Tidemark

/// The demo rows carry the request details of schema v4 the way capture records them, and the demo database serves the
/// DNS answers and proxy errors that go with them.
@MainActor
struct ShellDemoDataTests {
    @Test func demoRequestsCarryTheirDetails() async throws {
        let defaults = TestDefaults()
        let model = AppModel(preferences: Preferences(defaults: defaults.make()))
        ShellDemoData.install(into: model)
        let rows = model.live.rows
        try #require(!rows.isEmpty)
        for row in rows {
            #expect(CaptureRecordMapper.endReason(notes: row.notes) == row.endReason, "\(row.notes)")
            #expect(CaptureRecordMapper.policyPath(notes: row.notes, policyName: nil) == row.policyPath)
            if row.remoteIPSource == .ruleDNS {
                #expect(CaptureRecordMapper.ruleDNSAddress(notes: row.notes)?.ip == row.remoteIP)
            }
        }
        #expect(rows.contains { $0.endedWithError && $0.state == .completed }, "resets Surge reports completed")
        #expect(Set(rows.compactMap(\.entry)) == [.httpProxy, .virtualInterface(udp: true), .virtualInterface(udp: false)])
        #expect(Set(rows.compactMap(\.remoteIPSource)) == [.literal, .surge, .ruleDNS])

        let database = try #require(model.database as? ShellDemoDatabase)
        let looked = try #require(rows.first { $0.timing?.contains { $0.name == "DNS Lookup" } == true })
        let related = try await database.relatedRecords(of: looked)
        #expect(related.dnsAnswer?.addresses == looked.remoteIP.map { [$0] })
        #expect(related.dnsAnswer?.path?.hasSuffix(looked.remoteIP ?? "?") == true)

        let reset = try #require(rows.first { $0.endReason == "TCP error: Connection reset" && $0.finalPolicy != "DIRECT" && $0.completedAt != nil },
                                 "a proxied request the live table shows ended with a reset")
        #expect(try await database.proxyErrors(for: reset).map(\.error) == ["Stream closed"])
        let page = try await database.requests(forHost: reset.host, query: RequestQuery(range: .all, endedWithError: true))
        #expect(page.totalCount > 0 && page.rows.allSatisfy { $0.host == reset.host && $0.endedWithError })
    }
}
