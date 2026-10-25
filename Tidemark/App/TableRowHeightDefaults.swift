import Foundation

/// Keeps every SwiftUI `Table` and `List` out of NSTableView's estimated row heights.
///
/// SwiftUI turns estimated row heights on for each table it builds on macOS 27. In that mode a table without
/// cached row heights that receives more than 200 rows in one update (the live table's backfill, a History page,
/// the Domains & IPs list) caches the heights around its first row and resizes itself before that pass ends; the
/// resize measures the table's total height, which caches the heights around its last row from inside the first
/// pass. AppKit logs that as "Application performed a reentrant operation in its NSTableView delegate" and will
/// turn it into an assert. Without estimates the tables keep automatic row heights and AppKit measures rows as
/// they come into view, at the same cost for tables of Tidemark's size.
enum TableRowHeightDefaults {
    /// AppKit's per-app switch, read once, when the first table is configured.
    static let canEstimateRowHeightsKey = "NSTableViewCanEstimateRowHeights"

    /// Registers the switch; it must run before SwiftUI builds the first window.
    static func register(in defaults: UserDefaults = .standard) {
        defaults.register(defaults: [canEstimateRowHeightsKey: false])
    }
}
