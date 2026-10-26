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

    /// The demo's global-mode requests go through every stage of a journey, and their alert, site probe and egress
    /// change are there to link to.
    @Test func demoGlobalModeRequestsShowEveryStage() async throws {
        let defaults = TestDefaults()
        let model = AppModel(preferences: Preferences(defaults: defaults.make()))
        ShellDemoData.install(into: model)
        let database = try #require(model.database as? ShellDemoDatabase)
        let global = database.rows.filter { $0.rule == "Global · AI" }
        try #require(global.count == 5)
        for row in global {
            #expect(CaptureRecordMapper.endReason(notes: row.notes) == row.endReason)
            #expect(CaptureRecordMapper.policyPath(notes: row.notes, policyName: nil) == row.policyPath)
        }

        let linear = try #require(global.first { $0.host == "api.linear.app" })
        let related = try await database.relatedRecords(of: linear)
        #expect(related.alert?.value == "api.linear.app")
        #expect(related.egressChange?.policyPath == ["AI", "US-West"])
        #expect(related.dnsAnswer?.byTidemark == true)
        let journey = RequestsJourney(record: linear, related: related)
        #expect(journey.stages.map(\.kind) == [0, 1, 2, 3, 4, 5])
        let decisions = journey.stages.compactMap { stage -> RequestsJourney.Rule.Decision? in
            if case .rule(let rule) = stage { rule.decision } else { nil }
        }
        #expect(decisions == [.global(policy: "AI")])
        guard case .route(let route)? = journey.stages.first(where: { $0.kind == 3 }) else {
            Issue.record("no route")
            return
        }
        #expect(route.hops.contains { if case .exit("198.51.100.23", _, _) = $0 { true } else { false } })

        let probed = global.filter { $0.probeSessionID != nil }
        #expect(probed.count == 3)
        #expect(try await database.relatedRecords(of: probed[0]).probeSession?.host == "github.com")
        let entries = try await database.inventory(kind: .domain, search: "github.com", scope: .all)
        #expect(entries.first { $0.value == "github.com" }?.sources.contains { $0.probeSessionID != nil } == true)

        let reset = try #require(global.first { $0.endedWithError })
        #expect(RequestsPresentation.status(of: reset) == .ended("TCP error: Connection reset"))
        #expect(try await database.proxyErrors(for: reset).map(\.error) == ["Stream closed"])
        #expect(model.probe.sessions.count == 1 && model.egress.samples.first?.isCurrent == true)
    }
}
