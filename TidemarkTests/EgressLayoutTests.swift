import AppKit
import SwiftUI
import Testing
@testable import Tidemark

/// The Egress IP page's widths at every UI scale: columns that hold their text in both languages, and a page that fits
/// the minimum window.
@MainActor
struct EgressLayoutTests {
    /// Every step the UI scale offers.
    static let factors: [CGFloat] = [1, 1.1, 1.2, 1.3, 1.4, 1.5]

    private static func width(_ text: String, _ font: NSFont, tracking: CGFloat = 0) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: font]).width + tracking * CGFloat(text.count)
    }

    private static func fixedWidth(_ column: AnalyzeColumnsLayout.Column) -> CGFloat? {
        if case .fixed(let width) = column { return width }
        return nil
    }

    /// At the design's window the lookup and This Mac cards sit beside the tables. At the minimum window, whatever the
    /// sidebar's width, they go side by side below them, no narrower than their column, and the tables keep their
    /// minimum.
    @Test func pageFitsTheMinimumWindow() {
        for factor in Self.factors {
            let layout = EgressLayout(factor: factor)
            // The page between its padding, beside the design's sidebar and the window's divider.
            let design = UIScale.length(MainWindowFrame.designSize.width - 244, factor: factor) - 1 - 2 * layout.padding
            #expect(layout.showsSideColumn(width: design), "at \(factor)")
            #expect(design - layout.gap - layout.sideWidth >= layout.tablesMinimum, "at \(factor)")
            for sidebar: CGFloat in [220, 244, 320] {
                let width = UIScale.length(UIScale.minimumWindow.width - sidebar, factor: factor) - 1 - 2 * layout.padding
                #expect(!layout.showsSideColumn(width: width), "beside a \(sidebar) px sidebar at \(factor)")
                #expect(width >= layout.tablesMinimum, "beside a \(sidebar) px sidebar at \(factor)")
                #expect((width - layout.gap) / 2 >= layout.sideWidth, "beside a \(sidebar) px sidebar at \(factor)")
            }
        }
        // Policy 128, Egress IP 150, Location 70, Network 90 and Latency 56, 12 apart, within 16 at either side.
        #expect(EgressLayout(factor: 1).tablesMinimum == 574)
    }

    /// The lookup and This Mac cards' labels stay on one line in either language.
    @Test func keyValueLabelsFitTheirColumn() {
        let labels = ["Country", "ASN", "Organization", "Type", "Reverse DNS", "Interface", "Local IP", "Router", "DNS", "Surge",
                      "国家", "组织", "类型", "反向解析", "接口", "本地 IP", "路由器"]
        for factor in Self.factors {
            let font = NSFont.systemFont(ofSize: 12 * factor)
            for label in labels {
                #expect(Self.width(label, font) <= EgressLayout(factor: factor).labelWidth, "\(label) at \(factor)")
            }
        }
        #expect(EgressLayout.current == EgressLayout(factor: UIScale.factor))
    }

    /// By policy's Egress IP column holds the widest IPv4 address with the NOW tag, and Latency four-digit times and its
    /// title, in either language.
    @Test func policyColumnsFitTheirText() throws {
        for factor in Self.factors {
            let columns = EgressLayout(factor: factor).policyColumns
            let ip = try #require(Self.fixedWidth(columns[1]))
            let latency = try #require(Self.fixedWidth(columns[4]))
            let address = Self.width("255.255.255.255", NSFont.monospacedSystemFont(ofSize: 11.5 * factor, weight: .regular))
            let tag = NSFont.systemFont(ofSize: 9 * factor, weight: .bold)
            for now in ["NOW", "当前"] {
                #expect(address + UIScale.length(6, factor: factor) + Self.width(now, tag, tracking: 0.45 * factor) <= ip, "\(now) at \(factor)")
            }
            #expect(Self.width(Fmt.ms(9999), NSFont.monospacedSystemFont(ofSize: 11 * factor, weight: .regular)) <= latency, "at \(factor)")
            for title in ["Latency", "延迟"] {
                #expect(Self.width(title, NSFont.systemFont(ofSize: 11 * factor, weight: .semibold)) <= latency, "\(title) at \(factor)")
            }
        }
    }

    /// Changes' time column holds the longest time it shows, and the IP column the widest IPv4 address.
    @Test func changesColumnsFitTheirText() throws {
        for factor in Self.factors {
            let columns = EgressLayout(factor: factor).changesColumns
            let time = try #require(Self.fixedWidth(columns[0]))
            let ip = try #require(Self.fixedWidth(columns[1]))
            let font = NSFont.systemFont(ofSize: 12 * factor)
            for label in ["Yesterday 23:59", "昨天 23:59", "Sep 30", "10月24日"] {
                #expect(Self.width(label, font) <= time, "\(label) at \(factor)")
            }
            #expect(Self.width("255.255.255.255", NSFont.monospacedSystemFont(ofSize: 11.5 * factor, weight: .regular)) <= ip, "at \(factor)")
        }
    }
}
