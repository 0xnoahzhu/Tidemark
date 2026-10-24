import Foundation
import Testing
@testable import Tidemark

struct CaptureAttributionTests {
    let boot = Date(timeIntervalSince1970: 1_792_000_000)

    /// Cursor (812) → Cursor Helper (Plugin) (851) → node (1201) → git (1288)
    var table: CaptureFakeProcesses {
        CaptureFakeProcesses([
            LiveProcess(pid: 812, parentPID: 1, name: "Cursor", path: "/Applications/Cursor.app/Contents/MacOS/Cursor", startTime: boot),
            LiveProcess(pid: 851, parentPID: 812, name: "Cursor Helper (Plugin)",
                        path: "/Applications/Cursor.app/Contents/Frameworks/Cursor Helper (Plugin).app/Contents/MacOS/Cursor Helper (Plugin)",
                        startTime: boot.addingTimeInterval(1)),
            LiveProcess(pid: 1201, parentPID: 851, name: "node", path: "/usr/local/bin/node", startTime: boot.addingTimeInterval(2)),
            LiveProcess(pid: 1288, parentPID: 1201, name: "git", path: "/usr/bin/git", startTime: boot.addingTimeInterval(3)),
        ])
    }

    @Test func rollsUpThroughParentProcesses() {
        let cursor = CaptureFixtures.app("Cursor", path: "/Applications/Cursor.app")
        var attributor = CaptureAttributor(isRemote: false)
        attributor.setApps([cursor])
        let chain = attributor.chain(pid: 1288, processPath: "/usr/bin/git", startedAt: boot.addingTimeInterval(60), inspector: table)
        #expect(chain.map(\.name) == ["Cursor", "Cursor Helper (Plugin)", "node", "git"])

        let result = attributor.attribute(chain: chain, pathForStatistics: "/usr/bin/git")
        #expect(result.appID == cursor.id)
        #expect(result.matchedIndex == 1, "the nearest process inside the bundle is the helper")
        #expect(result.bundlePath == "/Applications/Cursor.app")
    }

    @Test func appsWithoutChildrenOnlyMatchTheLeaf() {
        let cursor = CaptureFixtures.app("Cursor", path: "/Applications/Cursor.app", includeChildren: false)
        var attributor = CaptureAttributor(isRemote: false)
        attributor.setApps([cursor])
        let viaNode = attributor.chain(pid: 1201, processPath: "/usr/local/bin/node", startedAt: boot.addingTimeInterval(60), inspector: table)
        #expect(attributor.attribute(chain: viaNode, pathForStatistics: nil).appID == nil)

        let helper = attributor.chain(pid: 851, processPath: nil, startedAt: boot.addingTimeInterval(60), inspector: table)
        #expect(attributor.attribute(chain: helper, pathForStatistics: nil).appID == cursor.id)
    }

    @Test func prefersTheMostSpecificNestedBundle() {
        let cursor = CaptureFixtures.app("Cursor", path: "/Applications/Cursor.app")
        let helper = CaptureFixtures.app("Plugin Host", path: "/Applications/Cursor.app/Contents/Frameworks/Cursor Helper (Plugin).app")
        var attributor = CaptureAttributor(isRemote: false)
        attributor.setApps([cursor, helper])
        let chain = attributor.chain(pid: 851, processPath: nil, startedAt: boot.addingTimeInterval(60), inspector: table)
        #expect(attributor.attribute(chain: chain, pathForStatistics: nil).appID == helper.id)
    }

    @Test func ignoresArchivedApps() {
        var cursor = CaptureFixtures.app("Cursor", path: "/Applications/Cursor.app")
        cursor.archivedAt = .now
        var attributor = CaptureAttributor(isRemote: false)
        attributor.setApps([cursor])
        let chain = attributor.chain(pid: 851, processPath: nil, startedAt: boot.addingTimeInterval(60), inspector: table)
        #expect(attributor.attribute(chain: chain, pathForStatistics: "/Applications/Cursor.app/").appID == nil)
    }

    @Test func fallsBackWhenThePIDWasReused() {
        var attributor = CaptureAttributor(isRemote: false)
        // The request started before the live process with that PID did.
        let chain = attributor.chain(pid: 1288, processPath: "/usr/bin/curl", startedAt: boot, inspector: table)
        #expect(chain == [ProcessLink(name: "curl", pid: 1288, path: "/usr/bin/curl", startTime: nil)])
    }

    @Test func keepsTheChainOfAnExitedProcess() {
        var attributor = CaptureAttributor(isRemote: false)
        let first = attributor.chain(pid: 1201, processPath: "/usr/local/bin/node", startedAt: boot.addingTimeInterval(60), inspector: table)
        #expect(first.count == 3)
        // node exits; a later update of the same request still gets its cached ancestry.
        let gone = CaptureFakeProcesses()
        let again = attributor.chain(pid: 1201, processPath: "/usr/local/bin/node", startedAt: boot.addingTimeInterval(61), inspector: gone)
        #expect(again == first)
    }

    @Test func attributesRemoteSurgeByPathsOnly() {
        let grok = CaptureFixtures.app("Grok Bot", path: "/Applications/Grok Bot.app")
        var attributor = CaptureAttributor(isRemote: true)
        attributor.setApps([grok])
        // The local table must not be consulted for a remote Surge.
        let chain = attributor.chain(pid: 851, processPath: "/usr/local/bin/node", startedAt: boot.addingTimeInterval(60), inspector: table)
        #expect(chain.map(\.name) == ["node"])
        let byStats = attributor.attribute(chain: chain, pathForStatistics: "/Applications/Grok Bot.app/")
        #expect(byStats.appID == grok.id)
        #expect(byStats.bundlePath == "/Applications/Grok Bot.app")

        let leaf = attributor.chain(pid: 9, processPath: "/Applications/Grok Bot.app/Contents/MacOS/Grok Bot", startedAt: .now, inspector: table)
        #expect(attributor.attribute(chain: leaf, pathForStatistics: nil).appID == grok.id)
    }

    @Test func bumpsTheVersionOnlyWhenAppsChange() {
        let cursor = CaptureFixtures.app("Cursor", path: "/Applications/Cursor.app")
        var attributor = CaptureAttributor(isRemote: false)
        attributor.setApps([cursor])
        let version = attributor.appsVersion
        attributor.setApps([cursor])
        #expect(attributor.appsVersion == version)
        attributor.setApps([])
        #expect(attributor.appsVersion != version)
    }
}
