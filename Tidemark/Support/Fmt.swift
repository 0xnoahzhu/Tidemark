import Foundation

/// Formatting used across the UI, matching the prototype's number and time styles.
enum Fmt {
    /// `1,284,093`
    static func count<T: BinaryInteger>(_ n: T) -> String {
        groupingFormatter.string(from: NSNumber(value: Int64(n))) ?? String(n)
    }

    private static let groupingFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.locale = Locale(identifier: "en_US")
        f.numberStyle = .decimal
        f.usesGroupingSeparator = true
        return f
    }()

    /// `1.28M`, `48.2K`, `9,412` (≥ 10 000 abbreviated, like the prototype's `short`).
    static func short<T: BinaryInteger>(_ n: T) -> String {
        let v = Double(n)
        if v >= 1_000_000 { return String(format: "%.2fM", v / 1_000_000) }
        if v >= 10_000 { return String(format: "%.1fK", v / 1_000) }
        return count(n)
    }

    /// `15.4 KB`, `1.2 MB`, `820 B`
    static func bytes(_ n: Int64) -> String {
        let v = Double(n)
        if v < 1024 { return "\(n) B" }
        if v < 1024 * 1000 { return String(format: "%.1f KB", v / 1024) }
        if v < 1024 * 1024 * 1000 { return String(format: "%.1f MB", v / 1024 / 1024) }
        return String(format: "%.2f GB", v / 1024 / 1024 / 1024)
    }

    /// `2.3/s`
    static func rate(_ perSecond: Double) -> String { String(format: "%.1f/s", perSecond) }

    /// `1.2 MB/s`
    static func speed(_ bytesPerSecond: Int64) -> String { bytes(bytesPerSecond) + "/s" }

    /// `14:32:27.130` (local time, milliseconds).
    static func clock(_ date: Date) -> String {
        clockFormatter.string(from: date)
    }

    /// `14:32`
    static func hm(_ date: Date) -> String { hmFormatter.string(from: date) }

    /// `14:31:52`
    static func hms(_ date: Date) -> String { hmsFormatter.string(from: date) }

    /// `10-24 14:32:27` for history rows.
    static func dayClock(_ date: Date) -> String { dayClockFormatter.string(from: date) }

    /// Relative day label used in inventories: `Today 14:31`, `Yesterday 21:16`, `Sep 30`.
    /// `timeOnlyToday` renders today's dates as bare `14:31` (the prototype's "Last seen" column).
    static func seen(_ date: Date, now: Date = .now, timeOnlyToday: Bool = false, locale: Locale = .current) -> SeenLabel {
        let cal = Calendar.current
        if cal.isDate(date, inSameDayAs: now) {
            return timeOnlyToday ? .time(hm(date)) : .today(hm(date))
        }
        if let y = cal.date(byAdding: .day, value: -1, to: now), cal.isDate(date, inSameDayAs: y) {
            return .yesterday(hm(date))
        }
        return .date(date)
    }

    /// The day bucket for notification sections.
    enum SeenLabel: Equatable {
        case time(String)
        case today(String)
        case yesterday(String)
        case date(Date)
    }

    /// `Sep 30` / `9月30日` depending on the locale.
    static func monthDay(_ date: Date, locale: Locale) -> String {
        date.formatted(.dateTime.month(.abbreviated).day().locale(locale))
    }

    /// `12 ms`
    static func ms(_ value: Double) -> String { "\(Int(value.rounded())) ms" }

    /// `9.6s`
    static func seconds(_ t: TimeInterval) -> String { String(format: "%.1fs", t) }

    private static let clockFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    private static let hmFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm"
        return f
    }()

    private static let hmsFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    private static let dayClockFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MM-dd HH:mm:ss"
        return f
    }()
}
