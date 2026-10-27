import Foundation
import Testing
@testable import Tidemark

// The processes an app's Domains & IPs tab lists under a selected domain or IP.

@Suite @MainActor struct AppDetailHostProcessesTests {
    typealias F = UIMainFixtures

    /// Waits until `condition` holds, a second at most.
    private func eventually(_ condition: () -> Bool) async throws {
        for _ in 0..<100 where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    /// A selection shows what the cache had for its address while the database reads it, then what it read; a failed
    /// read keeps a list and otherwise says why; no selection shows nothing.
    @Test func aSelectionStartsFromTheCacheAndFollowsTheDatabase() async throws {
        let defaults = TestDefaults()
        let model = AppModel(preferences: Preferences(defaults: defaults.make()))
        let cursor = F.cursor.id
        let key = AppDetailCache.HostKey(appID: cursor, scope: .all, kind: .domain, value: "api2.cursor.sh")
        let curl = HostProcess(path: "/usr/bin/curl", name: "curl", firstSeen: .now, lastSeen: .now, requestCount: 1, deviceIDs: [F.thisMac])
        let node = HostProcess(path: "/usr/local/bin/node", name: "node", firstSeen: .now, lastSeen: .now, requestCount: 2, deviceIDs: [F.thisMac])
        let cache = AppDetailCache()
        cache.setProcesses([curl], for: key)
        let processes = AppDetailHostProcesses()

        // The cached list while a slow read runs, then the list read.
        model.database = RequestsStubDatabase(processes: { kind, value in
            try await Task.sleep(for: .milliseconds(300))
            return kind == .domain && value == "api2.cursor.sh" ? [node] : []
        })
        let reading = Task { await processes.follow(key, in: .domain, model: model, cache: cache) }
        try await eventually { processes.shown(.domain) != nil }
        #expect(processes.shown(.domain)?.processes == [curl])
        try await eventually { processes.shown(.domain)?.processes == [node] }
        #expect(processes.shown(.domain)?.processes == [node])
        #expect(cache.processes(key) == [node])
        #expect(processes.shown(.ip) == nil)
        reading.cancel()
        await reading.value

        // A read that fails keeps the list shown; with none, the selection says why.
        model.database = RequestsStubDatabase(processes: { _, _ in throw DatabaseError.unreachable(.poolClosed) })
        let failing = Task { await processes.follow(key, in: .domain, model: model, cache: cache) }
        try await Task.sleep(for: .milliseconds(100))
        #expect(processes.shown(.domain) == AppDetailHostProcesses.Shown(key: key, processes: [node]))
        failing.cancel()
        await failing.value
        let ipKey = AppDetailCache.HostKey(appID: cursor, scope: .all, kind: .ip, value: "104.18.19.125")
        let failingIP = Task { await processes.follow(ipKey, in: .ip, model: model, cache: cache) }
        try await eventually { processes.shown(.ip)?.failure != nil }
        #expect(processes.shown(.ip)?.processes == nil)
        #expect(processes.shown(.ip)?.failure == CaptureEngine.message(for: DatabaseError.unreachable(.poolClosed)))
        failingIP.cancel()
        await failingIP.value

        await processes.follow(nil, in: .domain, model: model, cache: cache)
        #expect(processes.shown(.domain) == nil && processes.shown(.ip) != nil)
        processes.retry(.ip)
        #expect(processes.attempt(.ip) == 1 && processes.attempt(.domain) == 0)
    }

    /// The cache keeps each address's list apart, per app and scope.
    @Test func theCacheKeepsEachAddressApart() {
        let cache = AppDetailCache(hostLimit: 2)
        let app = UUID()
        let keys = ["a.example.com", "b.example.com", "c.example.com"].map {
            AppDetailCache.HostKey(appID: app, scope: .all, kind: .domain, value: $0)
        }
        let process = HostProcess(path: "/usr/bin/curl", name: "curl", firstSeen: .now, lastSeen: .now, requestCount: 1, deviceIDs: [])
        for key in keys { cache.setProcesses([process], for: key) }
        #expect(cache.processes(keys[0]) == nil)
        #expect(cache.processes(keys[2])?.count == 1)
        #expect(cache.processes(AppDetailCache.HostKey(appID: app, scope: .device(UUID()), kind: .domain, value: "c.example.com")) == nil)
        cache.removeAll()
        #expect(cache.processes(keys[2]) == nil)
    }

    /// An IP stays selected while it is one of the app's IPs, and a cached list fits a selected IP it has.
    @Test func anIPStaysSelectedWhileTheAppHasIt() {
        let now = Date()
        let hosts = [
            AppHost(appID: UUID(), kind: .domain, value: "api2.cursor.sh", site: "cursor.sh", firstSeen: now, lastSeen: now, requestCount: 1,
                    processName: nil, policy: nil, geo: nil, isDirect: false, hosts: []),
            AppHost(appID: UUID(), kind: .ip, value: "104.18.19.125", site: nil, firstSeen: now, lastSeen: now, requestCount: 1,
                    processName: nil, policy: nil, geo: nil, isDirect: false, hosts: ["api2.cursor.sh"]),
        ]
        let summary = AppDetailInventorySummary(hosts: hosts, search: "", now: now, site: { $0 })
        #expect(summary.selectedIP("104.18.19.125") == "104.18.19.125")
        #expect(summary.selectedIP("api2.cursor.sh") == nil)
        #expect(summary.selectedHost("104.18.19.125") == nil)
        #expect(summary.selectedIP("10.0.0.1") == nil && summary.selectedIP(nil) == nil)
        let inventory = AppDetailCache.Inventory(hosts: hosts, summary: summary)
        #expect(inventory.fits(search: "", selectedHost: "api2.cursor.sh", selectedIP: "104.18.19.125"))
        // An IP selected after the list was cached, like the new IP a notification's View opens.
        #expect(!inventory.fits(search: "", selectedHost: nil, selectedIP: "10.0.0.1"))
    }

    /// A process's tile comes from the bundle it lives in.
    @Test func findsTheBundleAProcessLivesIn() {
        #expect(AppDetailProcessPath.bundle(of: "/Applications/Docker.app/Contents/MacOS/com.docker.backend") == "/Applications/Docker.app")
        #expect(AppDetailProcessPath.bundle(of: "/Applications/Cursor.app/Contents/Frameworks/Cursor Helper (Plugin).app/Contents/MacOS/Cursor Helper (Plugin)")
            == "/Applications/Cursor.app")
        #expect(AppDetailProcessPath.bundle(of: "/usr/local/bin/node") == nil)
        #expect(AppDetailProcessPath.bundle(of: "/Applications/Thing.application/bin/x") == nil)
    }

    /// The processes of a selected IP show First seen only in an IP pane wide enough to keep their names 200 px: not in
    /// the default window's, which has its Last seen and a tooltip for it, but in a wider one.
    @Test func ipProcessesShowFirstSeenWhenThePaneHasRoom() {
        let page = MainWindowFrame.designSize.width - 244
        let split = AppDetailInventoryTab.split(page, factor: 1)
        #expect(!AppDetailInventoryTab.ipProcessesShowFirstSeen(page - split.domainsWidth - 0.5, factor: 1))
        let wide = AppDetailInventoryTab.split(1_700, factor: 1)
        #expect(AppDetailInventoryTab.ipProcessesShowFirstSeen(1_700 - wide.domainsWidth - 0.5, factor: 1))
    }
}
