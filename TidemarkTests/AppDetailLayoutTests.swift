import AppKit
import Foundation
import Testing
@testable import Tidemark

/// The app page's fixed columns hold their longest text at every UI scale.
@Suite @MainActor struct AppDetailLayoutTests {
    /// The factors the column widths are checked at: every step the UI scale offers.
    static let factors: [CGFloat] = [1, 1.1, 1.2, 1.3, 1.4, 1.5]

    private static func width(_ text: String, _ font: NSFont) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }

    private static func mono(_ px: CGFloat, _ factor: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
        .monospacedSystemFont(ofSize: px * factor, weight: weight)
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
        for factor in Self.factors {
            let widths = Self.fixedWidths(AppDetailRequestsTab.columns(factor: factor))
            let time = try #require(widths[0]), remoteIP = try #require(widths[3]), size = try #require(widths[5])
            for label in ["10-24 23:59:59", "23:59:59.999"] {
                #expect(Self.width(label, Self.mono(11, factor)) <= time, "\(label) at \(factor)")
            }
            #expect(Self.width("255.255.255.255", Self.mono(11, factor)) <= remoteIP, "at \(factor)")
            for label in ["999.9 KB", "999.9 MB", "12.34 GB", "1023 B", "failed"] {
                #expect(Self.width(label, Self.mono(11, factor)) <= size, "\(label) at \(factor)")
            }
            for method in ["CONNECT", "OPTIONS"] {
                #expect(Self.width(method, Self.mono(9.5, factor, .semibold)) <= AppDetailRequestsTab.methodWidth(factor: factor), "\(method) at \(factor)")
            }
        }
        #expect(AppDetailRequestsTab.columns == AppDetailRequestsTab.columns(factor: UIScale.factor))
        #expect(AppDetailRequestsTab.methodWidth == AppDetailRequestsTab.methodWidth(factor: UIScale.factor))
    }

    /// First seen holds the long form of yesterday in both languages, and the counts and the IP (with its NEW badge)
    /// theirs.
    @Test func inventoryColumnsFitTheirText() throws {
        for factor in Self.factors {
            let domains = Self.fixedWidths(AppDetailInventoryTab.domainColumns(factor: factor))
            let firstSeen = try #require(domains[1]), requests = try #require(domains[3])
            for label in ["Yesterday 23:59", "Today 23:59", "Sep 30", "昨天 23:59", "今天 23:59", "10月24日"] {
                #expect(Self.width(label, .systemFont(ofSize: 12 * factor)) <= firstSeen, "\(label) at \(factor)")
            }
            #expect(Self.width("1,234,567", Self.mono(11, factor, .semibold)) <= requests, "at \(factor)")

            let ips = Self.fixedWidths(AppDetailInventoryTab.ipColumns(factor: factor))
            let ip = try #require(ips[0]), ipRequests = try #require(ips[2])
            // The address, 6 px, and a NEW badge: its text and 5 px either side.
            let badge = Self.width("NEW", .systemFont(ofSize: 9.5 * factor, weight: .bold)) + 2 * UIScale.length(5, factor: factor)
            let address = Self.width("255.255.255.255", Self.mono(11.5, factor))
            #expect(address + UIScale.length(6, factor: factor) + badge <= ip, "at \(factor)")
            #expect(Self.width("123,456", Self.mono(11, factor)) <= ipRequests, "at \(factor)")
        }
        #expect(AppDetailInventoryTab.domainColumns == AppDetailInventoryTab.domainColumns(factor: UIScale.factor))
        #expect(AppDetailInventoryTab.ipColumns == AppDetailInventoryTab.ipColumns(factor: UIScale.factor))
    }

    /// The counts hold seven digits and the State column its chip, 7 px either side, in both languages.
    @Test func processTreeColumnsFitTheirText() throws {
        for factor in Self.factors {
            let widths = Self.fixedWidths(AppDetailProcessTreeTab.columns(factor: factor))
            let domains = try #require(widths[1]), requests = try #require(widths[2]), state = try #require(widths[3])
            #expect(Self.width("99,999", Self.mono(11.5, factor)) <= domains, "at \(factor)")
            #expect(Self.width("1,234,567", Self.mono(11.5, factor)) <= requests, "at \(factor)")
            for label in ["Running", "Exited", "运行中", "已退出"] {
                let chip = Self.width(label, .systemFont(ofSize: 11 * factor, weight: .medium)) + 2 * UIScale.length(7, factor: factor)
                #expect(chip <= state, "\(label) at \(factor)")
            }
        }
        #expect(AppDetailProcessTreeTab.columns == AppDetailProcessTreeTab.columns(factor: UIScale.factor))
    }
}
