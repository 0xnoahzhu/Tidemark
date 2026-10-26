import AppKit
import Foundation
import Testing
@testable import Tidemark

/// The app page's fixed columns hold their longest text at the shipping UI size, its names keep their room in the
/// narrowest window, and its Installed on row wraps.
@Suite @MainActor struct AppDetailLayoutTests {
    /// The shipping UI size, the factor the layout is checked at.
    static let factor: CGFloat = 1.2

    private static func px(_ value: CGFloat) -> CGFloat {
        UIScale.length(value, factor: factor)
    }

    private static func width(_ text: String, _ font: NSFont) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }

    private static func system(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
        .systemFont(ofSize: size * factor, weight: weight)
    }

    private static func mono(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
        .monospacedSystemFont(ofSize: size * factor, weight: weight)
    }

    /// A `TagBadge`: its text and 5 px either side.
    private static func badge(_ text: String) -> CGFloat {
        width(text, system(9.5, .bold)) + 2 * px(5)
    }

    private static func fixedWidths(_ columns: [AnalyzeColumnsLayout.Column]) -> [CGFloat?] {
        columns.map { column in
            if case .fixed(let width) = column { return width }
            return nil
        }
    }

    /// Time, Remote IP and Size hold History's time, the widest IPv4 address and the longest size; the method column
    /// holds a seven-letter method.
    @Test func requestColumnsFitTheirText() throws {
        let widths = Self.fixedWidths(AppDetailRequestsTab.columns(factor: Self.factor))
        let time = try #require(widths[0]), remoteIP = try #require(widths[3]), size = try #require(widths[5])
        for label in ["10-24 23:59:59", "23:59:59.999"] {
            #expect(Self.width(label, Self.mono(11)) <= time, "\(label)")
        }
        #expect(Self.width("255.255.255.255", Self.mono(11)) <= remoteIP)
        for label in ["999.9 KB", "999.9 MB", "12.34 GB", "1023 B", "failed"] {
            #expect(Self.width(label, Self.mono(11)) <= size, "\(label)")
        }
        for method in ["CONNECT", "OPTIONS"] {
            #expect(Self.width(method, Self.mono(9.5, .semibold)) <= AppDetailRequestsTab.methodWidth(factor: Self.factor), "\(method)")
        }
        #expect(AppDetailRequestsTab.columns == AppDetailRequestsTab.columns(factor: UIScale.factor))
        #expect(AppDetailRequestsTab.methodWidth == AppDetailRequestsTab.methodWidth(factor: UIScale.factor))
    }

    /// First seen holds the long form of yesterday in both languages, Last seen the short form, and the counts and the
    /// IP (with its NEW badge) theirs.
    @Test func inventoryColumnsFitTheirText() throws {
        let domains = Self.fixedWidths(AppDetailInventoryTab.domainColumns(factor: Self.factor))
        let firstSeen = try #require(domains[1]), lastSeen = try #require(domains[2]), requests = try #require(domains[3])
        for label in ["Yesterday 23:59", "Today 23:59", "Sep 30", "昨天 23:59", "今天 23:59", "10月24日"] {
            #expect(Self.width(label, Self.system(12)) <= firstSeen, "\(label)")
        }
        for label in ["23:59", "Yesterday", "Sep 30", "昨天", "10月24日"] {
            #expect(Self.width(label, Self.mono(11)) <= lastSeen, "\(label)")
        }
        #expect(Self.width("1,234,567", Self.mono(11, .semibold)) <= requests)
        // Without First seen, the other columns are the same.
        #expect(Self.fixedWidths(AppDetailInventoryTab.domainColumns(factor: Self.factor, showsFirstSeen: false)) == [nil, lastSeen, requests])

        let ips = Self.fixedWidths(AppDetailInventoryTab.ipColumns(factor: Self.factor))
        let ip = try #require(ips[0]), ipRequests = try #require(ips[2])
        // The address, 6 px, and a NEW badge.
        #expect(Self.width("255.255.255.255", Self.mono(11.5)) + Self.px(6) + Self.badge("NEW") <= ip)
        #expect(Self.width("1,234,567", Self.mono(11)) <= ipRequests)
        #expect(AppDetailInventoryTab.domainColumns == AppDetailInventoryTab.domainColumns(factor: UIScale.factor))
        #expect(AppDetailInventoryTab.narrowDomainColumns == AppDetailInventoryTab.domainColumns(factor: UIScale.factor, showsFirstSeen: false))
        #expect(AppDetailInventoryTab.ipColumns == AppDetailInventoryTab.ipColumns(factor: UIScale.factor))
    }

    /// The counts hold seven digits and the State column its chip, 7 px either side, in both languages.
    @Test func processTreeColumnsFitTheirText() throws {
        let widths = Self.fixedWidths(AppDetailProcessTreeTab.columns(factor: Self.factor))
        let domains = try #require(widths[1]), requests = try #require(widths[2]), state = try #require(widths[3])
        #expect(Self.width("99,999", Self.mono(11.5)) <= domains)
        #expect(Self.width("1,234,567", Self.mono(11.5)) <= requests)
        for label in ["Running", "Exited", "运行中", "已退出"] {
            #expect(Self.width(label, Self.system(11, .medium)) + 2 * Self.px(7) <= state, "\(label)")
        }
        #expect(AppDetailProcessTreeTab.columns == AppDetailProcessTreeTab.columns(factor: UIScale.factor))
    }

    /// The page's width at the narrowest window beside the sidebar's 244 px.
    private static let narrowestPage = px(UIScale.minimumWindow.width - 244)

    /// An always-visible scroller's width.
    private static let scroller = NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy)

    /// The widths of `columns`, 10 px apart, laid out `total` wide.
    private static func widths(_ columns: [AnalyzeColumnsLayout.Column], total: CGFloat) -> [CGFloat] {
        AnalyzeColumnsLayout.widths(for: columns, spacing: px(10), total: total)
    }

    /// The width `columns` take, 10 px apart, laid out `total` wide.
    private static func laidOut(_ columns: [AnalyzeColumnsLayout.Column], total: CGFloat) -> CGFloat {
        let widths = widths(columns, total: total)
        return widths.reduce(0, +) + px(10) * CGFloat(widths.count - 1)
    }

    /// At the narrowest window the request table, beside a scroller, keeps every column at its minimum and no wider
    /// than the page.
    @Test func requestColumnsFitTheNarrowestWindow() {
        let total = Self.narrowestPage - 2 * Self.px(20) - Self.scroller
        #expect(Self.laidOut(AppDetailRequestsTab.columns(factor: Self.factor), total: total) <= total + 0.001)
    }

    /// At the narrowest window, beside a scroller, BY IP gives way before the host, and the host keeps ten characters
    /// of an address beside the method and NEW, in both languages.
    @Test func hostKeepsItsTextAtTheNarrowestWindow() {
        let total = Self.narrowestPage - 2 * Self.px(20) - Self.scroller
        let column = Self.widths(AppDetailRequestsTab.columns(factor: Self.factor), total: total)[2]
        let room = column - AppDetailRequestsTab.methodWidth(factor: Self.factor) - Self.px(6)
        let host = Self.width("183.3.226.35", Self.system(12))
        for (byIP, new) in [("BY IP", "NEW"), ("直连 IP", "新")] {
            let items = [AppDetailNameLayout.Item(ideal: Self.badge(byIP), narrowest: 0),
                         AppDetailNameLayout.Item(ideal: Self.badge(new), narrowest: Self.badge(new))]
            let widths = AppDetailNameLayout.widths(name: host, items: items, spacing: Self.px(6), width: room)
            #expect(widths[1] == 0, "\(byIP)")
            #expect(widths[2] == Self.badge(new), "\(new)")
            #expect(widths[0] >= Self.width("255.255.25", Self.system(12)), "\(new)")
        }
    }

    /// The Domains & IPs panes split 1.4 to 1, as in the design. At the narrowest window, beside scrollers, the Domains
    /// pane drops First seen so the site keeps its 150 px and the network its 90 px, and neither pane's columns run
    /// past it.
    @Test func inventoryPanesFitTheNarrowestWindow() {
        // The design's page, beside the sidebar in the default window.
        let design = Self.px(MainWindowFrame.designSize.width - 244)
        #expect(AppDetailInventoryTab.split(design, factor: Self.factor) == .init(domainsWidth: design * 1.4 / 2.4, showsFirstSeen: true))

        let page = Self.narrowestPage
        let split = AppDetailInventoryTab.split(page, factor: Self.factor)
        #expect(!split.showsFirstSeen)
        let padding = 2 * Self.px(16)
        let domains = AppDetailInventoryTab.domainColumns(factor: Self.factor, showsFirstSeen: split.showsFirstSeen)
        let ips = AppDetailInventoryTab.ipColumns(factor: Self.factor)
        let domainTotal = split.domainsWidth - padding - Self.scroller
        let ipTotal = page - split.domainsWidth - 0.5 - padding - Self.scroller
        #expect(Self.laidOut(domains, total: domainTotal) <= domainTotal + 0.001)
        #expect(Self.laidOut(ips, total: ipTotal) <= ipTotal + 0.001)
        #expect(Self.widths(ips, total: ipTotal)[1] >= Self.px(90) - 0.001)
        #expect(Self.widths(domains, total: domainTotal)[0] >= Self.px(150) - 0.001)
    }

    /// At the narrowest window a site keeps its name: a short one with its host count and NEW SITE, a long one whole
    /// once the count has gone and, where needed, NEW SITE has become NEW, in both languages.
    @Test func sitesKeepTheirNamesAtTheNarrowestWindow() {
        let page = Self.narrowestPage
        let split = AppDetailInventoryTab.split(page, factor: Self.factor)
        let domains = AppDetailInventoryTab.domainColumns(factor: Self.factor, showsFirstSeen: split.showsFirstSeen)
        let column = Self.widths(domains, total: split.domainsWidth - 2 * Self.px(16) - Self.scroller)[0]
        for (count, newSite, new) in [("1 host", "NEW SITE", "NEW"), ("2 个主机", "新站点", "新")] {
            let items = [AppDetailNameLayout.Item(ideal: Self.width(count, Self.system(11)), narrowest: 0),
                         AppDetailNameLayout.Item(ideal: Self.badge(newSite), narrowest: Self.badge(new))]
            let short = Self.width("github.com", Self.system(12.5, .semibold))
            #expect(AppDetailNameLayout.widths(name: short, items: items, spacing: Self.px(8), width: column)
                == [short, items[0].ideal, items[1].ideal], "\(newSite)")
            let long = Self.width("githubusercontent.com", Self.system(12.5, .semibold))
            let widths = AppDetailNameLayout.widths(name: long, items: items, spacing: Self.px(8), width: column)
            #expect(widths[0] == long && widths[1] == 0, "\(newSite)")
            #expect([Self.badge(newSite), Self.badge(new)].contains(widths[2]), "\(newSite)")
        }
    }

    /// What follows a name gives way in its order, each to its narrowest form, before the name shortens.
    @Test func nameLayoutGivesWayInOrder() {
        let items = [AppDetailNameLayout.Item(ideal: 40, narrowest: 0), AppDetailNameLayout.Item(ideal: 60, narrowest: 30)]
        #expect(AppDetailNameLayout.widths(name: 100, items: items, spacing: 10, width: 220) == [100, 40, 60])
        // The first item goes; the second keeps its whole form.
        #expect(AppDetailNameLayout.widths(name: 100, items: items, spacing: 10, width: 200) == [100, 0, 60])
        // Then the second takes its narrowest form.
        #expect(AppDetailNameLayout.widths(name: 100, items: items, spacing: 10, width: 150) == [100, 0, 30])
        // Then the name shortens.
        #expect(AppDetailNameLayout.widths(name: 100, items: items, spacing: 10, width: 90) == [50, 0, 30])
        #expect(AppDetailNameLayout.widths(name: 100, items: items, spacing: 10, width: 20) == [0, 0, 30])
    }

    /// Last seen reads like the design's column: the time today, `Yesterday` without its time, then the day.
    @Test func lastSeenUsesTheShortForm() throws {
        let calendar = Calendar.current
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 24, hour: 15, minute: 2)))
        let today = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 24, hour: 14, minute: 31)))
        let yesterday = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 23, hour: 19, minute: 59)))
        let earlier = try #require(calendar.date(from: DateComponents(year: 2026, month: 9, day: 30, hour: 9)))
        Localizer.shared.override = "en"
        #expect(AppDetailInventoryFormat.lastSeen(today, now: now) == Fmt.hm(today))
        #expect(AppDetailInventoryFormat.lastSeen(yesterday, now: now) == "Yesterday")
        #expect(AppDetailInventoryFormat.lastSeen(earlier, now: now) == Fmt.monthDay(earlier, locale: Locale(identifier: "en")))

        Localizer.shared.override = "zh-Hans"
        defer { Localizer.shared.override = "en" }
        guard Localizer.shared.bundle != nil else { return }
        #expect(AppDetailInventoryFormat.lastSeen(yesterday, now: now) == "昨天")
        #expect(AppDetailInventoryFormat.lastSeen(earlier, now: now) == "9月30日")
    }

    /// The label and chips go on as many rows as they need, 8 px apart, each centered on its row, rather than past the
    /// right edge.
    @Test func installsWrapOntoMoreRows() {
        let sizes = [CGSize(width: 70, height: 15), CGSize(width: 150, height: 19), CGSize(width: 160, height: 19), CGSize(width: 120, height: 19)]
        let oneRow = AppDetailInstallsLayout.frames(for: sizes, width: 600, spacing: 8)
        #expect(oneRow.map(\.minX) == [0, 78, 236, 404])
        #expect(oneRow.map(\.minY) == [2, 0, 0, 0])

        let wrapped = AppDetailInstallsLayout.frames(for: sizes, width: 400, spacing: 8)
        #expect(wrapped.map(\.minX) == [0, 78, 236, 0])
        #expect(wrapped.map(\.minY) == [2, 0, 0, 27])
        #expect(wrapped.allSatisfy { $0.maxX <= 400 })

        // A chip wider than the row gets the row, on a row of its own.
        let narrow = AppDetailInstallsLayout.frames(for: sizes, width: 120, spacing: 8)
        #expect(narrow.map(\.minY) == [0, 23, 50, 77])
        #expect(narrow.map(\.width) == [70, 120, 120, 120])
    }
}
