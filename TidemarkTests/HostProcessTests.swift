import Foundation
import Testing
@testable import Tidemark

// The processes that reached one of an app's domains or IPs (`hostProcesses`), merged by executable path across Macs.

@Suite struct HostProcessMergeTests {
    static let now = Date(timeIntervalSince1970: 1_761_400_000)
    static let mac = UUID(uuidString: "00000000-0000-0000-0000-0000000000F1")!
    static let mini = UUID(uuidString: "00000000-0000-0000-0000-0000000000F2")!

    static func sighting(_ path: String, _ title: String, device: DeviceID = mac, first: Double = -72, last: Double = -1,
                         requests: Int64 = 1) -> HostProcess.Sighting {
        HostProcess.Sighting(deviceID: device, path: path, title: title, firstSeen: now.addingTimeInterval(first * 3600),
                             lastSeen: now.addingTimeInterval(last * 3600), requestCount: requests)
    }

    /// Each Mac's row of a path merges into one process: requests added up, the earliest first seen and the latest last
    /// seen, the name the latest gave it, and the Macs, the one that saw it last first.
    @Test func mergesEveryMacsRowsOfAPath() throws {
        let processes = HostProcess.merge([
            Self.sighting("/usr/local/bin/node", "node", device: Self.mac, first: -50, last: -3, requests: 5),
            Self.sighting("/usr/local/bin/node", "node (renamed)", device: Self.mini, first: -30, last: -1, requests: 7),
            Self.sighting("/Applications/Cursor.app/Contents/MacOS/Cursor", "Cursor", device: Self.mini, requests: 2),
        ], now: Self.now)
        #expect(processes.count == 2)
        let node = try #require(processes.first)
        #expect(node.path == "/usr/local/bin/node" && node.name == "node (renamed)")
        #expect(node.requestCount == 12)
        #expect(node.firstSeen == Self.now.addingTimeInterval(-50 * 3600))
        #expect(node.lastSeen == Self.now.addingTimeInterval(-3600))
        #expect(node.deviceIDs == [Self.mini, Self.mac])
        #expect(processes[1].deviceIDs == [Self.mini])
        #expect(!node.isNew(now: Self.now))
    }

    /// Like the tab's domains: what first reached the address in the last 24 hours, then the busiest, then the most
    /// recent, then by path; requests whose process Surge never named last, merged however they were stored.
    @Test func ordersNewThenBusiestThenRecentAndUnreportedLast() {
        let processes = HostProcess.merge([
            Self.sighting("", "MacBook Pro", requests: 500),
            Self.sighting("unknown", "Mac mini", device: Self.mini, last: -3, requests: 5),
            Self.sighting("/usr/bin/curl", "curl", requests: 10),
            Self.sighting("/usr/bin/git", "git", last: -5, requests: 40),
            Self.sighting("/usr/bin/ssh", "ssh", last: -2, requests: 40),
            Self.sighting("/usr/bin/nc", "nc", last: -2, requests: 40),
            Self.sighting("/usr/bin/new", "new", first: -2, requests: 1),
        ], now: Self.now)
        #expect(processes.map(\.name) == ["new", "nc", "ssh", "git", "curl", "MacBook Pro"])
        #expect(processes[0].isNew(now: Self.now))
        let unreported = processes.last
        #expect(unreported?.isUnreported == true && unreported?.requestCount == 505)
        #expect(HostProcess.merge([Self.sighting("/usr/bin/a", "a"), Self.sighting("/usr/bin/b", "b")], now: Self.now, limit: 1).count == 1)
    }

    /// One Mac lists the processes it reported, with its own counts.
    @Test func oneMacKeepsItsOwnRows() {
        let sightings = [
            Self.sighting("/usr/local/bin/node", "node", device: Self.mac, requests: 5),
            Self.sighting("/usr/local/bin/node", "node", device: Self.mini, requests: 7),
            Self.sighting("/usr/bin/curl", "curl", device: Self.mac, requests: 9),
        ]
        let onMini = HostProcess.merge(sightings, scope: .device(Self.mini), now: Self.now)
        #expect(onMini.map(\.requestCount) == [7] && onMini.first?.deviceIDs == [Self.mini])
        #expect(HostProcess.merge(sightings, scope: .all, now: Self.now).map(\.requestCount) == [12, 9])
        #expect(HostProcess.merge([], now: Self.now).isEmpty)
    }
}

/// The demo database lists the processes the demo's requests came from, as capture records them in `host_sources`.
@Suite @MainActor struct HostProcessDemoTests {
    typealias F = UIMainFixtures

    /// The demo lists, for an app's domain or IP, the processes its requests came from, merged across Macs; another
    /// app's requests and the site probe's are not the app's.
    @Test func theDemoListsTheProcessesOfAnAppsRequests() async throws {
        let cursor = F.cursor.id
        let helperChain = Array(F.cursorChain.prefix(2))
        var probed = F.record(id: 6, chain: F.cursorChain, appID: cursor)
        probed.probeSessionID = UUID()
        let database = ShellDemoDatabase(rows: [
            F.record(id: 1, chain: F.cursorChain, appID: cursor, startedAt: Date(timeIntervalSince1970: 1_729_750_000)),
            F.record(id: 2, device: F.otherMac, chain: F.cursorChain, appID: cursor, startedAt: Date(timeIntervalSince1970: 1_729_750_100)),
            F.record(id: 3, chain: helperChain, appID: cursor),
            F.record(id: 4, host: "registry.npmjs.org", ip: "104.18.19.125", chain: F.cursorChain, appID: cursor),
            F.record(id: 5, chain: F.cursorChain),
            probed,
        ])
        let domain = try await database.hostProcesses(kind: .domain, value: "api2.cursor.sh", appID: cursor, scope: .all)
        #expect(domain.map(\.name) == ["node", "Cursor Helper (Plugin)"])
        #expect(domain.first?.requestCount == 2 && domain.first?.deviceIDs == [F.otherMac, F.thisMac])
        // The IP counts the requests to every domain that resolved to it.
        let ip = try await database.hostProcesses(kind: .ip, value: "104.18.19.125", appID: cursor, scope: .all)
        #expect(ip.map { "\($0.name) \($0.requestCount)" } == ["node 3", "Cursor Helper (Plugin) 1"])
        let otherMac = try await database.hostProcesses(kind: .domain, value: "api2.cursor.sh", appID: cursor, scope: .device(F.otherMac))
        #expect(otherMac.map { "\($0.name) \($0.requestCount)" } == ["node 1"])
    }

    /// The demo's apps reach some addresses from several processes, some of them from more than one Mac, and others
    /// from one process.
    @Test func theDemoAppsReachAddressesFromOneOrSeveralProcesses() async throws {
        let defaults = TestDefaults()
        let model = AppModel(preferences: Preferences(defaults: defaults.make()))
        ShellDemoData.install(into: model)
        let cursor = try #require(model.catalog.apps.first { $0.name == "Cursor" })
        let api = try await model.database.hostProcesses(kind: .domain, value: "api2.cursor.sh", appID: cursor.id, scope: .all)
        #expect(api.count == 3, "\(api.map(\.name))")
        #expect(api.contains { $0.deviceIDs.count > 1 }, "\(api.map(\.deviceIDs))")
        #expect(api.allSatisfy { cursor.contains(processPath: $0.path) || $0.path == "/usr/local/bin/node" })
        let ip = try await model.database.hostProcesses(kind: .ip, value: "104.18.19.125", appID: cursor.id, scope: .all)
        #expect(ip.count == 3)
        let push = try await model.database.hostProcesses(kind: .domain, value: "courier.push.apple.com", appID: cursor.id, scope: .all)
        #expect(push.map(\.name) == ["Cursor"])
    }
}
