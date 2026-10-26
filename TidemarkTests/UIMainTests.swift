import AppKit
import Foundation
import SwiftUI
import Synchronization
import Testing
@testable import Tidemark

/// Builds request records for the main-window tests.
enum UIMainFixtures {
    static let thisMac = UUID(uuidString: "00000000-0000-0000-0000-0000000000F1")!
    static let otherMac = UUID(uuidString: "00000000-0000-0000-0000-0000000000F2")!

    static let cursor = MonitoredApp(
        id: UUID(uuidString: "00000000-0000-0000-0000-0000000000C1")!, name: "Cursor", path: "/Applications/Cursor.app",
        bundleID: nil, tileLetter: "C", tileHue: 260, includeChildren: true, alertRule: .site, alertNewIP: true,
        archivedAt: nil, createdAt: .distantPast
    )

    static func record(
        id: Int64,
        host: String = "api2.cursor.sh",
        ip: String? = "104.18.19.125",
        method: String = "HTTPS",
        state: RequestState = .completed,
        device: DeviceID = thisMac,
        chain: [ProcessLink] = [],
        appID: AppID? = nil,
        bundle: String? = nil,
        policy: [String] = ["DIRECT"],
        startedAt: Date = Date(timeIntervalSince1970: 1_729_750_000),
        processPath: String? = nil
    ) -> RequestRecord {
        RequestRecord(
            key: RequestKey(deviceID: device, session: 1, surgeID: id), rowID: id, startedAt: startedAt,
            setupCompletedAt: nil, completedAt: state == .active ? nil : startedAt.addingTimeInterval(0.2),
            method: method, host: host, port: 443, url: host + ":443", remoteIP: ip, remoteAddress: ip, geo: nil,
            policyPath: policy, rule: nil, state: state, inBytes: 1000, outBytes: 24, pid: chain.last?.pid,
            processPath: processPath ?? chain.last?.path, bundlePath: bundle, chain: chain, appID: appID, localAddress: nil,
            interface: nil, notes: [], isNew: false, writtenAt: nil, probeSessionID: nil
        )
    }

    static let cursorChain = [
        ProcessLink(name: "Cursor", pid: 812, path: "/Applications/Cursor.app/Contents/MacOS/Cursor"),
        ProcessLink(name: "Cursor Helper (Plugin)", pid: 851, path: "/Applications/Cursor.app/Contents/Frameworks/Cursor Helper (Plugin).app/Contents/MacOS/Cursor Helper (Plugin)"),
        ProcessLink(name: "node", pid: 1201, path: "/usr/local/bin/node"),
    ]

    static func identity(_ record: RequestRecord) -> AppIdentity {
        if record.appID == cursor.id {
            return AppIdentity(name: "Cursor", bundlePath: cursor.path, letter: "C", hue: 260, isMonitored: true, appID: cursor.id)
        }
        return AppIdentity(name: record.processName, bundlePath: nil, letter: "?", hue: nil, isMonitored: false, appID: nil)
    }
}

struct RequestsPresentationTests {
    typealias F = UIMainFixtures

    @Test func filtersLiveRowsByScopeAndSearch() {
        let rows = [
            F.record(id: 1, host: "api2.cursor.sh", chain: F.cursorChain, appID: F.cursor.id),
            F.record(id: 2, host: "github.com", ip: "20.205.243.166", device: F.otherMac),
            F.record(id: 3, host: "res.wx.qq.com", ip: "58.251.111.103", chain: [ProcessLink(name: "WeChat", pid: 9, path: "/Applications/WeChat.app/Contents/MacOS/WeChat")]),
        ]
        let all = RequestsPresentation.liveRows(rows, scope: .all, search: "", identity: F.identity)
        #expect(all.map(\.key.surgeID) == [1, 2, 3])

        let thisMac = RequestsPresentation.liveRows(rows, scope: .device(F.thisMac), search: "", identity: F.identity)
        #expect(thisMac.map(\.key.surgeID) == [1, 3])

        #expect(RequestsPresentation.liveRows(rows, scope: .all, search: "20.205", identity: F.identity).map(\.key.surgeID) == [2])
        #expect(RequestsPresentation.liveRows(rows, scope: .all, search: " WECHAT ", identity: F.identity).map(\.key.surgeID) == [3])
        #expect(RequestsPresentation.liveRows(rows, scope: .all, search: "node", identity: F.identity).map(\.key.surgeID) == [1])
        #expect(RequestsPresentation.liveRows(rows, scope: .all, search: "cursor", identity: F.identity).map(\.key.surgeID) == [1])
    }

    @Test func mapsStatus() {
        #expect(RequestsPresentation.status(of: F.record(id: 1, method: "HTTPS")) == .tunnel)
        #expect(RequestsPresentation.status(of: F.record(id: 1, method: "HTTPS", state: .active)) == .tunnel)
        #expect(RequestsPresentation.status(of: F.record(id: 1, method: "GET")) == nil)
        #expect(RequestsPresentation.status(of: F.record(id: 1, method: "GET", state: .active)) == nil)
        #expect(RequestsPresentation.status(of: F.record(id: 1, state: .failed)) == .failed)
        #expect(RequestsPresentation.status(of: F.record(id: 1, state: .rejected)) == .failed)
    }

    @Test func describesAttribution() {
        let rolled = F.record(id: 1, chain: F.cursorChain, appID: F.cursor.id)
        #expect(RequestsPresentation.attribution(for: rolled, app: F.cursor, displayName: "Cursor") == .rolledUp(app: "Cursor", parents: 2))

        let direct = F.record(id: 2, chain: [F.cursorChain[0]], appID: F.cursor.id)
        #expect(RequestsPresentation.attribution(for: direct, app: F.cursor, displayName: "Cursor") == .direct(app: "Cursor"))

        let helper = F.record(id: 3, chain: Array(F.cursorChain.prefix(2)), appID: F.cursor.id)
        #expect(RequestsPresentation.attribution(for: helper, app: F.cursor, displayName: "Cursor") == .rolledUp(app: "Cursor", parents: 1))

        let spotify = F.record(id: 4, chain: [ProcessLink(name: "Spotify", pid: 7, path: "/Applications/Spotify.app/Contents/MacOS/Spotify")])
        #expect(RequestsPresentation.attribution(for: spotify, app: nil, displayName: "Spotify") == .unmonitored(app: "Spotify"))
    }

    @Test func fallsBackToTheLeafWithoutAChain() {
        let record = F.record(id: 1, chain: [], processPath: "/usr/bin/curl")
        let links = RequestsPresentation.chainLinks(for: record)
        #expect(links.count == 1)
        #expect(links[0].name == "curl")
    }

    @Test func leavesUnknownProcessesToTheView() {
        // QUIC / UDP flows can arrive without a PID: no chain, no path, no bundle.
        let quic = F.record(id: 1, host: "apple-relay.cloudflare.com", method: "QUIC")
        #expect(RequestsPresentation.processName(of: quic) == nil)
        #expect(RequestsPresentation.chainLinks(for: quic).map(\.name) == [""])

        let placeholder = AppIdentity(name: "Unknown", bundlePath: nil, letter: "U", hue: nil, isMonitored: false, appID: nil)
        #expect(RequestsPresentation.isUnattributed(quic, identity: placeholder))
        let shown = RequestsPresentation.displayIdentity(placeholder, for: quic, unknownName: "未知进程")
        #expect(shown.name == "未知进程")
        #expect(shown.letter == "?")

        // The placeholder is not data: searching for it finds nothing.
        #expect(!RequestsPresentation.matches(quic, needle: "unknown", appName: ""))

        // Anything that names the sender keeps its identity.
        let curl = F.record(id: 2, processPath: "/usr/bin/curl")
        let curlIdentity = AppIdentity(name: "curl", bundlePath: nil, letter: "c", hue: nil, isMonitored: false, appID: nil)
        #expect(RequestsPresentation.processName(of: curl) == "curl")
        #expect(RequestsPresentation.displayIdentity(curlIdentity, for: curl, unknownName: "?") == curlIdentity)
        let spotify = F.record(id: 3, bundle: "/Applications/Spotify.app")
        let spotifyIdentity = AppIdentity(name: "Spotify", bundlePath: "/Applications/Spotify.app", letter: "S", hue: nil, isMonitored: false, appID: nil)
        #expect(!RequestsPresentation.isUnattributed(spotify, identity: spotifyIdentity))
    }

    @MainActor
    @Test func localizesTheUnknownProcess() {
        let suite = "tidemark-tests-\(UUID().uuidString)"
        let model = AppModel(preferences: Preferences(defaults: UserDefaults(suiteName: suite)!))
        let quic = F.record(id: 1, method: "QUIC")
        let saved = Localizer.shared.override
        defer {
            Localizer.shared.override = saved
            TestDefaults.remove(suite)
        }

        Localizer.shared.override = "en"
        #expect(model.requestsIdentity(for: quic).name == "Unknown process")
        Localizer.shared.override = "zh-Hans"
        guard Localizer.shared.bundle != nil else { return }
        #expect(model.requestsIdentity(for: quic).name == "未知进程")
    }

    @Test func detectsFreshRows() {
        let start = Date(timeIntervalSince1970: 1_000)
        let record = F.record(id: 1, startedAt: start)
        #expect(RequestsPresentation.isFresh(record, now: start.addingTimeInterval(1)))
        #expect(!RequestsPresentation.isFresh(record, now: start.addingTimeInterval(2)))
    }

    @Test func encodesJSON() throws {
        let json = RequestsPresentation.json(for: F.record(id: 42, host: "api.github.com"))
        let object = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        #expect(object["host"] as? String == "api.github.com")
        #expect(json.contains("\n"))
    }
}

@MainActor
struct RequestsRowTintTests {
    typealias F = UIMainFixtures

    /// A row view with a separator-like view and two cells, the first hosting the tint anchor.
    private func makeRow() -> (row: NSTableRowView, firstCell: NSTableCellView, anchor: RequestsRowTintAnchor) {
        let row = NSTableRowView(frame: NSRect(x: 0, y: 0, width: 600, height: 24))
        row.addSubview(NSView(frame: row.bounds))
        let firstCell = NSTableCellView(frame: NSRect(x: 16, y: 0, width: 86, height: 24))
        let secondCell = NSTableCellView(frame: NSRect(x: 119, y: 0, width: 200, height: 24))
        row.addSubview(firstCell)
        row.addSubview(secondCell)
        let host = NSView(frame: firstCell.bounds)
        firstCell.addSubview(host)
        let anchor = RequestsRowTintAnchor(frame: host.bounds)
        host.addSubview(anchor)
        return (row, firstCell, anchor)
    }

    private func band(in row: NSTableRowView) -> RequestsRowBand? {
        row.subviews.compactMap { $0 as? RequestsRowBand }.first
    }

    @Test func tintsTheWholeRowBelowTheCells() throws {
        let (row, firstCell, anchor) = makeRow()
        anchor.apply(key: F.record(id: 1).key, isFresh: true, animated: true)

        let band = try #require(band(in: row))
        #expect(band.alphaValue == 1)
        #expect(band.frame == row.bounds.insetBy(dx: RequestsRowBand.horizontalInset, dy: 0))
        let bandIndex = try #require(row.subviews.firstIndex(of: band))
        let cellIndex = try #require(row.subviews.firstIndex(of: firstCell))
        #expect(bandIndex < cellIndex)
        #expect(bandIndex > 0, "above the row's own background views")

        // Updating again reuses the same band.
        anchor.apply(key: F.record(id: 1).key, isFresh: true, animated: true)
        #expect(row.subviews.filter { $0 is RequestsRowBand }.count == 1)
    }

    @Test func clearsAtOnceForAnotherRequest() throws {
        let (row, _, anchor) = makeRow()
        anchor.apply(key: F.record(id: 1).key, isFresh: true, animated: true)
        let band = try #require(band(in: row))

        // The row view now shows another request that is not fresh: no fade, no leftover tint.
        anchor.apply(key: F.record(id: 2).key, isFresh: false, animated: true)
        #expect(band.alphaValue == 0)
        #expect(band.key == F.record(id: 2).key)

        // The same request aging out fades to clear.
        anchor.apply(key: F.record(id: 3).key, isFresh: true, animated: true)
        #expect(band.alphaValue == 1)
        anchor.apply(key: F.record(id: 3).key, isFresh: false, animated: true)
        #expect(band.alphaValue == 0)
    }

    @Test func doesNothingOutsideATableRow() {
        let anchor = RequestsRowTintAnchor(frame: .zero)
        anchor.apply(key: F.record(id: 1).key, isFresh: true, animated: true)
        #expect(anchor.subviews.isEmpty)
    }
}

@MainActor
struct RequestsTableLayoutTests {
    /// The factors the column widths are checked at: every step the UI scale offers.
    static let factors: [CGFloat] = [1, 1.1, 1.2, 1.3, 1.4, 1.5]

    private static func width(_ text: String, _ font: NSFont) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: font]).width
    }

    /// The Remote IP column is fixed to the widest IPv4 address in the cell's 11 px SF Mono, with the few
    /// points of inset the fixed Time column also leaves around its text, so a rebuilt table can't squeeze it.
    @Test func remoteIPColumnFitsEveryIPv4Address() {
        for factor in Self.factors {
            let font = NSFont.monospacedSystemFont(ofSize: 11 * factor, weight: .regular)
            let column = RequestsTable.remoteIPWidth(factor: factor)
            #expect(Self.width("255.255.255.255", font) + 6 <= column, "at \(factor)")
            #expect(column <= UIScale.length(124, factor: factor), "the column stays narrow; App · Process and Host get the rest")
        }
        #expect(RequestsTable.remoteIPWidth == RequestsTable.remoteIPWidth(factor: UIScale.factor))
    }

    /// History's time column fits the date and the time to the millisecond in both languages.
    @Test func historyTimesShowTheDay() {
        let date = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 24, hour: 23, minute: 59, second: 59))!.addingTimeInterval(0.999)
        let english = RequestsTimeCell.label(date, style: .dayClock, locale: Locale(identifier: "en"))
        let chinese = RequestsTimeCell.label(date, style: .dayClock, locale: Locale(identifier: "zh-Hans"))
        #expect(english == "Oct 24 23:59:59.999")
        #expect(chinese == "10月24日 23:59:59.999")
        #expect(RequestsTimeCell.label(date, style: .clock, locale: Locale(identifier: "en")) == "23:59:59.999")
        for factor in Self.factors {
            let font = NSFont.monospacedSystemFont(ofSize: 11 * factor, weight: .regular)
            for label in [english, chinese, "Sep 30 23:59:59.999"] {
                #expect(Self.width(label, font) + 6 <= RequestsTable.historyTimeWidth(factor: factor), "\(label) at \(factor)")
            }
        }
        #expect(RequestsTable.historyTimeWidth == RequestsTable.historyTimeWidth(factor: UIScale.factor))
    }

    /// A rebuilt table leaves Policy at its minimum, which still shows the group and enough of the final policy
    /// to tell nodes with the same protocol apart (`AI › …kNerd-Hysteria2`, not `AI › …Hysteria2`).
    @Test func policyColumnKeepsTheGroupAndTheEndOfThePolicy() {
        for factor in Self.factors {
            let font = NSFont.systemFont(ofSize: 11 * factor, weight: .medium)
            let group = Self.width("AI › ", font)
            let leafEnd = Self.width("…kNerd-Hysteria2", font)
            // 6 px chip padding on each side.
            let column = RequestsTable.policyMinWidth(factor: factor)
            #expect(group + leafEnd + 2 * UIScale.length(6, factor: factor) <= column, "at \(factor)")
            #expect(column >= UIScale.length(84, factor: factor), "at least the design's column")
        }
        #expect(RequestsTable.policyMinWidth == RequestsTable.policyMinWidth(factor: UIScale.factor))
    }

    /// At its minimum the App · Process column still shows the tile, an app name like `Brave Browser` and the
    /// start of the process.
    @Test func appColumnKeepsTheAppName() {
        for factor in Self.factors {
            let name = Self.width("Brave Browser", NSFont.systemFont(ofSize: 12 * factor, weight: .medium))
            let process = Self.width(" › …", NSFont.systemFont(ofSize: 12 * factor))
            // 16 px tile and 6 px spacing.
            let tile = UIScale.length(16, factor: factor) + UIScale.length(6, factor: factor)
            #expect(tile + name + process <= RequestsTable.appMinWidth(factor: factor), "at \(factor)")
        }
        #expect(RequestsTable.appMinWidth == RequestsTable.appMinWidth(factor: UIScale.factor))
    }

    /// "Open <App>" in the inspector shows the app's Domains & IPs, as in the design.
    @Test func openingAnAppShowsItsDomainsAndIPs() {
        #expect(RequestsPresentation.openAppTab == .inventory)
    }

    /// The table asks for no width of its own, however wide its columns: the content beside the inspector already
    /// holds the sidebar's and the inspector's widths, and with its 360 px minimum on top, opening the inspector in
    /// a window narrower than about 1,164 px at 1.0 aborted the app. It scrolls sideways instead.
    @Test func tableAsksForNoWidth() {
        let defaults = TestDefaults()
        let model = AppModel(preferences: Preferences(defaults: defaults.make()))
        let rows = (1...20).map { UIMainFixtures.record(id: Int64($0), host: "host\($0).example.com") }
        for style in [RequestsTable.TimeStyle.clock, .dayClock] {
            let table = RequestsTable(model: model, rows: rows, selection: .constant(nil), timeStyle: style, now: .now)
            #expect(NSHostingController(rootView: table).sizeThatFits(in: CGSize(width: 0, height: 600)).width == 0, "\(style)")
        }
    }
}

/// The toolbar search field of Requests and Domains & IPs hands every edit, and the clear button's empty
/// string, to its binding, and takes ⌘F.
@MainActor
struct ToolbarSearchFieldTests {
    @Test func editsReachTheBinding() {
        final class Box { var text = "" }
        let box = Box()
        let coordinator = ToolbarSearchField.Coordinator(text: Binding(get: { box.text }, set: { box.text = $0 }))
        let field = NSSearchField()
        field.stringValue = "cursor"
        coordinator.searchChanged(field)
        #expect(box.text == "cursor")
        field.stringValue = ""
        coordinator.searchChanged(field)
        #expect(box.text == "")
    }

    @Test func focusesOnCommandF() throws {
        func key(_ characters: String, _ flags: NSEvent.ModifierFlags) throws -> NSEvent {
            try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
                                          context: nil, characters: characters, charactersIgnoringModifiers: characters,
                                          isARepeat: false, keyCode: 3))
        }
        #expect(ToolbarSearchField.isFindShortcut(try key("f", .command)))
        #expect(ToolbarSearchField.isFindShortcut(try key("F", [.command, .capsLock])))
        #expect(!ToolbarSearchField.isFindShortcut(try key("F", [.command, .shift])))
        #expect(!ToolbarSearchField.isFindShortcut(try key("f", [.command, .option])))
        #expect(!ToolbarSearchField.isFindShortcut(try key("f", [])))
        #expect(!ToolbarSearchField.isFindShortcut(try key("g", .command)))
    }
}

/// A segmented control in a toolbar too narrow for it overflows into a submenu of its choices, the selected one
/// checked, and picking one there selects it (by default the menu would offer only the first segment's button).
@MainActor
struct DesignSegmentedControlTests {
    @Test func overflowMenuOffersEveryChoice() async throws {
        final class Box { var live = true }
        let box = Box()
        let control = DesignSegmentedControl("Mode", selection: Binding(get: { box.live }, set: { box.live = $0 }), size: .compact(),
                                             segments: [.init(true, "Live", systemImage: "dot.radiowaves.left.and.right"),
                                                        .init(false, "History", systemImage: "clock.arrow.circlepath", count: 12)])
        let host = NSHostingView(rootView: Color.clear.toolbar {
            ToolbarItem(placement: .primaryAction) { control }
        })
        host.sceneBridgingOptions = [.toolbars]
        // Never ordered in: a window this narrow puts the item in the overflow menu.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 120, height: 100),
                              styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = host

        var submenu: NSMenu?
        let deadline = ContinuousClock.now + .seconds(5)
        while submenu == nil, ContinuousClock.now < deadline {
            window.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(50))
            submenu = window.toolbar?.items.lazy.compactMap { $0.menuFormRepresentation?.submenu }.first
        }
        let menu = try #require(submenu)
        #expect(menu.items.map(\.title) == ["Live", "History"])
        #expect(menu.items.map(\.state) == [.on, .off])
        menu.performActionForItem(at: 1)
        let selected = ContinuousClock.now + .seconds(2)
        while box.live, ContinuousClock.now < selected {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(box.live == false)
    }

    private static func width(of control: DesignSegmentedControl<Int>, proposed: CGFloat = .infinity) -> CGFloat {
        NSHostingController(rootView: control).sizeThatFits(in: CGSize(width: proposed, height: .infinity)).width
    }

    private static func kinds(selected: Int, count: Int) -> DesignSegmentedControl<Int> {
        DesignSegmentedControl("Kind", selection: .constant(selected), size: .compact(), segments: [
            .init(0, "All", systemImage: "list.bullet", count: count),
            .init(1, "Domains", systemImage: "globe", count: 128),
            .init(2, "IPs", systemImage: "number", count: 57),
        ])
    }

    /// Selecting another choice, or a count changing without gaining a digit, keeps the control's width, so
    /// nothing after it moves.
    @Test func widthHoldsAcrossSelectionsAndCounts() {
        let width = Self.width(of: Self.kinds(selected: 0, count: 12))
        #expect(width > 0)
        #expect(Self.width(of: Self.kinds(selected: 1, count: 12)) == width)
        #expect(Self.width(of: Self.kinds(selected: 2, count: 12)) == width)
        #expect(Self.width(of: Self.kinds(selected: 0, count: 85)) == width)
    }

    /// The two sizes are 40 and 32 px tall. Both grow with the UI scale, the compact one in a toolbar only as far as a
    /// toolbar item's capsule holds it; the control draws at its size's height.
    @Test func sizesFollowTheScaleUpToTheToolbarsHeight() {
        typealias Size = DesignSegmentedControl<Int>.Size
        #expect(Size.regular(factor: 1).height == 40)
        #expect(Size.compact(factor: 1).height == 32)
        for factor: CGFloat in [1, 1.1, 1.2, 1.3, 1.4, 1.5] {
            #expect(Size.regular(factor: factor).height >= UIScale.length(40, factor: factor) - 1)
            #expect(Size.compact(factor: factor).height <= Size.toolbarItemHeight, "at \(factor)")
            #expect(Size.compact(factor: factor).height >= min(UIScale.length(32, factor: factor), Size.toolbarItemHeight) - 1)
        }
        #expect(Size.compact(factor: 1.1).factor == 1.1)
        #expect(Size.compact(factor: 1.4).factor < 1.4)
        // At 1.2 a toolbar already holds it a little smaller; outside a toolbar (a Settings row) it keeps the factor.
        #expect(Size.compact(factor: 1.2).factor < 1.2)
        #expect(Size.compact(factor: 1.2, inToolbar: false).factor == 1.2)
        #expect(Size.compact(factor: 1.2, inToolbar: false).height >= UIScale.length(32, factor: 1.2) - 1)
        let drawn = NSHostingController(rootView: Self.kinds(selected: 0, count: 12)).sizeThatFits(in: CGSize(width: CGFloat.infinity, height: .infinity))
        #expect(drawn.height == Size.compact().height)
    }

    /// A place narrower than the control gets it without its counts, then without its icons as well.
    @Test func countsAndThenIconsGiveWayWhenNarrow() {
        let control = Self.kinds(selected: 0, count: 185)
        let ideal = Self.width(of: control)
        let withoutCounts = Self.width(of: control, proposed: ideal - 1)
        #expect(withoutCounts < ideal - 1)
        let withoutIcons = Self.width(of: control, proposed: withoutCounts - 1)
        #expect(withoutIcons < withoutCounts - 1)
        // Without counts to give up, the control keeps its icons and its width.
        let plain = DesignSegmentedControl("Kind", selection: .constant(0), size: .compact(), segments: [
            .init(0, "All", systemImage: "list.bullet"),
            .init(1, "Domains", systemImage: "globe"),
        ])
        let plainWidth = Self.width(of: plain)
        #expect(Self.width(of: plain, proposed: plainWidth / 2) == plainWidth)
    }
}

/// The live table's backfill and a History page reach the table as hundreds of rows in one update. With
/// NSTableView's estimated row heights, which SwiftUI turns on, more than 200 rows arriving at a table without
/// cached row heights re-enter AppKit's row height cache, which AppKit logs (and will assert on).
@MainActor
struct RequestsTableRowHeightTests {
    typealias F = UIMainFixtures

    @Test func hundredsOfRowsArriveWithoutReenteringTheTable() async throws {
        #expect(UserDefaults.standard.object(forKey: TableRowHeightDefaults.canEstimateRowHeightsKey) as? Bool == false)

        let suite = "tidemark-tests-\(UUID().uuidString)"
        defer { TestDefaults.remove(suite) }
        let model = AppModel(preferences: Preferences(defaults: UserDefaults(suiteName: suite)!))
        func liveTable(_ rows: [RequestRecord]) -> RequestsTable {
            RequestsTable(model: model, rows: rows, selection: .constant(nil), timeStyle: .clock, now: .now)
        }
        let host = NSHostingView(rootView: liveTable([]))
        // Never ordered in: the table updates and lays out off screen.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 500), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        try await Self.waitUntil { host.layoutSubtreeIfNeeded(); return Self.table(in: host) != nil }
        let table = try #require(Self.table(in: host))

        let marker = "tidemark-row-heights-\(UUID().uuidString)"
        let output = await Self.capturingStandardError {
            NSLog("%@", marker)
            // Fresh rows, so the row tint runs too.
            host.rootView = liveTable((1...300).map { F.record(id: $0, startedAt: .now) })
            try? await Self.waitUntil { host.layoutSubtreeIfNeeded(); return table.numberOfRows == 300 }
        }
        #expect(output.contains(marker), "NSLog reaches standard error, so the check below can see AppKit's warning")
        #expect(table.numberOfRows == 300)
        #expect(!output.contains("reentrant operation"))
    }

    /// Rows and the header are the design's 28 px, at any UI scale: a cell asks for the row's height less what the
    /// inset style adds, and the table keeps its automatic row heights.
    @Test func rowsAndHeaderAreTheDesignsHeight() async throws {
        let suite = "tidemark-tests-\(UUID().uuidString)"
        defer { TestDefaults.remove(suite) }
        let model = AppModel(preferences: Preferences(defaults: UserDefaults(suiteName: suite)!))
        let rows = (1...20).map { F.record(id: $0, policy: ["Proxy", "HK-01"]) }
        for timeStyle in [RequestsTable.TimeStyle.clock, .dayClock] {
            let host = NSHostingView(rootView: RequestsTable(model: model, rows: rows, selection: .constant(nil), timeStyle: timeStyle,
                                                             now: timeStyle == .clock ? .now : nil))
            // Never ordered in: the table lays out off screen.
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 500), styleMask: [.titled],
                                  backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            defer { window.close() }
            try await Self.waitUntil { host.layoutSubtreeIfNeeded(); return (Self.table(in: host)?.numberOfRows ?? 0) == rows.count }
            let table = try #require(Self.table(in: host))
            #expect(table.rect(ofRow: 0).height == RequestsTable.rowHeight)
            #expect(table.rect(ofRow: rows.count - 1).height == RequestsTable.rowHeight)
            #expect(RequestsTable.rowHeight == 28.px)
            // The header gets its height after the update that added the first row.
            try await Self.waitUntil { table.headerView?.frame.height == RequestsTable.headerHeight }
            #expect(table.headerView?.frame.height == RequestsTable.headerHeight)
        }
    }

    /// The first row's cell gives its table's header the design's height wherever AppKit's differs, and only that
    /// cell holds the view that does it.
    @Test func firstRowGivesTheHeaderTheDesignsHeight() async throws {
        let rows = (1...20).map { F.record(id: $0) }
        let host = NSHostingView(rootView: HeaderAnchorTable(rows: []))
        // Never ordered in: the table lays out off screen.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 500), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        try await Self.waitUntil { host.layoutSubtreeIfNeeded(); return Self.table(in: host) != nil }
        let table = try #require(Self.table(in: host))
        let header = try #require(table.headerView)
        // A header AppKit drew at another height than the design's.
        header.frame.size.height = RequestsTable.headerHeight - 6

        host.rootView = HeaderAnchorTable(rows: rows)
        try await Self.waitUntil { host.layoutSubtreeIfNeeded(); return header.frame.height == RequestsTable.headerHeight }
        #expect(table.numberOfRows == rows.count)
        #expect(header.frame.height == RequestsTable.headerHeight)
        #expect(Self.count(RequestsTableHeaderAnchor.self, in: table) == 1)
        #expect(RequestsTableHeaderHeight.isNeeded == (RequestsTable.headerHeight != NSTableHeaderView().frame.height))
    }

    /// A table whose first row holds the header's anchor, as the request table's does where its header needs it.
    private struct HeaderAnchorTable: View {
        var rows: [RequestRecord]

        var body: some View {
            Table(rows) {
                TableColumn("Host") { (record: RequestRecord) in
                    Text(record.host)
                        .background {
                            if record.key == rows.first?.key { RequestsTableHeaderHeight() }
                        }
                }
            }
        }
    }

    private static func count<T: NSView>(_ type: T.Type, in view: NSView) -> Int {
        (view is T ? 1 : 0) + view.subviews.reduce(0) { $0 + count(type, in: $1) }
    }

    /// The header gets the design's height from a cell of its table, which AppKit would leave at its own.
    @Test func headerTakesTheDesignsHeight() throws {
        let table = NSTableView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        table.addTableColumn(NSTableColumn(identifier: .init("time")))
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        scroll.documentView = table
        let header = try #require(table.headerView)
        header.frame.size.height = RequestsTable.headerHeight - 6
        #expect(RequestsTableHeaderAnchor.needsHeight(table))
        RequestsTableHeaderAnchor.setHeight(of: table)
        #expect(header.frame.height == RequestsTable.headerHeight)
        #expect(!RequestsTableHeaderAnchor.needsHeight(table))
    }

    private static func table(in view: NSView) -> NSTableView? {
        if let table = view as? NSTableView { return table }
        return view.subviews.lazy.compactMap { table(in: $0) }.first
    }

    private static func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<250 where !condition() {
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    /// What the process writes to standard error (NSLog included) while `body` runs; it is passed on afterwards.
    private static func capturingStandardError(_ body: @MainActor () async -> Void) async -> String {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tidemark-stderr-\(UUID().uuidString).log")
        guard FileManager.default.createFile(atPath: url.path, contents: nil),
              let file = try? FileHandle(forWritingTo: url) else { return "" }
        defer { try? FileManager.default.removeItem(at: url) }
        fflush(nil)
        let saved = dup(STDERR_FILENO)
        dup2(file.fileDescriptor, STDERR_FILENO)
        await body()
        fflush(nil)
        dup2(saved, STDERR_FILENO)
        close(saved)
        try? file.close()
        let output = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        FileHandle.standardError.write(Data(output.utf8))
        return output
    }
}

/// The live table follows the stream at most twice a second, but opens with the stream's rows in its first pass
/// (never empty first) and applies the filter to the rows it shows.
@MainActor
struct RequestsLiveViewTests {
    typealias F = UIMainFixtures

    @Test func opensWithTheStreamAndFollowsIt() async throws {
        let defaults = TestDefaults()
        let model = AppModel(preferences: Preferences(defaults: defaults.make()))
        let start = Date.now.addingTimeInterval(-60)
        model.live.rows = (1...40).reversed().map { F.record(id: Int64($0), host: "host\($0).example.com", startedAt: start.addingTimeInterval(Double($0))) }
        let host = NSHostingView(rootView: RequestsLiveView().environment(model).environment(Localizer.shared))
        // Never ordered in: the table updates and lays out off screen.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 500), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }

        try await Self.waitUntil { host.layoutSubtreeIfNeeded(); return Self.table(in: host) != nil }
        let table = try #require(Self.table(in: host))
        #expect(table.numberOfRows == 40, "the first pass shows the stream")

        model.live.upsert([F.record(id: 41, host: "host41.example.com", startedAt: .now)])
        try await Self.waitUntil { host.layoutSubtreeIfNeeded(); return table.numberOfRows == 41 }
        #expect(table.numberOfRows == 41)

        // host1, host10…host19
        model.nav.requestSearch = "host1"
        try await Self.waitUntil { host.layoutSubtreeIfNeeded(); return table.numberOfRows == 11 }
        #expect(table.numberOfRows == 11)
    }

    private static func table(in view: NSView) -> NSTableView? {
        if let table = view as? NSTableView { return table }
        return view.subviews.lazy.compactMap { table(in: $0) }.first
    }

    private static func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<250 where !condition() {
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}

@MainActor
struct RequestsHistoryModelTests {
    typealias F = UIMainFixtures

    @Test func pagesThroughResults() async {
        let base = Date.now.addingTimeInterval(-60)
        let rows = (0..<1_200).map { F.record(id: Int64($0), startedAt: base.addingTimeInterval(Double($0) * 0.01)) }
        let database = ShellDemoDatabase(rows: rows)
        let history = RequestsHistoryModel()
        var query = RequestQuery()
        query.range = .lastHour

        await history.load(query, database: database)
        #expect(history.rows.count == RequestsHistoryModel.pageSize)
        #expect(history.totalCount == 1_200)
        #expect(history.histogram?.counts.count == RequestsHistoryModel.histogramBuckets)
        #expect(history.canLoadMore)

        await history.loadMore(database: database)
        await history.loadMore(database: database)
        #expect(history.rows.count == 1_200)
        #expect(!history.canLoadMore)
        #expect(Set(history.rows.map(\.key)).count == 1_200)
    }

    @Test func reportsErrors() async {
        Localizer.shared.override = "en"
        let history = RequestsHistoryModel()
        await history.load(RequestQuery(), database: RequestsStubDatabase())
        #expect(history.errorMessage == "PostgreSQL is unreachable: connection refused")
        #expect(history.rows.isEmpty)
        #expect(!history.canLoadMore)
        #expect(!history.isLoading)
        #expect(!history.isLoadingHistogram)

        // The failure reads in a language chosen after it.
        Localizer.shared.override = "zh-Hans"
        defer { Localizer.shared.override = "en" }
        guard Localizer.shared.bundle != nil else { return }
        #expect(history.errorMessage == "连不上 PostgreSQL：connection refused")
    }

    private func eventually(_ timeout: Duration = .seconds(3), _ condition: () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await condition()
    }

    /// A page with one row whose ID tells the queries apart (`old` → 1, anything else → 2).
    private nonisolated static func page(_ query: RequestQuery) -> RequestPage {
        RequestPage(rows: [F.record(id: query.search == "old" ? 1 : 2)], totalCount: 1, elapsed: .milliseconds(4))
    }

    private nonisolated static let oldChart = Histogram(start: Date(timeIntervalSince1970: 0), end: Date(timeIntervalSince1970: 3600), counts: [1, 0])
    private nonisolated static let newChart = Histogram(start: Date(timeIntervalSince1970: 0), end: Date(timeIntervalSince1970: 3600), counts: [0, 1])

    @Test func showsRowsBeforeTheHistogram() async {
        let gate = RequestsGate()
        let database = RequestsStubDatabase(
            query: { query in Self.page(query) },
            buckets: { _, _ in
                await gate.wait()
                return Self.newChart
            }
        )
        let history = RequestsHistoryModel()
        let load = Task { await history.load(RequestQuery(), database: database) }
        #expect(await eventually { history.rows.count == 1 })
        #expect(history.totalCount == 1)
        #expect(!history.isLoading)
        #expect(history.isLoadingHistogram)
        #expect(history.histogram == nil)

        await gate.open()
        await load.value
        #expect(history.histogram == Self.newChart)
        #expect(!history.isLoadingHistogram)
        #expect(history.histogramError == nil)
    }

    @Test func keepsRowsWhenTheHistogramFails() async {
        let rows = (0..<600).map { F.record(id: Int64($0)) }
        let failing = RequestsStubDatabase(
            query: { query in try await ShellDemoDatabase(rows: rows).queryRequests(query) },
            buckets: { _, _ in throw DatabaseError.unreachable("Query timed out") }
        )
        let history = RequestsHistoryModel()
        var query = RequestQuery()
        query.range = .all

        await history.load(query, database: failing)
        #expect(history.rows.count == RequestsHistoryModel.pageSize)
        #expect(history.totalCount == 600)
        #expect(history.errorMessage == nil)
        #expect(history.histogram == nil)
        #expect(history.histogramError == CaptureEngine.message(for: DatabaseError.unreachable("Query timed out")))
        #expect(history.canLoadMore)
        await history.loadMore(database: failing)
        #expect(history.rows.count == 600)

        // The next load that gets a histogram clears the note.
        await history.load(query, database: ShellDemoDatabase(rows: rows))
        #expect(history.histogramError == nil)
        #expect(history.histogram?.counts.reduce(0, +) == 600)
    }

    @Test func keepsRowsWhenANextPageFails() async {
        let rows = (0..<600).map { F.record(id: Int64($0)) }
        let flaky = RequestsStubDatabase(query: { query in
            guard query.offset == 0 else { throw DatabaseError.unreachable("connection refused") }
            return try await ShellDemoDatabase(rows: rows).queryRequests(query)
        })
        let history = RequestsHistoryModel()
        var query = RequestQuery()
        query.range = .all

        await history.load(query, database: flaky)
        await history.loadMore(database: flaky)
        #expect(history.rows.count == RequestsHistoryModel.pageSize)
        #expect(history.errorMessage == nil, "no \"Can't load history\" over the rows already loaded")
        #expect(history.nextPageFailures == 1)
        #expect(history.canLoadMore)

        await history.loadMore(database: ShellDemoDatabase(rows: rows))
        #expect(history.rows.count == 600)
        #expect(history.nextPageFailures == 0)
    }

    @Test func aFailedPageTakesTheChartWithIt() async {
        // The histogram arrives first, then the page fails.
        let pageGate = RequestsGate()
        let pageLast = RequestsStubDatabase(
            query: { _ in
                await pageGate.wait()
                throw DatabaseError.unreachable("connection refused")
            },
            buckets: { _, _ in Self.newChart }
        )
        let history = RequestsHistoryModel()
        let load = Task { await history.load(RequestQuery(), database: pageLast) }
        #expect(await eventually { history.histogram == Self.newChart })
        await pageGate.open()
        await load.value
        #expect(history.errorMessage != nil)
        #expect(history.histogram == nil)
        #expect(!history.isLoadingHistogram)

        // The page fails first: the histogram is cancelled, and one that finishes anyway is dropped.
        let chartGate = RequestsGate()
        let chartLast = RequestsStubDatabase(
            buckets: { _, _ in
                await chartGate.wait()
                if Task.isCancelled { await chartGate.noteCancellation() }
                return Self.newChart
            }
        )
        let fresh = RequestsHistoryModel()
        let second = Task { await fresh.load(RequestQuery(), database: chartLast) }
        #expect(await eventually { fresh.errorMessage != nil })
        #expect(!fresh.isLoading)
        #expect(!fresh.isLoadingHistogram)
        await chartGate.open()
        await second.value
        #expect(await chartGate.cancellations == 1)
        #expect(fresh.histogram == nil)
        #expect(fresh.histogramError == nil)
        #expect(fresh.rows.isEmpty)
    }

    @Test func aNewerLoadCancelsTheOlderHistogram() async {
        let gate = RequestsGate()
        let database = RequestsStubDatabase(
            query: { query in Self.page(query) },
            buckets: { query, _ in
                guard query.search == "old" else { return Self.newChart }
                do {
                    try await Task.sleep(for: .seconds(30))
                } catch {
                    await gate.noteCancellation()
                    throw error
                }
                return Self.oldChart
            }
        )
        let history = RequestsHistoryModel()
        var old = RequestQuery()
        old.search = "old"
        let first = Task { await history.load(old, database: database) }
        #expect(await eventually { history.rows.first?.rowID == 1 })
        #expect(history.isLoadingHistogram)

        await history.load(RequestQuery(), database: database)
        await first.value
        #expect(await gate.cancellations == 1)
        #expect(history.rows.map(\.rowID) == [2])
        #expect(history.histogram == Self.newChart)
        #expect(history.histogramError == nil)
        #expect(!history.isLoadingHistogram)
    }

    @Test func dropsAnOlderHistogramThatFinishesLate() async {
        let gate = RequestsGate()
        // The old histogram ignores cancellation, like a server still working on the statement.
        let database = RequestsStubDatabase(
            query: { query in Self.page(query) },
            buckets: { query, _ in
                guard query.search == "old" else { return Self.newChart }
                await gate.wait()
                return Self.oldChart
            }
        )
        let history = RequestsHistoryModel()
        var old = RequestQuery()
        old.search = "old"
        let first = Task { await history.load(old, database: database) }
        #expect(await eventually { history.rows.first?.rowID == 1 })

        await history.load(RequestQuery(), database: database)
        #expect(history.histogram == Self.newChart)
        await gate.open()
        await first.value
        #expect(history.histogram == Self.newChart)
        #expect(history.rows.map(\.rowID) == [2])
        #expect(!history.isLoading)
        #expect(!history.isLoadingHistogram)
    }

    @Test func stopsLoadingWhenItsCallerIsCancelled() async {
        let gate = RequestsGate()
        let database = RequestsStubDatabase(
            query: { query in Self.page(query) },
            buckets: { _, _ in
                do {
                    try await Task.sleep(for: .seconds(30))
                } catch {
                    await gate.noteCancellation()
                    throw error
                }
                return Self.newChart
            }
        )
        let history = RequestsHistoryModel()
        let load = Task { await history.load(RequestQuery(), database: database) }
        #expect(await eventually { !history.rows.isEmpty })
        load.cancel()
        await load.value
        #expect(await gate.cancellations == 1)
        #expect(!history.isLoadingHistogram)
        #expect(history.histogramError == nil)
    }

    /// History shown again with the same filters keeps the results it has instead of querying PostgreSQL again;
    /// other filters, a failed histogram, another database and `load` itself query.
    @Test func showsKeptResultsWithoutQueryingAgain() async {
        let rows = (0..<50).map { F.record(id: Int64($0)) }
        let queries = RequestsQueryCounter()
        let database = RequestsStubDatabase(
            query: { query in
                await queries.add()
                return try await ShellDemoDatabase(rows: rows).queryRequests(query)
            },
            buckets: { query, buckets in try await ShellDemoDatabase(rows: rows).histogram(query, buckets: buckets) }
        )
        let history = RequestsHistoryModel()
        var query = RequestQuery()
        query.range = .all

        await history.show(query, database: database)
        #expect(history.keeps(query))
        await history.show(query, database: database)
        #expect(await queries.count == 1)
        #expect(history.rows.count == 50)
        #expect(history.histogram != nil)

        query.status = .failed
        #expect(!history.keeps(query))
        await history.show(query, database: database)
        #expect(await queries.count == 2)
        await history.load(query, database: database)
        #expect(await queries.count == 3)

        // Results read from a database that has since been replaced are not kept.
        history.databaseChanged()
        #expect(!history.keeps(query))
        await history.show(query, database: database)
        #expect(await queries.count == 4)
        #expect(history.keeps(query))

        // Results whose histogram failed are not kept.
        let chartless = RequestsStubDatabase(
            query: { query in
                await queries.add()
                return try await ShellDemoDatabase(rows: rows).queryRequests(query)
            },
            buckets: { _, _ in throw DatabaseError.unreachable("Query timed out") }
        )
        await history.load(query, database: chartless)
        #expect(history.histogramError != nil)
        #expect(!history.keeps(query))
        await history.show(query, database: chartless)
        #expect(await queries.count == 6)
    }

    /// Replacing `AppModel.database` (a new URL in Settings) ends the reuse of History results.
    @Test func anotherDatabaseEndsTheReuse() async {
        let defaults = TestDefaults()
        defer { defaults.removeAll() }
        let model = AppModel(preferences: Preferences(defaults: defaults.make()))
        let rows = (0..<5).map { F.record(id: Int64($0)) }
        model.database = ShellDemoDatabase(rows: rows)
        var query = RequestQuery()
        query.range = .all
        await model.requestsHistory.show(query, database: model.database)
        #expect(model.requestsHistory.keeps(query))

        model.database = ShellDemoDatabase(rows: [])
        #expect(!model.requestsHistory.keeps(query))
    }

    /// Kept results older than `refreshInterval` stay up while they are queried again: nothing shows a loading
    /// state, an unchanged answer changes nothing, and a changed one replaces the rows and the total.
    @Test func refreshesKeptResultsInTheBackground() async {
        let store = RequestsStore((0..<20).map { F.record(id: Int64($0)) })
        let gate = RequestsGate()
        let gated = RequestsGateSwitch()
        let queries = RequestsQueryCounter()
        let database = RequestsStubDatabase(
            query: { query in
                await queries.add()
                if gated.isOn { await gate.wait() }
                return try await ShellDemoDatabase(rows: store.rows).queryRequests(query)
            },
            buckets: { _, _ in Self.newChart }
        )
        let history = RequestsHistoryModel(refreshInterval: .zero)
        var query = RequestQuery()
        query.range = .all
        await history.show(query, database: database)
        #expect(history.rows.count == 20)

        let unchanged = await Self.changes(of: history) {
            await history.show(query, database: database)
        }
        #expect(await queries.count == 2)
        #expect(!unchanged, "an unchanged answer redraws nothing")

        store.rows += (20..<25).map { F.record(id: Int64($0)) }
        gated.isOn = true
        let loadingState = await Self.changes(of: history, reading: { _ = $0.isLoading; _ = $0.isLoadingHistogram }) {
            let refresh = Task { await history.show(query, database: database) }
            #expect(await eventually { await queries.count == 3 })
            #expect(history.rows.count == 20, "the kept rows stay up while they are queried again")
            await gate.open()
            await refresh.value
        }
        #expect(!loadingState)
        #expect(history.rows.count == 25)
        #expect(history.totalCount == 25)
        #expect(history.keeps(query))
    }

    /// A History that opens the page clears results it does not keep before querying, as a new model would; the
    /// Live / History switch leaves them up until the new page arrives.
    @Test func clearsResultsItDoesNotKeepWhenAsked() async {
        let gate = RequestsGate()
        let gated = RequestsGateSwitch()
        let database = RequestsStubDatabase(
            query: { query in
                if gated.isOn { await gate.wait() }
                return Self.page(query)
            },
            buckets: { _, _ in Self.newChart }
        )
        let history = RequestsHistoryModel()
        var old = RequestQuery()
        old.search = "old"
        await history.show(old, database: database)
        #expect(history.rows.map(\.rowID) == [1])
        #expect(history.histogram == Self.newChart)

        gated.isOn = true
        let switched = Task { await history.show(RequestQuery(), database: database) }
        #expect(await eventually { history.isLoading })
        #expect(history.rows.map(\.rowID) == [1], "the switch leaves the old rows up")
        await gate.open()
        await switched.value
        #expect(history.rows.map(\.rowID) == [2])

        let reopened = RequestsGate()
        let database2 = RequestsStubDatabase(
            query: { query in
                await reopened.wait()
                return Self.page(query)
            },
            buckets: { _, _ in
                await reopened.wait()
                return Self.newChart
            }
        )
        let opened = Task { await history.show(old, database: database2, clearsOthers: true) }
        #expect(await eventually { history.isLoading })
        #expect(history.rows.isEmpty)
        #expect(history.totalCount == 0)
        #expect(history.histogram == nil)
        #expect(history.isLoadingHistogram)
        await reopened.open()
        await opened.value
        #expect(history.rows.map(\.rowID) == [1])
    }

    /// The policy list is queried again for another range or database, or once it is older than `refreshInterval`.
    @Test func keepsPoliciesPerRangeAndDatabase() async {
        let asked = RequestsQueryCounter()
        let database = RequestsStubDatabase(policies: { _ in
            await asked.add()
            return ["Proxy", "DIRECT"]
        })
        let history = RequestsHistoryModel()
        await history.loadPolicies(for: .last24Hours, database: database)
        await history.loadPolicies(for: .last24Hours, database: database)
        #expect(await asked.count == 1)
        #expect(history.policies == ["DIRECT", "Proxy"])
        await history.loadPolicies(for: .all, database: database)
        #expect(await asked.count == 2)
        history.databaseChanged()
        await history.loadPolicies(for: .all, database: database)
        #expect(await asked.count == 3)

        let eager = RequestsHistoryModel(refreshInterval: .zero)
        await eager.loadPolicies(for: .all, database: database)
        await eager.loadPolicies(for: .all, database: database)
        #expect(await asked.count == 5)
    }

    /// Whether `history` sets any of the properties `reading` reads (by default everything the History view
    /// draws) while `work` runs.
    private static func changes(
        of history: RequestsHistoryModel,
        reading: @escaping @MainActor (RequestsHistoryModel) -> Void = {
            _ = ($0.rows, $0.totalCount, $0.elapsed, $0.histogram, $0.histogramError, $0.errorMessage, $0.isLoading, $0.isLoadingHistogram)
        },
        during work: () async -> Void
    ) async -> Bool {
        let changed = RequestsChangeFlag()
        withObservationTracking { reading(history) } onChange: { changed.value.withLock { $0 = true } }
        await work()
        return changed.value.withLock { $0 }
    }

    @Test func labelsQueryTime() {
        #expect(RequestsHistoryLabels.milliseconds(.milliseconds(38)) == "38 ms")
        #expect(RequestsHistoryLabels.milliseconds(.seconds(1.5)) == "1500 ms")
    }
}

/// Set once an observed property changes.
private final class RequestsChangeFlag: Sendable {
    let value = Mutex(false)
}

/// Rows a stub database answers from, changed by the test.
private final class RequestsStore: Sendable {
    private let value: Mutex<[RequestRecord]>

    init(_ rows: [RequestRecord]) { value = Mutex(rows) }

    var rows: [RequestRecord] {
        get { value.withLock { $0 } }
        set { value.withLock { $0 = newValue } }
    }
}

/// Makes a stub database wait for its gate from the next query on.
private final class RequestsGateSwitch: Sendable {
    private let value = Mutex(false)

    var isOn: Bool {
        get { value.withLock { $0 } }
        set { value.withLock { $0 = newValue } }
    }
}

/// Counts the stub database's page queries.
private actor RequestsQueryCounter {
    private(set) var count = 0

    func add() { count += 1 }
}

/// Holds the stub database's queries until the test opens it, and counts queries that were cancelled.
private actor RequestsGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var cancellations = 0

    /// Returns once the gate is open, whether or not the caller was cancelled meanwhile.
    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        for waiter in waiters { waiter.resume() }
        waiters = []
    }

    func noteCancellation() { cancellations += 1 }
}

/// A database whose request queries are answered by closures; by default they fail.
private struct RequestsStubDatabase: TidemarkDatabase {
    var query: @Sendable (RequestQuery) async throws -> RequestPage = { _ in throw DatabaseError.unreachable("connection refused") }
    var buckets: @Sendable (RequestQuery, Int) async throws -> Histogram = { _, _ in throw DatabaseError.unreachable("connection refused") }
    var policies: @Sendable (Date?) async throws -> [String] = { _ in [] }

    func queryRequests(_ query: RequestQuery) async throws -> RequestPage { try await self.query(query) }
    func histogram(_ query: RequestQuery, buckets: Int) async throws -> Histogram { try await self.buckets(query, buckets) }

    func connect() async throws {}
    func migrate() async throws -> Int { 0 }
    func ping() async throws -> (roundTrip: Duration, serverVersion: String) { (.zero, "") }
    func schemaVersion() async throws -> Int { 0 }
    func tableNames() async throws -> [String] { [] }
    func upsertDevice(_ device: Device) async throws {}
    func devices() async throws -> [Device] { [] }
    func renameDevice(_ id: DeviceID, name: String) async throws {}
    func mergeDevice(_ from: DeviceID, into: DeviceID, idleFor: Duration?) async throws -> DeviceMergeResult { DeviceMergeResult() }
    func devicesSharingHistory(with device: DeviceID, sessions: [Int64]) async throws -> [DeviceID] { [] }
    func apps() async throws -> [MonitoredApp] { [] }
    func insertApp(_ app: MonitoredApp) async throws {}
    func updateApp(_ app: MonitoredApp) async throws {}
    func deleteApp(_ id: AppID) async throws {}
    func setInstalled(appID: AppID, deviceID: DeviceID, installed: Bool) async throws {}
    func installs() async throws -> [AppID: [DeviceID: Bool]] { [:] }
    func appStats(_ id: AppID, scope: DeviceScope) async throws -> AppStats { AppStats() }
    func countRequests(inBundle bundlePath: String) async throws -> Int64 { 0 }
    func backfill(appID: AppID, bundlePath: String) async throws -> Int64 { 0 }
    func upsertRequests(_ rows: [RequestRecord]) async throws -> [RequestKey: Int64] { [:] }
    func requestsWritten(after cursor: RequestWriteCursor, excluding: DeviceID?, limit: Int) async throws -> [RequestRecord] { [] }
    func requestWritePosition() async throws -> RequestWriteCursor { .start }
    func distinctPolicies(since: Date?) async throws -> [String] { try await policies(since) }
    func countRequests(since: Date, scope: DeviceScope) async throws -> Int64 { 0 }
    func estimatedRequestCount() async throws -> Int64 { 0 }
    func upsertProcessChain(deviceID: DeviceID, chain: [ProcessLink], appID: AppID?) async throws -> Int64? { nil }
    func processTree(appID: AppID, scope: DeviceScope) async throws -> [ProcessNode] { [] }
    func knownHosts() async throws -> [AppID: Set<String>] { [:] }
    func insertAppHosts(_ hosts: [AppHost]) async throws -> [AppHost] { [] }
    func touchAppHosts(_ hosts: [AppHost]) async throws {}
    func appHosts(_ appID: AppID, scope: DeviceScope) async throws -> [AppHost] { [] }
    func touchHostSources(_ sources: [HostSourceTouch]) async throws {}
    func inventory(kind: HostKind?, search: String, scope: DeviceScope) async throws -> [InventoryEntry] { [] }
    func ipInfo(_ ip: String) async throws -> GeoInfo? { nil }
    func saveIPInfo(_ ip: String, geo: GeoInfo) async throws {}
    func insertAlerts(_ alerts: [AlertItem]) async throws -> [AlertItem] { [] }
    func alerts(filter: AlertFilter, appID: AppID?, scope: DeviceScope, limit: Int) async throws -> [AlertItem] { [] }
    func alerts(after id: Int64, excluding: DeviceID?) async throws -> [AlertItem] { [] }
    func unreadAlertCount(scope: DeviceScope) async throws -> Int { 0 }
    func markAlertsRead(_ ids: [Int64]) async throws {}
    func markAllAlertsRead(appID: AppID?, scope: DeviceScope) async throws {}
    func saveProbeSession(_ session: ProbeSession) async throws {}
    func probeSessions(limit: Int) async throws -> [ProbeSession] { [] }
    func saveEgressSamples(_ samples: [EgressSample], deviceID: DeviceID) async throws {}
    func latestEgress(deviceID: DeviceID) async throws -> [EgressSample] { [] }
    func insertEgressChange(_ change: EgressChange, deviceID: DeviceID) async throws {}
    func egressChanges(deviceID: DeviceID, limit: Int) async throws -> [EgressChange] { [] }
}

struct RequestsHistogramTests {
    @Test func splitsTheRangeIntoBins() {
        let start = Date(timeIntervalSince1970: 0)
        let histogram = Histogram(start: start, end: start.addingTimeInterval(4800), counts: [1, 2, 3, 4])
        let bins = RequestsHistogramBin.bins(of: histogram)
        #expect(bins.count == 4)
        #expect(bins[1].start == start.addingTimeInterval(1200))
        #expect(bins[1].end == start.addingTimeInterval(2400))
        #expect(bins.last?.isLast == true)
        // Bars stop short of the next bucket.
        #expect(bins[2].barEnd > bins[2].start && bins[2].barEnd < bins[2].end)
    }

    private let english = Locale(identifier: "en")

    private func date(_ day: Int, _ hour: Int, _ minute: Int, _ second: Int = 0) -> Date {
        Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute, second: second))!
    }

    private func labels(from start: Date, to end: Date, now: Date) -> [String] {
        let histogram = Histogram(start: start, end: end, counts: Array(repeating: 1, count: 48))
        return RequestsHistogramBin.axisTicks(of: histogram, now: now, locale: english, nowLabel: "Now").map(\.label)
    }

    @Test func labelsTheLastDayOnWholeHours() {
        // The design: `Oct 23 14:00 · 20:00 · Oct 24 02:00 · 08:00 · Now`.
        let now = date(24, 13, 48, 12)
        #expect(labels(from: now.addingTimeInterval(-86400), to: now, now: now) == ["Oct 23 14:00", "20:00", "Oct 24 02:00", "08:00", "Now"])
        let ticks = RequestsHistogramBin.axisTicks(of: Histogram(start: now.addingTimeInterval(-86400), end: now, counts: [1]), now: now, locale: english, nowLabel: "Now")
        #expect(ticks.first?.date == date(23, 14, 0))
        #expect(ticks.last?.date == now)
    }

    @Test func labelsShorterAndLongerRanges() {
        let now = date(24, 14, 48)
        #expect(labels(from: now.addingTimeInterval(-3600), to: now, now: now) == ["14:00", "14:15", "14:30", "Now"])
        #expect(labels(from: now.addingTimeInterval(-7 * 86400), to: now, now: now) == ["Oct 18", "Oct 20", "Oct 22", "Now"])
        #expect(labels(from: now.addingTimeInterval(-30 * 86400), to: now, now: now) == ["Sep 25", "Oct 2", "Oct 9", "Oct 16", "Now"])
    }

    @Test func aNarrowChartGetsFewerLabels() {
        let now = date(24, 13, 48, 12)
        let histogram = Histogram(start: now.addingTimeInterval(-86400), end: now, counts: [1])
        let ticks = RequestsHistogramBin.axisTicks(of: histogram, now: now, locale: english, nowLabel: "Now", parts: 2)
        #expect(ticks.map(\.label) == ["Oct 23 14:00", "Oct 24 02:00", "Now"])
        #expect(RequestsHistogramBin.axisParts(forWidth: 1100) == 5)
        #expect(RequestsHistogramBin.axisParts(forWidth: 560) == 4)
        #expect(RequestsHistogramBin.axisParts(forWidth: 300) == 2)
        #expect(RequestsHistogramBin.axisParts(forWidth: 0) == 2)
    }

    @Test func labelsARangeThatEndsBeforeNow() {
        // A chart that no longer reaches now (the page stayed open) is labelled with its end time.
        #expect(labels(from: date(24, 9, 5), to: date(24, 11, 50), now: date(24, 14, 0)) == ["10:00", "11:00", "11:50"])
        // The date appears where the day changes.
        #expect(labels(from: date(23, 22, 10), to: date(24, 1, 40), now: date(24, 14, 0)) == ["23:00", "Oct 24 00:00", "01:00", "01:40"])
        // Seconds appear once the ticks are less than a minute apart.
        #expect(labels(from: date(24, 10, 0, 5), to: date(24, 10, 1, 35), now: date(24, 14, 0)) == ["10:00:30", "10:01:00", "10:01:35"])
    }
}

struct NotificationsPresentationTests {
    private func alert(_ id: Int64, kind: HostKind, scope: AlertScope, value: String, read: Bool = false, at date: Date = .now,
                       site: String? = nil, host: String? = nil, ip: String? = nil, direct: Bool = false) -> AlertItem {
        AlertItem(id: id, deviceID: UIMainFixtures.thisMac, appID: UIMainFixtures.cursor.id, kind: kind, scope: scope, value: value,
                  site: site, host: host, ip: ip, geo: GeoInfo(countryCode: "US", asn: 13335, organization: "Cloudflare, Inc."),
                  processName: "node", isDirect: direct, requestRowID: nil, createdAt: date, readAt: read ? date : nil)
    }

    @Test func filtersAndSortsNewestFirst() {
        let now = Date.now
        let items = [
            alert(1, kind: .domain, scope: .host, value: "a.com", read: true, at: now.addingTimeInterval(-30)),
            alert(2, kind: .ip, scope: .ip, value: "1.1.1.1", at: now.addingTimeInterval(-10)),
            alert(3, kind: .domain, scope: .site, value: "api.linear.app", at: now.addingTimeInterval(-20)),
        ]
        #expect(NotificationsPresentation.filter(items, by: .all).map(\.id) == [2, 3, 1])
        #expect(NotificationsPresentation.filter(items, by: .unread).map(\.id) == [2, 3])
    }

    @Test func groupsTodayAndEarlier() {
        let now = Date.now
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: now)!
        let groups = NotificationsPresentation.group([alert(1, kind: .domain, scope: .host, value: "a.com", at: now), alert(2, kind: .domain, scope: .host, value: "b.com", at: yesterday)], now: now)
        #expect(groups.today.map(\.id) == [1])
        #expect(groups.earlier.map(\.id) == [2])
    }

    @Test func wordsHeadlines() {
        let classifier = NaiveSiteClassifier()
        let site = alert(1, kind: .domain, scope: .site, value: "api.linear.app")
        #expect(NotificationsPresentation.headline(for: site, appName: "Raycast", site: classifier.site(for:)) == .newSite(app: "Raycast", site: "linear.app"))
        let host = alert(2, kind: .domain, scope: .host, value: "raw.githubusercontent.com")
        #expect(NotificationsPresentation.headline(for: host, appName: "Cursor", site: classifier.site(for:)) == .newHost(app: "Cursor", host: "raw.githubusercontent.com"))
        let ip = alert(3, kind: .ip, scope: .ip, value: "104.16.98.215", host: "production.cloudflare.docker.com")
        #expect(NotificationsPresentation.headline(for: ip, appName: "Docker", site: classifier.site(for:)) == .newIP(app: "Docker", ip: "104.16.98.215"))
        let direct = alert(4, kind: .ip, scope: .ip, value: "157.148.69.80", direct: true)
        #expect(NotificationsPresentation.headline(for: direct, appName: "WeChat", site: classifier.site(for:)) == .directIP(app: "WeChat", ip: "157.148.69.80"))
    }

    @Test func listsDetails() {
        let geo = NotificationsPresentation.Detail.text("US · AS13335 Cloudflare")
        #expect(NotificationsPresentation.details(for: alert(1, kind: .domain, scope: .site, value: "api.linear.app")) == [.firstHost("api.linear.app"), .via("node"), geo])
        #expect(NotificationsPresentation.details(for: alert(2, kind: .domain, scope: .host, value: "x.com", ip: "185.199.108.133")) == [.via("node"), .text("185.199.108.133"), geo])
        #expect(NotificationsPresentation.details(for: alert(3, kind: .ip, scope: .ip, value: "1.2.3.4", host: "a.docker.com")) == [.text("a.docker.com"), .via("node"), geo])
        #expect(NotificationsPresentation.details(for: alert(4, kind: .ip, scope: .ip, value: "1.2.3.4", direct: true)) == [.noHostname, .via("node"), geo])
    }

    @Test func leavesOutUnknownProcesses() {
        var unknown = alert(1, kind: .domain, scope: .host, value: "apple-relay.cloudflare.com", ip: "162.159.196.66")
        unknown.processName = "Unknown"
        #expect(NotificationsPresentation.details(for: unknown) == [.text("162.159.196.66"), .text("US · AS13335 Cloudflare")])
        unknown.processName = ""
        #expect(!NotificationsPresentation.details(for: unknown).contains(.via("")))
        #expect(!NotificationsPresentation.isUnknownProcessName("node"))
    }
}

@MainActor
struct NotificationCardLayoutTests {
    /// The time column fits today's time and an older card's day, `Yesterday` or a date, in both languages and at
    /// every factor the UI scale offers.
    @Test func timeColumnFitsItsLabels() {
        let saved = Localizer.shared.override
        defer { Localizer.shared.override = saved }
        let calendar = Calendar(identifier: .gregorian)
        let dates = (1...12).compactMap { calendar.date(from: DateComponents(year: 2026, month: $0, day: 28)) }
        var days: [String] = []
        for language in ["en", "zh-Hans"] {
            Localizer.shared.override = language
            days.append(tr("Yesterday", "Notifications"))
            days += dates.map { Fmt.monthDay($0, locale: Localizer.shared.locale) }
        }
        #expect(days.contains("Sep 28"))
        func width(_ text: String, _ font: NSFont) -> CGFloat {
            (text as NSString).size(withAttributes: [.font: font]).width
        }
        for factor in RequestsTableLayoutTests.factors {
            let font = NSFont.systemFont(ofSize: 11 * factor)
            #expect(width("23:59", font) <= NotificationCard.timeWidth(isToday: true, factor: factor), "at \(factor)")
            for day in days {
                #expect(width(day, font) <= NotificationCard.timeWidth(isToday: false, factor: factor), "\(day) at \(factor)")
            }
        }
        #expect(NotificationCard.todayTimeWidth == NotificationCard.timeWidth(isToday: true, factor: UIScale.factor))
        #expect(NotificationCard.earlierTimeWidth == NotificationCard.timeWidth(isToday: false, factor: UIScale.factor))
    }
}

@MainActor
struct ShellTests {
    /// Each glass surface takes the design's `max(floor, .16 + .76·g)`: the menu bar panel .85, the Mac menu .88, the
    /// dialogs .6 and .85 and the Settings window .72 at the Clear end and at the default 40, more past their floor,
    /// all of them .92 at Tinted.
    @Test func mapsTheGlassPreference() {
        #expect(abs(GlassSurface.glassAlpha(preference: 40) - 0.464) < 0.0001)
        #expect(abs(GlassSurface.dialog.opacity(preference: 80) - 0.768) < 0.0001)
        #expect(GlassSurface.panel.opacity(preference: 0) == 0.85)
        #expect(GlassSurface.panel.opacity(preference: 40) == 0.85)
        #expect(GlassSurface.menu.opacity(preference: 40) == 0.88)
        #expect(GlassSurface.dialog.opacity(preference: 40) == 0.6)
        #expect(GlassSurface.appDialog.opacity(preference: 40) == 0.85)
        #expect(GlassSurface.settings.opacity(preference: 40) == 0.72)
        for surface in [GlassSurface.panel, .menu, .dialog, .appDialog, .settings] {
            #expect(abs(surface.opacity(preference: 100) - 0.92) < 0.0001)
            #expect(surface.opacity(preference: 250) == surface.opacity(preference: 100))
            #expect(surface.opacity(preference: -5) == surface.floor)
        }
    }

    /// The sidebar keeps the system's glass at the Clear end; above it the glass itself is tinted with the design's
    /// glass color at `--glassA`, and its own tint comes back at the Clear end and when the sidebar goes away.
    @Test func tintsTheSidebarGlass() throws {
        #expect(SidebarGlassTint.alpha(preference: 0) == nil)
        #expect(SidebarGlassTint.alpha(preference: -5) == nil)
        #expect(abs(try #require(SidebarGlassTint.alpha(preference: 40)) - 0.464) < 0.0001)
        #expect(abs(try #require(SidebarGlassTint.alpha(preference: 250)) - 0.92) < 0.0001)

        func resolved(_ color: NSColor?, _ appearance: NSAppearance.Name) -> NSColor? {
            var result: NSColor?
            NSAppearance(named: appearance)?.performAsCurrentDrawingAppearance { result = color?.usingColorSpace(.sRGB) }
            return result
        }
        let glass = NSGlassEffectView()
        let ownTint = NSColor.systemPink
        glass.tintColor = ownTint
        let column = NSView()
        glass.contentView = column
        let anchor = SidebarGlassTintAnchor()
        column.addSubview(anchor)

        anchor.apply(alpha: 0.5)
        let light = try #require(resolved(glass.tintColor, .aqua))
        #expect(abs(light.redComponent - 242 / 255) < 0.001)
        #expect(abs(light.blueComponent - 246 / 255) < 0.001)
        #expect(abs(light.alphaComponent - 0.5) < 0.001)
        let dark = try #require(resolved(glass.tintColor, .darkAqua))
        #expect(abs(dark.redComponent - 40 / 255) < 0.001)
        #expect(abs(dark.alphaComponent - 0.5) < 0.001)

        anchor.apply(alpha: nil)
        #expect(glass.tintColor == ownTint)
        anchor.apply(alpha: 0.92)
        anchor.restore()
        #expect(glass.tintColor == ownTint)

        // Outside any glass it does nothing.
        SidebarGlassTintAnchor().apply(alpha: 0.5)
    }

    @Test func listsMacsWithThisMacFirst() {
        Localizer.shared.override = "en"
        let state = DeviceState(thisDeviceID: UIMainFixtures.thisMac)
        state.devices = [
            Device(id: UIMainFixtures.otherMac, name: "Mac mini (Office)", model: nil, shortName: "mini", hue: 150, rowCount: 0, lastWriteAt: .now, createdAt: .now),
            Device(id: UIMainFixtures.thisMac, name: "MacBook Pro", model: nil, shortName: "MBP", hue: 240, rowCount: 0, lastWriteAt: nil, createdAt: .now),
        ]
        let options = SidebarMacOption.options(in: state, matching: "")
        #expect(options.map(\.scope) == [.all, .device(UIMainFixtures.thisMac), .device(UIMainFixtures.otherMac)])
        #expect(options[2].detail == "Online")
        // "All Macs" stays at the top of the menu whatever is typed, as in the design.
        #expect(SidebarMacOption.options(in: state, matching: "mini").map(\.scope) == [.all, .device(UIMainFixtures.otherMac)])
        #expect(SidebarMacOption.options(in: state, matching: "studio").map(\.scope) == [.all])

        #expect(SidebarMacOption.current(in: state).detail == "2 Macs")
        state.scope = .device(UIMainFixtures.thisMac)
        #expect(SidebarMacOption.current(in: state).label == "MacBook Pro")
        #expect(SidebarMacOption.current(in: state).detail == "This Mac")
    }

    @Test func describesLinkStatus() {
        Localizer.shared.override = "en"
        #expect(SidebarStatusText.surge(.connected(detail: "")) == "watching requests")
        #expect(SidebarStatusText.database(.connected(detail: ""), totalRows: 1_284_093) == "1,284,093 rows")
        #expect(SidebarStatusText.help(.failed(DatabaseError.unreachable("connection refused"))) == "PostgreSQL is unreachable: connection refused")
        #expect(SidebarStatusText.help(.failed(CaptureSurgeFailure.shuttingDown)) == "Surge is shutting down")
        #expect(SidebarStatusText.help(.connected(detail: "Surge 6.10.0")) == nil)
        #expect(SidebarStatusText.help(.idle) == nil)

        // A failed link keeps its error: equal errors make equal statuses, so views only update on a new failure.
        #expect(LinkStatus.failed(DatabaseError.notConfigured) == .failed(DatabaseError.notConfigured))
        #expect(LinkStatus.failed(DatabaseError.notConfigured) != .failed(DatabaseError.invalidURL("x")))
        #expect(LinkStatus.failed(CaptureServerRejection(message: "disk full")) == .failed(CaptureServerRejection(message: "disk full")))
        #expect(LinkStatus.failed(CaptureServerRejection(message: "disk full")) != .failed(CaptureServerRejection(message: "read-only")))
        #expect(LinkStatus.failed(CaptureTimeoutError(seconds: 20)) != .failed(DatabaseError.notConfigured))
        #expect(LinkStatus.failed(DatabaseError.notConfigured) != .connecting)
    }
}
