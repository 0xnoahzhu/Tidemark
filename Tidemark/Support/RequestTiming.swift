import Foundation

/// A phase of a request's lifetime for the inspector's timing bar.
struct TimingPhase: Hashable, Sendable {
    enum Kind: String, CaseIterable, Sendable {
        case dns = "DNS"
        case rule = "Rule"
        case connect = "Connect"
        case tls = "TLS"
        case transfer = "Transfer"
    }

    var kind: Kind
    var duration: TimeInterval
}

/// Builds timing phases from Surge's timestamps and its per-request notes.
///
/// Notes look like `12:07:22.102428 [TLS] TLS Client Hello SNI: api2.cursor.sh`. The first note of each
/// category marks where that phase starts; the setup ends at `setupCompletedDate` and the transfer runs
/// until `completedDate` (or now, for active connections).
enum RequestTiming {
    struct Note: Hashable, Sendable {
        /// Seconds since midnight (local), as printed by Surge.
        var secondsOfDay: TimeInterval
        var tag: String
        var text: String
    }

    static func parse(note: String) -> Note? {
        // "HH:mm:ss.ffffff [Tag] text"
        let parts = note.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard parts.count == 2 else { return nil }
        let clock = parts[0].split(separator: ":")
        guard clock.count == 3, let h = Double(clock[0]), let m = Double(clock[1]), let s = Double(clock[2]) else { return nil }
        let rest = parts[1]
        guard rest.hasPrefix("["), let close = rest.firstIndex(of: "]") else { return nil }
        let tag = String(rest[rest.index(after: rest.startIndex)..<close])
        let text = rest[rest.index(after: close)...].trimmingCharacters(in: .whitespaces)
        return Note(secondsOfDay: h * 3600 + m * 60 + s, tag: tag, text: text)
    }

    static func kind(forTag tag: String) -> TimingPhase.Kind? {
        switch tag.lowercased() {
        case "dns": .dns
        case "rule": .rule
        case "tls": .tls
        case "connector", "connection-pool", "socket", "proxy", "connect": .connect
        default: nil
        }
    }

    static func phases(for record: RequestRecord, now: Date = .now) -> [TimingPhase] {
        let start = record.startedAt
        let startOfDay = Calendar.current.startOfDay(for: start)
        let setupEnd = record.setupCompletedAt ?? start
        let end = record.completedAt ?? (record.state == .active ? now : setupEnd)

        // First timestamp of each phase, as absolute dates.
        var marks: [(TimingPhase.Kind, Date)] = []
        var seen = Set<TimingPhase.Kind>()
        for raw in record.notes {
            guard let note = parse(note: raw), let kind = kind(forTag: note.tag), !seen.contains(kind) else { continue }
            var date = startOfDay.addingTimeInterval(note.secondsOfDay)
            if date < start.addingTimeInterval(-60) { date = date.addingTimeInterval(86400) } // crossed midnight
            seen.insert(kind)
            marks.append((kind, max(start, min(date, setupEnd))))
        }
        marks.sort { $0.1 < $1.1 }

        var result: [TimingPhase] = []
        for (i, mark) in marks.enumerated() {
            let next = i + 1 < marks.count ? marks[i + 1].1 : setupEnd
            let d = next.timeIntervalSince(mark.1)
            if d > 0 { result.append(TimingPhase(kind: mark.0, duration: d)) }
        }
        let lead = (marks.first?.1 ?? setupEnd).timeIntervalSince(start)
        if lead > 0 {
            if let first = result.first, first.kind == .connect {
                result[0].duration += lead
            } else {
                result.insert(TimingPhase(kind: .connect, duration: lead), at: 0)
            }
        }
        let transfer = end.timeIntervalSince(setupEnd)
        if transfer > 0 { result.append(TimingPhase(kind: .transfer, duration: transfer)) }
        return result
    }
}
