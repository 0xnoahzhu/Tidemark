import Foundation

/// Reads the request rows other Macs write, for the live table, in the server's write order
/// `(updated_at, id)`: page after page until a page comes back short, at most `maxPages` per poll. Every
/// position comes from the server (each poll starts by reading its clock), so this Mac's clock never matters.
///
/// `updated_at` is the writing transaction's start time, so a transaction that commits late adds rows just
/// behind positions already read. A poll that starts afresh therefore steps back `overlap` behind the newest
/// position read and skips the positions it already returned, by `(row ID, updated_at)`; a row written again
/// gets a later position and is returned again. A poll that stopped at `maxPages` lets the next one carry on
/// where it stopped instead of stepping back, so a burst larger than a poll can never keep the poller
/// re-reading the same rows.
///
/// The position never stays more than `lookback` behind the server's clock: after a sleep, an outage or a
/// burst too large to keep up with, the next poll skips ahead (the live table only shows recent rows), so no
/// page reads more than about `lookback` of writes. A poll that read everything moves the position up to the
/// server's clock at its start, so while the other Macs write nothing a poll reads only the last `overlap` of
/// this Mac's own rows instead of every one written since the last row of another Mac.
struct CaptureOtherMacRows: Sendable {
    /// Rows per `requestsWritten(after:)` call.
    var pageSize = 300
    /// `requestsWritten(after:)` calls per poll at most.
    var maxPages = 10
    /// How far a fresh poll steps back behind the newest position read, for rows committed late.
    var overlap: TimeInterval = 3
    /// How far behind the server's clock a poll starts at most (the first one starts there).
    var lookback: TimeInterval = 60

    /// The newest position read, or the server's clock at the start of the last poll that read everything;
    /// nil until the server seeded it. Never moves backwards, except when `reset()`.
    private(set) var cursor: RequestWriteCursor?
    /// Where the last poll stopped when it reached `maxPages`.
    private(set) var resumeAfter: RequestWriteCursor?
    /// Positions already returned that a later poll may read again (within `overlap` of `cursor`).
    private var seen: Set<RequestWriteCursor> = []

    /// What one poll read.
    struct Poll: Sendable {
        /// Rows not returned before, one per request (its newest version), in write order.
        var rows: [RequestRecord]
        /// The poll stopped at `maxPages`; the next one carries on from there.
        var capped: Bool
        /// The span this poll skipped because the position had fallen more than `lookback` behind the server's
        /// clock (0 when it did not): rows other Macs wrote in it were not read.
        var skipped: TimeInterval = 0
    }

    /// Forgets the position: the next poll starts again from the server's clock.
    mutating func reset() {
        cursor = nil
        resumeAfter = nil
        seen.removeAll()
    }

    /// Reads what other devices than `excluding` wrote since the last poll. A failure changes nothing, so the
    /// next poll reads the same rows again.
    mutating func poll(_ database: any TidemarkDatabase, excluding: DeviceID?) async throws -> Poll {
        // Rows of transactions that start from now on come after this position.
        let serverNow = try await database.requestWritePosition()
        let earliest = RequestWriteCursor(updatedAt: serverNow.updatedAt.addingTimeInterval(-lookback), rowID: 0)
        var newest = cursor ?? earliest
        var resumeAfter = self.resumeAfter
        var seen = self.seen
        var skipped: TimeInterval = 0
        if newest < earliest {
            skipped = earliest.updatedAt.timeIntervalSince(newest.updatedAt)
            newest = earliest
            resumeAfter = nil
            seen.removeAll()
        }
        var position = resumeAfter ?? RequestWriteCursor(updatedAt: newest.updatedAt.addingTimeInterval(-overlap), rowID: 0)
        var fresh: [RequestRecord] = []
        var capped = true
        let limit = max(1, pageSize)
        for _ in 0..<max(1, maxPages) {
            let page = try await database.requestsWritten(after: position, excluding: excluding, limit: limit)
            for row in page {
                guard let at = RequestWriteCursor(row), at > position else { continue }
                position = at
                newest = max(newest, at)
                if seen.insert(at).inserted { fresh.append(row) }
            }
            if page.count < limit {
                capped = false
                break
            }
        }
        // A poll that read to a short page read every row committed before it began, from its position on: the
        // next one starts from the server's clock even when no other Mac wrote anything, and still steps back
        // `overlap` from there for transactions that commit late.
        if !capped { newest = max(newest, serverNow) }
        // Positions a fresh poll can no longer reach are dropped (the cursor only moves forward).
        let floor = newest.updatedAt.addingTimeInterval(-overlap)
        seen = seen.filter { $0.updatedAt >= floor }

        self.cursor = newest
        self.resumeAfter = capped ? position : nil
        self.seen = seen
        return Poll(rows: Self.newestVersions(fresh), capped: capped, skipped: skipped)
    }

    /// One record per request, the last one read, in the order those were read.
    static func newestVersions(_ rows: [RequestRecord]) -> [RequestRecord] {
        var keys: Set<RequestKey> = []
        return rows.reversed().filter { keys.insert($0.key).inserted }.reversed()
    }
}
