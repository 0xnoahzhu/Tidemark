import Foundation
import Testing
@testable import Tidemark

/// Read-only checks against the Surge running on this Mac. Skipped when surge-cli is not installed.
@Suite("Surge live", .enabled(if: SurgeCLIClient.locateCLI() != nil), .timeLimit(.minutes(1)))
struct SurgeLiveTests {
    let client = SurgeCLIClient(endpoint: SurgeEndpoint(cliPath: SurgeCLIClient.locateCLI() ?? ""))

    @Test func readsStatus() async throws {
        let status = try await client.status()
        #expect(status.version?.isEmpty == false)
        #expect((status.startTime ?? 0) > 1_600_000_000)
        #expect(["rule", "proxy", "direct"].contains(status.mode ?? ""))
    }

    @Test func readsRecentRequests() async throws {
        let requests = try await client.recentRequests()
        #expect(requests.count <= 200)
        for request in requests {
            #expect(request.remoteHost != nil || request.url != nil)
            #expect((request.startDate ?? 0) > 1_600_000_000)
        }
    }

    @Test func looksUpGeoIP() async throws {
        let geo = try await client.geoIP("1.1.1.1")
        #expect(geo.address == "1.1.1.1")
        #expect(geo.asn == 13335)
    }

    @Test func readsEnvironmentPoliciesAndNetwork() async throws {
        let environment = try await client.environment()
        #expect(environment.proxyMode.map { (0...2).contains($0) } ?? true)
        let groups = try await client.policyGroups()
        #expect(groups.allSatisfy { !$0.name.isEmpty })
        let network = try await client.network()
        #expect(network.surgeMode != nil)
        let port = try await client.httpProxyPort()
        #expect((1...65535).contains(port))
        let listener = try await client.httpProxyListener()
        #expect(listener.port == port)
        #expect(!listener.connectHost.isEmpty)
        #expect(groups.allSatisfy { $0.type?.isEmpty != true }, "types are kept when Surge reports them")
    }

    @Test func readsTheFinalRule() async throws {
        let policy = try await client.finalRulePolicy()
        #expect(policy?.isEmpty != true)
    }

    @Test func reportsCommandErrors() async {
        await #expect(throws: SurgeError.self) {
            try await client.geoIP("not-an-ip")
        }
    }

    @Test func watchesForThreeSeconds() async throws {
        let events = client.events()
        let collector = Task {
            var kinds: [String] = []
            do {
                for try await event in events {
                    switch event {
                    case .subscribed: kinds.append("subscribed")
                    case .request: kinds.append("request")
                    case .speed: kinds.append("speed")
                    default: kinds.append("other")
                    }
                }
            } catch {
                kinds.append("error: \(error)")
            }
            return kinds
        }
        try await Task.sleep(for: .seconds(3))
        collector.cancel()
        let kinds = await collector.value
        #expect(kinds.first == "subscribed")
        #expect(!kinds.contains { $0.hasPrefix("error") })
    }
}
