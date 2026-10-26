import SwiftUI
import UniformTypeIdentifiers

// Building blocks shared by the Analyze pages (monitored app, Domains & IPs, Site Probe, Egress IP).

// MARK: - Column layout

/// Lays out the cells of a hand-built table row: fixed columns keep their width and flexible columns
/// share the rest by weight, never shrinking below their minimum or growing past their maximum (what a
/// capped column cannot take goes to the others). Every row of a table uses the same column list, so
/// cells line up without a `Grid`. Cells are centered vertically; a cell that should fill its column
/// (right-aligned numbers, chips) uses `.frame(maxWidth: .infinity, alignment:)`.
struct AnalyzeColumnsLayout: Layout {
    enum Column: Hashable, Sendable {
        case fixed(CGFloat)
        case flexible(weight: CGFloat = 1, min: CGFloat = 0, max: CGFloat = .infinity)
    }

    var columns: [Column]
    var spacing: CGFloat = 10.px
    /// Aligns cells to the top of the row instead of centering them (multi-line cards).
    var topAligned = false

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? idealWidth
        let widths = Self.widths(for: columns, spacing: spacing, total: width)
        var height: CGFloat = 0
        for (index, subview) in subviews.enumerated() where index < widths.count {
            height = max(height, subview.sizeThatFits(ProposedViewSize(width: widths[index], height: nil)).height)
        }
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let widths = Self.widths(for: columns, spacing: spacing, total: bounds.width)
        var x = bounds.minX
        for (index, subview) in subviews.enumerated() {
            guard index < widths.count else {
                subview.place(at: CGPoint(x: bounds.maxX, y: bounds.midY), anchor: .leading, proposal: .zero)
                continue
            }
            subview.place(at: CGPoint(x: x, y: topAligned ? bounds.minY : bounds.midY),
                          anchor: topAligned ? .topLeading : .leading,
                          proposal: ProposedViewSize(width: widths[index], height: nil))
            x += widths[index] + spacing
        }
    }

    private var idealWidth: CGFloat {
        columns.reduce(spacing * CGFloat(max(0, columns.count - 1))) { total, column in
            switch column {
            case .fixed(let width): total + width
            case .flexible(_, let minimum, let maximum): total + max(minimum, min(80, maximum))
            }
        }
    }

    /// Column widths for a row `total` points wide.
    static func widths(for columns: [Column], spacing: CGFloat, total: CGFloat) -> [CGFloat] {
        var result = [CGFloat](repeating: 0, count: columns.count)
        var available = total - spacing * CGFloat(max(0, columns.count - 1))
        var pool: [Int] = []
        for (index, column) in columns.enumerated() {
            switch column {
            case .fixed(let width):
                result[index] = width
                available -= width
            case .flexible:
                pool.append(index)
            }
        }
        available = max(0, available)
        while !pool.isEmpty {
            let totalWeight = pool.reduce(CGFloat(0)) { $0 + weight(columns[$1]) }
            let shares = pool.map { share(available, weight(columns[$0]), totalWeight) }
            let short = pool.indices.filter { shares[$0] < minimum(columns[pool[$0]]) }
            let over = pool.indices.filter { shares[$0] > maximum(columns[pool[$0]]) }
            if short.isEmpty && over.isEmpty {
                for (index, share) in zip(pool, shares) { result[index] = share }
                break
            }
            // Pin the first column outside its bounds, then share the rest again. As in CSS flexbox, columns
            // below their minimum go first when they lack more than the capped columns would give back.
            let missing = short.reduce(CGFloat(0)) { $0 + minimum(columns[pool[$1]]) - shares[$1] }
            let surplus = over.reduce(CGFloat(0)) { $0 + shares[$1] - maximum(columns[pool[$1]]) }
            let toMinimum = missing >= surplus
            let pinned = pool[toMinimum ? short[0] : over[0]]
            result[pinned] = toMinimum ? minimum(columns[pinned]) : maximum(columns[pinned])
            available = max(0, available - result[pinned])
            pool.removeAll { $0 == pinned }
        }
        return result
    }

    private static func share(_ available: CGFloat, _ weight: CGFloat, _ totalWeight: CGFloat) -> CGFloat {
        totalWeight > 0 ? available * weight / totalWeight : 0
    }

    private static func weight(_ column: Column) -> CGFloat {
        if case .flexible(let weight, _, _) = column { return max(0, weight) }
        return 0
    }

    private static func minimum(_ column: Column) -> CGFloat {
        if case .flexible(_, let minimum, _) = column { return minimum }
        return 0
    }

    private static func maximum(_ column: Column) -> CGFloat {
        if case .flexible(_, _, let maximum) = column { return maximum }
        return .infinity
    }
}

/// Grey column titles above a hand-built table, with a hairline underneath.
struct AnalyzeHeaderRow<Content: View>: View {
    var columns: [AnalyzeColumnsLayout.Column]
    var spacing: CGFloat = 10.px
    var height: CGFloat = 28.px
    var horizontalPadding: CGFloat = 20.px
    @ViewBuilder var content: Content

    var body: some View {
        AnalyzeColumnsLayout(columns: columns, spacing: spacing) { content }
            .font(.design(11, .semibold))
            .foregroundStyle(Theme.ink2)
            .lineLimit(1)
            .padding(.horizontal, horizontalPadding)
            .frame(height: height)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 0.5) }
    }
}

/// A rounded chip such as `4 new domains in 24 h` or `Rule FINAL`.
struct AnalyzePill: View {
    enum Style { case new, neutral }
    var text: String
    var style: Style = .new
    /// The text's size in design px.
    var size: CGFloat = 11.5

    var body: some View {
        Text(text)
            .font(.design(size, style == .new ? .semibold : .regular))
            .lineLimit(1)
            .padding(.horizontal, 9.px)
            .padding(.vertical, 3.px)
            .background(style == .new ? Color(oklch: 0.8, 0.14, 75, alpha: 0.24) : Theme.fill, in: Capsule())
            .foregroundStyle(style == .new ? Theme.amberInk : Theme.ink2)
            .fixedSize()
    }
}

// MARK: - Formatting

/// Localized date labels and emphasized sentences used by the Analyze pages.
@MainActor
enum AnalyzeFormat {
    /// `Today 14:31`, `Yesterday 21:16`, `Sep 30` (and `14:31` for today when `timeOnlyToday`).
    static func seen(_ date: Date, timeOnlyToday: Bool = false, now: Date = .now) -> String {
        switch Fmt.seen(date, now: now, timeOnlyToday: timeOnlyToday) {
        case .time(let time): time
        case .today(let time): trf("Today %@", "Inventory", time)
        case .yesterday(let time): trf("Yesterday %@", "Inventory", time)
        case .date(let day): Fmt.monthDay(day, locale: Localizer.shared.locale)
        }
    }

    /// Fills the single `%@` of a localized `format` with `value` in a heavier, darker style. The run's font replaces
    /// the `Text`'s, so it takes the sentence's design `size` in px.
    static func emphasized(_ format: String, _ value: String, size: CGFloat, weight: Font.Weight = .semibold) -> AttributedString {
        let parts = format.components(separatedBy: "%@")
        var result = AttributedString(parts.first ?? "")
        guard parts.count > 1 else { return result }
        var highlighted = AttributedString(value)
        highlighted.swiftUI.font = .design(size, weight)
        highlighted.swiftUI.foregroundColor = Theme.ink
        result += highlighted
        result += AttributedString(parts.dropFirst().joined(separator: "%@"))
        return result
    }
}

// MARK: - CSV export

/// Builds RFC 4180 CSV text for the Domains & IPs exports.
enum AnalyzeCSV {
    static func escape(_ field: String) -> String {
        guard field.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else { return field }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    static func make(header: [String], rows: [[String]]) -> String {
        ([header] + rows).map { $0.map(escape).joined(separator: ",") }.joined(separator: "\r\n") + "\r\n"
    }

    /// One row per domain or IP of a monitored app's inventory.
    static func appHosts(_ hosts: [AppHost], now: Date = .now) -> String {
        let header = ["kind", "value", "site", "first_seen", "last_seen", "requests", "new",
                      "by_ip_only", "resolved_from", "country", "asn", "organization", "policy", "first_process"]
        let rows = hosts.map { host in
            [host.kind.rawValue, host.value, host.site ?? "", timestamp(host.firstSeen), timestamp(host.lastSeen),
             String(host.requestCount), host.isNew(now: now) ? "yes" : "no",
             host.kind == .ip && host.isDirect ? "yes" : "no", host.hosts.joined(separator: " "),
             host.geo?.countryCode ?? "", host.geo?.asn.map { "AS\($0)" } ?? "", host.geo?.organization ?? "",
             host.policy ?? "", host.processName ?? ""]
        }
        return make(header: header, rows: rows)
    }

    /// One row per entry of the global Domains & IPs page.
    static func inventory(_ entries: [InventoryEntry]) -> String {
        let header = ["kind", "value", "first_seen", "last_seen", "requests", "country", "asn", "organization", "seen_by"]
        let rows = entries.map { entry in
            [entry.kind.rawValue, entry.value, timestamp(entry.firstSeen), timestamp(entry.lastSeen),
             String(entry.requestCount), entry.geo?.countryCode ?? "", entry.geo?.asn.map { "AS\($0)" } ?? "",
             entry.geo?.organization ?? "", entry.sources.map(\.path).joined(separator: " | ")]
        }
        return make(header: header, rows: rows)
    }

    private static func timestamp(_ date: Date) -> String {
        date.formatted(.iso8601)
    }
}

/// A CSV file for the macOS 27 document-based `fileExporter(isPresented:document:…)`.
final class AnalyzeCSVDocument: WritableDocument {
    static var writableContentTypes: [UTType] { [.commaSeparatedText] }

    private let data: Data

    init(text: String) {
        data = Data(text.utf8)
    }

    func writer(configuration: sending WriteConfiguration) -> sending FileWrapperDocumentWriter<Data> {
        FileWrapperDocumentWriter(configuration) { snapshot, _ in
            FileWrapper(regularFileWithContents: snapshot)
        }
    }

    @MainActor
    func snapshot(contentType: UTType) async throws -> sending Data { data }
}
