import Foundation

/// A phase of a request's lifetime for the inspector's timing bar.
struct TimingPhase: Hashable, Sendable {
    /// The phases Surge's record can time, in the order they happen. Surge reports no time to first byte, so there
    /// is no Wait phase.
    enum Kind: CaseIterable, Sendable {
        /// Surge waiting for the client's TLS Client Hello, which it reads for the SNI (it does no handshake of its own).
        case clientHello
        /// The DNS lookup rule matching waited for (rule mode, on a cache miss).
        case dns
        /// Rule evaluation and Surge's outbound connection.
        case connect
        /// The same stretch in global proxy mode when the request rode an open connection of its proxy: Surge's own
        /// work on this Mac, not a connect on the network.
        case local
        case transfer
    }

    var kind: Kind
    var duration: TimeInterval
}

/// Builds timing phases from Surge's timestamps, its per-phase timings and its per-request notes.
///
/// Notes look like `12:07:22.102428 [TLS] TLS Client Hello SNI: api2.cursor.sh`. The setup runs from the start to
/// `setupCompletedDate` and the transfer until `completedDate` (or now, for active connections). Within the setup,
/// the wait for the Client Hello runs up to its note when Surge read it before evaluating any rule, the DNS lookup
/// takes the time Surge timed (`DNS Lookup`, or its `completed in 318.4ms` note), and the rest is the connect. The
/// DNS lookup is noted when it completes, so its note only marks where it ended.
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

    /// The date of a note of a request that started at `start`: its time of day on the day the request started,
    /// or on the next day when the clock passed midnight since.
    static func date(of note: Note, near start: Date) -> Date {
        let date = Calendar.current.startOfDay(for: start).addingTimeInterval(note.secondsOfDay)
        return date < start.addingTimeInterval(-60) ? date.addingTimeInterval(86400) : date
    }

    static func phases(for record: RequestRecord, now: Date = .now) -> [TimingPhase] {
        let start = record.startedAt
        let setupEnd = max(start, record.setupCompletedAt ?? start)
        let end = record.completedAt ?? (record.state == .active ? now : setupEnd)
        let setup = setupEnd.timeIntervalSince(start)

        let hello = clientHelloDate(of: record).map { min(max(0, $0.timeIntervalSince(start)), setup) } ?? 0
        let dns = min(dnsLookupDuration(of: record) ?? 0, setup - hello)
        let durations: [TimingPhase.Kind: TimeInterval] = [
            .clientHello: hello,
            .dns: dns,
            ridesOpenConnection(record) ? .local : .connect: setup - hello - dns,
            .transfer: end.timeIntervalSince(setupEnd),
        ]
        return TimingPhase.Kind.allCases.compactMap { kind in
            guard let duration = durations[kind], duration > 0 else { return nil }
            return TimingPhase(kind: kind, duration: duration)
        }
    }

    /// When Surge read the client's TLS Client Hello, if it did before evaluating any rule (a hello read later is
    /// not part of the wait before the connect).
    static func clientHelloDate(of record: RequestRecord) -> Date? {
        for raw in record.notes {
            guard let note = parse(note: raw) else { continue }
            if note.tag.caseInsensitiveCompare("Rule") == .orderedSame { return nil }
            if note.tag.caseInsensitiveCompare("TLS") == .orderedSame, note.text.localizedCaseInsensitiveContains("Client Hello") {
                return date(of: note, near: record.startedAt)
            }
        }
        return nil
    }

    /// How long Surge's DNS lookup for rule matching took, in seconds: its `DNS Lookup` timing, else its
    /// `[DNS] DNS lookup for … completed in 318.4ms` note. Nil when Surge looked nothing up (a cached answer, global
    /// proxy mode).
    static func dnsLookupDuration(of record: RequestRecord) -> TimeInterval? {
        if let timed = record.timing?.first(where: { $0.name == "DNS Lookup" }) { return timed.duration }
        for raw in record.notes {
            guard let note = parse(note: raw), note.tag.caseInsensitiveCompare("DNS") == .orderedSame,
                  let milliseconds = lookupMilliseconds(in: note.text) else { continue }
            return milliseconds / 1000
        }
        return nil
    }

    /// `318.4` from `DNS lookup for api.example.com completed in 318.4ms. A record count: 2, …`.
    static func lookupMilliseconds(in text: String) -> Double? {
        guard let range = text.range(of: "completed in ") else { return nil }
        let number = text[range.upperBound...].prefix { $0.isNumber || $0 == "." }
        return Double(number)
    }

    /// The request was routed in global proxy mode (`[Rule] Global proxy outbound mode: AI`): Surge evaluated no
    /// rule, looked nothing up and sent it over the global policy.
    static func isGlobalProxy(_ record: RequestRecord) -> Bool {
        if record.rule?.hasPrefix("Global · ") == true { return true }
        return record.notes.contains { raw in
            guard let note = parse(note: raw) else { return false }
            return note.tag.caseInsensitiveCompare("Rule") == .orderedSame && note.text.hasPrefix("Global proxy outbound mode")
        }
    }

    /// In global proxy mode, the request rode an open connection of its proxy (`[Connection-Pool] Use an existing
    /// master connector: …`), so its setup timed only Surge's own work on this Mac. The mode alone does not say so: a
    /// DIRECT global policy connects to the destination, and a proxy may open a new connection.
    static func ridesOpenConnection(_ record: RequestRecord) -> Bool {
        guard isGlobalProxy(record), let final = record.finalPolicy?.uppercased(), final != "DIRECT", !final.hasPrefix("REJECT") else {
            return false
        }
        for raw in record.notes {
            if let note = parse(note: raw), let reused = reusesConnection(note) { return reused }
        }
        return false
    }

    /// What a note says of the outbound connection: true when Surge reused an open one (`Use an existing master
    /// connector: SGHysteriaMasterConnector-2`), false when it opened a new one, nil when the note says neither.
    static func reusesConnection(_ note: Note) -> Bool? {
        let tag = note.tag.lowercased()
        guard tag == "connection-pool" || tag == "connector" else { return nil }
        let text = note.text.lowercased()
        if text.hasPrefix("use an existing") { return true }
        if text.contains("new") || text.contains("create") { return false }
        return nil
    }
}
