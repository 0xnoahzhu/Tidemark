import Foundation
import Testing
@testable import Tidemark

@Suite @MainActor struct AppDetailCacheTests {
    private static func node(_ name: String) -> ProcessNode {
        ProcessNode(id: name, name: name, pid: 1, startTime: nil, path: nil, depth: 0, domainCount: 0, requestCount: 0, isRunning: false)
    }

    @Test func keepsTheMostRecentlyUsedEntries() {
        let cache = AppDetailCache(limit: 2)
        let keys = (0..<3).map { _ in AppDetailCache.Key(appID: UUID(), scope: .all) }
        cache.setTree([Self.node("a")], for: keys[0])
        cache.setTree([Self.node("b")], for: keys[1])
        // Reading the first keeps it; the second is now the least recently used.
        #expect(cache.tree(keys[0])?.first?.name == "a")
        cache.setTree([Self.node("c")], for: keys[2])
        #expect(cache.tree(keys[0])?.first?.name == "a")
        #expect(cache.tree(keys[1]) == nil)
        #expect(cache.tree(keys[2])?.first?.name == "c")
    }

    @Test func keysScopesApart() {
        let cache = AppDetailCache()
        let app = UUID()
        let summary = AppDetailInventorySummary()
        cache.setInventory(AppDetailCache.Inventory(hosts: [], summary: summary), for: AppDetailCache.Key(appID: app, scope: .all))
        #expect(cache.inventory(AppDetailCache.Key(appID: app, scope: .all)) != nil)
        #expect(cache.inventory(AppDetailCache.Key(appID: app, scope: .device(UUID()))) == nil)
    }

    @Test func aCachedListFitsItsSearchAndTheDomainsItHas() {
        let now = Date()
        let hosts = [
            AppHost(appID: UUID(), kind: .domain, value: "api.github.com", site: "github.com", firstSeen: now, lastSeen: now,
                    requestCount: 1, processName: nil, policy: nil, geo: nil, isDirect: false, hosts: []),
        ]
        let inventory = AppDetailCache.Inventory(hosts: hosts, summary: AppDetailInventorySummary(hosts: hosts, search: "", now: now, site: { $0 }))
        #expect(inventory.fits(search: "", selectedHost: nil))
        #expect(inventory.fits(search: "", selectedHost: "api.github.com"))
        #expect(!inventory.fits(search: "git", selectedHost: nil))
        // A domain selected after the list was cached, like the new domain a notification's View opens.
        #expect(!inventory.fits(search: "", selectedHost: "brand.new.example"))
    }

    @Test func summaryIsCurrentUntilItsSearchChangesOrANewMarkRunsOut() {
        let now = Date()
        let hosts = [
            AppHost(appID: UUID(), kind: .domain, value: "api.github.com", site: "github.com", firstSeen: now.addingTimeInterval(-23 * 3600),
                    lastSeen: now, requestCount: 1, processName: nil, policy: nil, geo: nil, isDirect: false, hosts: []),
            AppHost(appID: UUID(), kind: .domain, value: "github.com", site: "github.com", firstSeen: now.addingTimeInterval(-48 * 3600),
                    lastSeen: now, requestCount: 1, processName: nil, policy: nil, geo: nil, isDirect: false, hosts: []),
        ]
        let summary = AppDetailInventorySummary(hosts: hosts, search: "git", now: now, site: { $0 })
        #expect(summary.search == "git")
        #expect(summary.isCurrent(search: "git", at: now.addingTimeInterval(3599)))
        #expect(!summary.isCurrent(search: "gi", at: now))
        // api.github.com stops being new an hour later, which reorders the site and changes the count.
        #expect(!summary.isCurrent(search: "git", at: now.addingTimeInterval(3600)))
        // Nothing new: current until the search changes.
        let old = AppDetailInventorySummary(hosts: [hosts[1]], search: "", now: now, site: { $0 })
        #expect(old.isCurrent(search: "", at: now.addingTimeInterval(365 * 86400)))
    }

    @Test func summarizesOffTheMainActorLikeTheInitializer() async {
        let now = Date()
        let hosts = [
            AppHost(appID: UUID(), kind: .domain, value: "api.github.com", site: nil, firstSeen: now, lastSeen: now, requestCount: 3,
                    processName: nil, policy: nil, geo: nil, isDirect: false, hosts: []),
            AppHost(appID: UUID(), kind: .ip, value: "140.82.112.5", site: nil, firstSeen: now, lastSeen: now, requestCount: 2,
                    processName: nil, policy: nil, geo: nil, isDirect: false, hosts: ["api.github.com"]),
        ]
        let made = await AppDetailInventorySummary.make(hosts: hosts, search: "", now: now, classifier: NaiveSiteClassifier())
        let direct = AppDetailInventorySummary(hosts: hosts, search: "", now: now, site: { NaiveSiteClassifier().site(for: $0) })
        #expect(made.groups == direct.groups)
        #expect(made.resolvedIPs == direct.resolvedIPs)
        #expect(made.headline == direct.headline)
    }
}
