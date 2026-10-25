import Foundation

/// Reads the request rows other Macs write, for the live table, in the server's write order
/// `(updated_at, id)`: page after page until a page comes back short, at most `maxPages` per poll. Every
/// position comes from the server (its clock seeds the first one), so this Mac's clock never matters.
///
/// `updated_at` is the writing transaction's start time, so a transaction that commits late adds rows just
/// behind positions already read. A poll that starts afresh therefore steps back `overlap` behind the newest
/// position read and skips the positions it already returned, by `(row ID, updated_at)`; a row written again
/// gets a later position and is returned again. A poll that stopped at `maxPages` lets the next one carry on
/// where it stopped instead of stepping back, so a burst larger than a poll can never keep the poller
/// re-reading the same rows.
struct CaptureOtherMacRows: Sendable {
    /// Rows per `requestsWritten(after:)` call.
    var pageSize = 300
    /// `requestsWritten(after:)` calls per poll at most.
    var maxPages = 10
    /// How far a fresh poll steps back behind the newest position read, for rows committed late.
    var overlap: TimeInterval = 3
    /// How far before the server's clock the first poll starts.
    var lookback: TimeInterval = 60

    /// The newest position read; nil until the server seeded it. Never moves backwards.
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
        var cursor = self.cursor
        if cursor == nil {
            let now = try await database.requestWritePosition()
            cursor = RequestWriteCursor(updatedAt: now.updatedAt.addingTimeInterval(-lookback), rowID: 0)
        }
        guard var newest = cursor else { return Poll(rows: [], capped: false) }
        var position = resumeAfter ?? RequestWriteCursor(updatedAt: newest.updatedAt.addingTimeInterval(-overlap), rowID: 0)
        var seen = self.seen
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
        // Positions a fresh poll can no longer reach are dropped (the cursor only moves forward).
        let floor = newest.updatedAt.addingTimeInterval(-overlap)
        seen = seen.filter { $0.updatedAt >= floor }

        self.cursor = newest
        resumeAfter = capped ? position : nil
        self.seen = seen
        return Poll(rows: Self.newestVersions(fresh), capped: capped)
    }

    /// One record per request, the last one read, in the order those were read.
    static func newestVersions(_ rows: [RequestRecord]) -> [RequestRecord] {
        var keys: Set<RequestKey> = []
        return rows.reversed().filter { keys.insert($0.key).inserted }.reversed()
    }
}
