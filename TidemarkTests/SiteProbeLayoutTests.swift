import AppKit
import SwiftUI
import Testing
@testable import Tidemark

/// The Site Probe page's widths at every UI scale: waterfall columns that hold their text in both languages, and a
/// page that fits the minimum window.
@MainActor
struct SiteProbeLayoutTests {
    /// Every step the UI scale offers.
    static let factors: [CGFloat] = [1, 1.1, 1.2, 1.3, 1.4, 1.5]

    private static func width(_ text: String, _ font: NSFont) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: font]).width
    }

    private static func fixedWidth(_ column: AnalyzeColumnsLayout.Column) -> CGFloat? {
        if case .fixed(let width) = column { return width }
        return nil
    }

    /// The waterfall's IP and Reqs columns hold their titles in either language and the counts a session reaches.
    @Test func waterfallCountsFitTheirColumns() throws {
        for factor in Self.factors {
            let columns = ProbeWaterfall.columns(factor: factor)
            let ip = try #require(Self.fixedWidth(columns[1]))
            let requests = try #require(Self.fixedWidth(columns[2]))
            let title = NSFont.systemFont(ofSize: 11 * factor, weight: .semibold)
            let count = NSFont.monospacedSystemFont(ofSize: 11 * factor, weight: .regular)
            #expect(max(Self.width("IP", title), Self.width("999", count)) <= ip, "at \(factor)")
            for label in ["Reqs", "请求"] {
                #expect(Self.width(label, title) <= requests, "\(label) at \(factor)")
            }
            #expect(Self.width("9999", count) <= requests, "at \(factor)")
        }
        #expect(ProbeWaterfall.columns == ProbeWaterfall.columns(factor: UIScale.factor))
        #expect(ProbeWaterfall.minimumWidth == ProbeWaterfall.minimumWidth(factor: UIScale.factor))
        // Host 180, IP 26, Reqs 34 and the bars' 120, 10 apart.
        #expect(ProbeWaterfall.minimumWidth(factor: 1) == 390)
    }

    /// At the minimum window, whatever the sidebar's width, the browser card and the waterfall fit beside each other
    /// with the waterfall at its minimum or wider: the sessions give way first, then the card narrows.
    @Test func sessionFitsTheMinimumWindow() {
        for factor in Self.factors {
            let layout = SiteProbeLayout(factor: factor)
            let window = UIScale.length(UIScale.minimumWindow.width, factor: factor)
            // The sidebar's narrowest, ideal and widest column, and the window's divider.
            for sidebar: CGFloat in [220, 244, 320] {
                let page = window - UIScale.length(sidebar, factor: factor) - 1
                let sessions = layout.showsSessions(pageWidth: page)
                let total = page - 2 * layout.padding - (sessions ? layout.sessionsWidth + 0.5 : 0)
                for mode in ProbeDeviceMode.allCases {
                    let card = layout.cardWidth(total: total, mode: mode)
                    #expect(card >= layout.cardMinimum, "\(mode) beside a \(sidebar) px sidebar at \(factor)")
                    #expect(card + layout.gap + layout.waterfallMinimum <= total, "\(mode) beside a \(sidebar) px sidebar at \(factor)")
                }
                // With the design's sidebar the card keeps the design's 256 px.
                if sidebar == 244 {
                    #expect(!sessions, "at \(factor)")
                    #expect(layout.cardWidth(total: total, mode: .desktop) >= layout.cardWidths.lowerBound, "at \(factor)")
                }
            }
            // Without the sidebar the minimum window has room for the sessions too.
            #expect(layout.showsSessions(pageWidth: window), "at \(factor)")
        }
    }

    /// The design's window shows the sessions, the card and the waterfall side by side at every factor.
    @Test func designWindowShowsTheSessions() {
        for factor in Self.factors {
            let layout = SiteProbeLayout(factor: factor)
            let page = UIScale.length(MainWindowFrame.designSize.width - 244, factor: factor) - 1
            #expect(layout.showsSessions(pageWidth: page), "at \(factor)")
            let total = page - 2 * layout.padding - layout.sessionsWidth - 0.5
            let card = layout.cardWidth(total: total, mode: .desktop)
            #expect(card >= layout.cardWidths.lowerBound && card + layout.gap + layout.waterfallMinimum <= total, "at \(factor)")
        }
        #expect(SiteProbeLayout.current == SiteProbeLayout(factor: UIScale.factor))
    }

    /// The iPhone page is web content: the card grows no wider than its viewport at any factor.
    @Test func iPhoneCardStaysWithinTheViewport() {
        for factor in Self.factors {
            let layout = SiteProbeLayout(factor: factor)
            #expect(layout.cardWidth(total: 3000, mode: .iphone) == ProbeWebSession.iPhoneViewport.width, "at \(factor)")
            #expect(layout.cardWidth(total: 3000, mode: .desktop) == layout.cardWidths.upperBound, "at \(factor)")
        }
    }
}
