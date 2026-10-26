import Foundation

/// The resolutions Surge's DNS makes (`dns` watch events), stored in `dns_answers` so a request can later show which
/// DNS answered for its host. An event carries the domain, the server, the interface and the addresses; the next
/// `dump dns` read (every 30 s, `refreshDNSCache`) adds the CNAME path, the lookup's log line, its time and the
/// answer's expiry. Surge keeps only its current cache, so nothing is learned per request and nothing is run for one.
extension CapturePipeline {
    /// One `dns` event. Answers Tidemark's own `dns lookup` caused (one in flight for the domain, or one that ended
    /// moments ago) are marked. Dropped while recording is paused.
    func recordDNSAnswer(_ event: SurgeDNSEvent, now: Date) {
        guard recording else { return }
        let domain = SurgeOutputParser.dnsDomain(event.domain)
        guard !domain.isEmpty else { return }
        let ownLookup = dnsInFlight.contains(domain) || finishedLookups[domain].map { now.timeIntervalSince($0) < ownLookupWindow } == true
        let server = event.server?.trimmingCharacters(in: .whitespaces)
        let interface = event.interface?.trimmingCharacters(in: .whitespaces)
        let answer = DNSAnswer(deviceID: settings.deviceID, domain: domain, resolvedAt: now, server: server?.isEmpty == false ? server : nil,
                               interface: interface?.isEmpty == false ? interface : nil, addresses: event.addresses, byTidemark: ownLookup)
        latestDNSAnswers[domain] = (Set(answer.addresses), now, ownLookup)
        // A flood of events with no read completing them: the oldest are written as they are.
        if pendingDNSAnswers.count >= 5_000 { buffer.add(dnsAnswer: pendingDNSAnswers.removeFirst()) }
        pendingDNSAnswers.append(answer)
    }

    /// Completes the waiting answers from a `dump dns` read: an entry of the same domain with the same addresses (not a
    /// static mapping) is the answer, and gives its CNAME path, log, time and expiry. Completed answers are queued for
    /// writing; one the read lacks (Surge resolved the domain again meanwhile) waits for the next read, at most
    /// `dnsAnswerWait`.
    func completeDNSAnswers(_ records: [SurgeDNSRecord], now: Date) {
        guard !pendingDNSAnswers.isEmpty else { return }
        var cached: [String: [SurgeDNSRecord]] = [:]
        for record in records where !record.isLocal { cached[record.domain, default: []].append(record) }
        var waiting: [DNSAnswer] = []
        for var answer in pendingDNSAnswers {
            let addresses = Set(answer.addresses)
            if let entry = cached[answer.domain]?.first(where: { Set($0.addresses) == addresses }) {
                answer.server = answer.server ?? entry.server
                answer.interface = answer.interface ?? entry.interface
                answer.path = entry.path
                answer.log = entry.logs.isEmpty ? nil : entry.logs.joined(separator: "\n")
                answer.timeCostMs = entry.timeCost.map { $0 * 1_000 }
                answer.expiresAt = entry.expires
                buffer.add(dnsAnswer: answer)
            } else if answer.resolvedAt <= now.addingTimeInterval(-dnsAnswerWait) {
                buffer.add(dnsAnswer: answer)
            } else {
                waiting.append(answer)
            }
        }
        pendingDNSAnswers = waiting
    }

    /// Queues the waiting answers that arrived before `date` as their events had them (no read completed them, or
    /// Tidemark is quitting).
    func queueDNSAnswers(olderThan date: Date) {
        guard let first = pendingDNSAnswers.first, first.resolvedAt < date else { return }
        let due = pendingDNSAnswers.prefix { $0.resolvedAt < date }
        for answer in due { buffer.add(dnsAnswer: answer) }
        pendingDNSAnswers.removeFirst(due.count)
    }
}
