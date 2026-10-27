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

    /// A list shows what the cache had for its address while the database reads it, then what it read; a failed read
    /// keeps a list and otherwise says why, until Try Again reads again.
    @Test func aListStartsFromTheCacheAndFollowsTheDatabase() async throws {
        let defaults = TestDefaults()
        let model = AppModel(preferences: Preferences(defaults: defaults.make()))
        let cursor = F.cursor.id
        let key = AppDetailCache.HostKey(appID: cursor, scope: .all, kind: .domain, value: "api2.cursor.sh")
        let curl = HostProcess(path: "/usr/bin/curl", name: "curl", firstSeen: .now, lastSeen: .now, requestCount: 1, deviceIDs: [F.thisMac])
        let node = HostProcess(path: "/usr/local/bin/node", name: "node", firstSeen: .now, lastSeen: .now, requestCount: 2, deviceIDs: [F.thisMac])
        let cache = AppDetailCache()
        cache.setProcesses([curl], for: key)
        let processes = AppDetailHostProcesses()

        // The cached list from the start, while a slow read runs, then the list read.
        #expect(processes.shown(key, cache: cache) == AppDetailHostProcesses.Shown(key: key, processes: [curl]))
        model.database = RequestsStubDatabase(processes: { kind, value in
            try await Task.sleep(for: .milliseconds(300))
            return kind == .domain && value == "api2.cursor.sh" ? [node] : []
        })
        let reading = Task { await processes.follow(key, model: model, cache: cache) }
        try await Task.sleep(for: .milliseconds(100))
        #expect(processes.shown(key, cache: cache).processes == [curl])
        try await eventually { processes.shown(key, cache: cache).processes == [node] }
        #expect(processes.shown(key, cache: cache).processes == [node])
        #expect(cache.processes(key) == [node])
        reading.cancel()
        await reading.value

        // A read that fails keeps the list shown; with none, the list says why.
        model.database = RequestsStubDatabase(processes: { _, _ in throw DatabaseError.unreachable(.poolClosed) })
        let failing = Task { await processes.follow(key, model: model, cache: cache) }
        try await Task.sleep(for: .milliseconds(100))
        #expect(processes.shown(key, cache: cache) == AppDetailHostProcesses.Shown(key: key, processes: [node]))
        failing.cancel()
        await failing.value
        let ipKey = AppDetailCache.HostKey(appID: cursor, scope: .all, kind: .ip, value: "104.18.19.125")
        let ip = AppDetailHostProcesses()
        #expect(ip.shown(ipKey, cache: cache) == AppDetailHostProcesses.Shown(key: ipKey))
        let failingIP = Task { await ip.follow(ipKey, model: model, cache: cache) }
        try await eventually { ip.shown(ipKey, cache: cache).failure != nil }
        #expect(ip.shown(ipKey, cache: cache).processes == nil)
        #expect(ip.shown(ipKey, cache: cache).failure == CaptureEngine.message(for: DatabaseError.unreachable(.poolClosed)))
        failingIP.cancel()
        await failingIP.value

        // Try Again: loading again, then what the read gives.
        ip.retry()
        #expect(ip.attempt == 1 && processes.attempt == 0)
        model.database = RequestsStubDatabase(processes: { _, _ in
            try await Task.sleep(for: .milliseconds(300))
            return [curl]
        })
        let again = Task { await ip.follow(ipKey, model: model, cache: cache) }
        try await Task.sleep(for: .milliseconds(100))
        #expect(ip.shown(ipKey, cache: cache) == AppDetailHostProcesses.Shown(key: ipKey))
        try await eventually { ip.shown(ipKey, cache: cache).processes == [curl] }
        #expect(ip.shown(ipKey, cache: cache).processes == [curl])
        again.cancel()
        await again.value
    }

    /// A list shows only its own address's processes: what was read for another address (the list's app, scope or
    /// address changed under it) gives way to what the cache has for its own, or to nothing, never to another list.
    @Test func aListShowsOnlyItsOwnAddress() async throws {
        let defaults = TestDefaults()
        let model = AppModel(preferences: Preferences(defaults: defaults.make()))
        let cursor = F.cursor.id
        let api = AppDetailCache.HostKey(appID: cursor, scope: .all, kind: .domain, value: "api2.cursor.sh")
        let onMini = AppDetailCache.HostKey(appID: cursor, scope: .device(F.otherMac), kind: .domain, value: "api2.cursor.sh")
        let push = AppDetailCache.HostKey(appID: cursor, scope: .all, kind: .domain, value: "courier.push.apple.com")
        let node = HostProcess(path: "/usr/local/bin/node", name: "node", firstSeen: .now, lastSeen: .now, requestCount: 2, deviceIDs: [F.thisMac])
        let cursorProcess = HostProcess(path: "/Applications/Cursor.app/Contents/MacOS/Cursor", name: "Cursor", firstSeen: .now, lastSeen: .now,
                                        requestCount: 27, deviceIDs: [F.thisMac])
        let cache = AppDetailCache()
        cache.setProcesses([cursorProcess], for: push)
        model.database = RequestsStubDatabase(processes: { _, value in value == "api2.cursor.sh" ? [node] : [cursorProcess] })
        let processes = AppDetailHostProcesses()
        let reading = Task { await processes.follow(api, model: model, cache: cache) }
        try await eventually { processes.shown(api, cache: cache).processes == [node] }
        reading.cancel()
        await reading.value

        #expect(processes.shown(api, cache: cache).processes == [node])
        #expect(processes.shown(push, cache: cache) == AppDetailHostProcesses.Shown(key: push, processes: [cursorProcess]))
        #expect(processes.shown(onMini, cache: cache) == AppDetailHostProcesses.Shown(key: onMini))
    }

    /// A read that answers with the list the cache gave changes nothing the rows observe, so they are not drawn again.
    @Test func aReadOfTheCachedListLeavesTheRowsAlone() async throws {
        let defaults = TestDefaults()
        let model = AppModel(preferences: Preferences(defaults: defaults.make()))
        let key = AppDetailCache.HostKey(appID: F.cursor.id, scope: .all, kind: .domain, value: "api2.cursor.sh")
        let node = HostProcess(path: "/usr/local/bin/node", name: "node", firstSeen: .now, lastSeen: .now, requestCount: 2, deviceIDs: [F.thisMac])
        let cache = AppDetailCache()
        cache.setProcesses([node], for: key)
        let answered = Counter()
        model.database = RequestsStubDatabase(processes: { _, _ in
            await answered.add()
            return [node]
        })
        let processes = AppDetailHostProcesses()
        let changed = Counter()
        withObservationTracking {
            _ = processes.shown(key, cache: cache)
        } onChange: {
            Task { await changed.add() }
        }
        let reading = Task { await processes.follow(key, model: model, cache: cache) }
        for _ in 0..<100 where await answered.value == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        try await Task.sleep(for: .milliseconds(50))
        reading.cancel()
        await reading.value
        #expect(await answered.value == 1)
        #expect(await changed.value == 0)
        #expect(processes.shown(key, cache: cache).processes == [node])
    }

    /// Another app's page opens with nothing selected while the same app's keeps its selection, so its cached list fits;
    /// an alert's View selects its domain or IP in the app it opens.
    @Test func anotherAppsPageOpensWithNothingSelected() {
        let nav = Navigation()
        let cursor = UUID(), raycast = UUID()
        nav.open(.app(cursor), tab: .inventory)
        nav.appSelectedHost = "api2.cursor.sh"
        nav.appSelectedIP = "104.18.19.125"
        nav.open(.requests)
        nav.open(.app(cursor))
        #expect(nav.appSelectedHost == "api2.cursor.sh" && nav.appSelectedIP == "104.18.19.125")
        nav.page = .app(raycast)
        #expect(nav.appSelectedHost == nil && nav.appSelectedIP == nil)
        nav.appSelectedIP = "8.8.8.8"
        nav.open(cursor, selecting: .ip, "17.57.146.20")
        #expect(nav.page == .app(cursor) && nav.appTab == .inventory)
        #expect(nav.appSelectedHost == nil && nav.appSelectedIP == "17.57.146.20")
        nav.open(cursor, selecting: .domain, "courier.push.apple.com")
        #expect(nav.appSelectedHost == "courier.push.apple.com" && nav.appSelectedIP == nil)
    }

    /// An alert's View clears what could hide its row in the tab (the search, the Direct / From domains switch, another
    /// domain's filter) and asks the tab to bring the row into view, again on every View; selecting another domain or IP,
    /// or another app's page, ends that.
    @Test func anAlertsViewClearsWhatWouldHideItsRow() throws {
        let nav = Navigation()
        let claude = UUID()
        nav.open(.app(claude), tab: .requests)
        nav.appInventorySearch = "anthropic"
        nav.appIPFilter = .direct
        nav.appSelectedHost = "api.anthropic.com"
        nav.open(claude, selecting: .ip, "18.97.36.52")
        #expect(nav.appTab == .inventory && nav.appInventorySearch.isEmpty && nav.appIPFilter == .all)
        #expect(nav.appSelectedHost == nil && nav.appSelectedIP == "18.97.36.52")
        let first = try #require(nav.appArrival)
        #expect(first.appID == claude && first.kind == .ip && first.value == "18.97.36.52")

        nav.appArrival = nil
        nav.open(claude, selecting: .ip, "18.97.36.52")
        #expect(nav.appArrival.map(\.serial) == first.serial + 1, "View again brings the row into view again")
        nav.appSelectedIP = nil
        #expect(nav.appArrival == nil)

        nav.appIPFilter = .resolved
        nav.open(claude, selecting: .domain, "claude.ai")
        #expect(nav.appSelectedHost == "claude.ai" && nav.appSelectedIP == nil && nav.appIPFilter == .all)
        #expect(nav.appArrival?.kind == .domain)
        nav.appSelectedHost = "api.anthropic.com"
        #expect(nav.appArrival == nil)
        nav.open(claude, selecting: .domain, "claude.ai")
        nav.page = .app(UUID())
        #expect(nav.appArrival == nil)
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

/// Counts what happened across tasks.
private actor Counter {
    private(set) var value = 0

    func add() { value += 1 }
}
