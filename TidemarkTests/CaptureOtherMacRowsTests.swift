import Foundation
import Testing
@testable import Tidemark

/// Paging through the rows other Macs write (`CaptureOtherMacRows`) against an in-memory server.
@Suite(.timeLimit(.minutes(1)))
struct CaptureOtherMacRowsTests {
    let me = UUID()
    let mini = UUID()
    /// The server's clock.
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// A row written at `now + offset` with row ID `rowID`, by `mini` unless `device` says otherwise.
    func row(_ surgeID: Int64, rowID: Int64, at offset: TimeInterval, device: DeviceID? = nil, state: RequestState = .active) -> RequestRecord {
        RequestRecord(
            key: RequestKey(deviceID: device ?? mini, session: 1_000, surgeID: surgeID), rowID: rowID, startedAt: now.addingTimeInterval(-120),
            setupCompletedAt: nil, completedAt: nil, method: "HTTPS", host: "h\(surgeID).example", port: 443, url: nil, remoteIP: nil,
            remoteAddress: nil, geo: nil, policyPath: ["DIRECT"], rule: nil, state: state, inBytes: 0, outBytes: 0, pid: nil,
            processPath: nil, bundlePath: nil, chain: [], appID: nil, localAddress: nil, interface: nil, notes: [], isNew: false,
            writtenAt: now.addingTimeInterval(offset), probeSessionID: nil
        )
    }

    func poller(pageSize: Int, maxPages: Int) -> CaptureOtherMacRows {
        var poller = CaptureOtherMacRows()
        poller.pageSize = pageSize
        poller.maxPages = maxPages
        return poller
    }

    @Test func aBurstIsReadPageByPageInWriteOrder() async throws {
        let database = CaptureFakeDatabase()
        // Written in any order; positions are (updated_at, id). Rows 1…25 share three timestamps.
        for id in Array(1...25).shuffled() {
            await database.write(row(Int64(id), rowID: Int64(id), at: -10 + Double((id - 1) / 10)))
        }
        await database.write(row(100, rowID: 100, at: -5, device: me))
        var rows = poller(pageSize: 10, maxPages: 5)

        let first = try await rows.poll(database, excluding: me)
        #expect(!first.capped)
        #expect(first.rows.map(\.key.surgeID) == Array(1...25).map(Int64.init), "every row once, in write order, none of this Mac's")
        #expect(await database.writtenPages == 3, "until a page came back short")
        #expect(rows.cursor == RequestWriteCursor(updatedAt: now, rowID: 0), "read everything: up to the server's clock")

        let second = try await rows.poll(database, excluding: me)
        #expect(second.rows.isEmpty && !second.capped)
    }

    @Test func theFirstPollStartsFromTheServersClock() async throws {
        let database = CaptureFakeDatabase()
        await database.write(row(1, rowID: 1, at: -600))
        await database.write(row(2, rowID: 2, at: -30))
        var rows = poller(pageSize: 10, maxPages: 5)
        // Rows from the last minute by the server's clock, whatever this Mac's clock says.
        #expect(try await rows.poll(database, excluding: me).rows.map(\.key.surgeID) == [2])

        // Dropping the position starts again from the server's clock at the next poll.
        rows.reset()
        #expect(rows.cursor == nil)
        await database.setServerNow(now.addingTimeInterval(600))
        await database.write(row(3, rowID: 3, at: 590))
        #expect(try await rows.poll(database, excluding: me).rows.map(\.key.surgeID) == [3])
    }

    @Test func aCappedPollLetsTheNextOneCarryOn() async throws {
        let database = CaptureFakeDatabase()
        for id in 1...25 { await database.write(row(Int64(id), rowID: Int64(id), at: -10 + Double(id) / 100)) }
        var rows = poller(pageSize: 10, maxPages: 2)

        let first = try await rows.poll(database, excluding: me)
        #expect(first.capped)
        #expect(first.rows.map(\.key.surgeID) == Array(1...20).map(Int64.init))
        let pages = await database.writtenPages
        let second = try await rows.poll(database, excluding: me)
        #expect(!second.capped)
        #expect(second.rows.map(\.key.surgeID) == Array(21...25).map(Int64.init))
        #expect(await database.writtenPages == pages + 1, "carried on from where the first poll stopped, without stepping back")
        #expect(try await rows.poll(database, excluding: me).rows.isEmpty)
    }

    @Test func rowsCommittedLateOrWrittenAgainAreReadOnce() async throws {
        let database = CaptureFakeDatabase()
        for id in 1...5 { await database.write(row(Int64(id), rowID: Int64(id), at: -3 + Double(id) / 2)) }
        var rows = poller(pageSize: 10, maxPages: 5)
        #expect(try await rows.poll(database, excluding: me).rows.count == 5)
        let cursor = try #require(rows.cursor)

        // A transaction that started before the newest row read commits a second later; another one writes
        // row 2 again.
        await database.setServerNow(now.addingTimeInterval(1))
        await database.write(row(6, rowID: 6, at: -1.25))
        await database.write(row(2, rowID: 2, at: 0.5, state: .completed))
        let next = try await rows.poll(database, excluding: me)
        #expect(next.rows.map(\.key.surgeID) == [6, 2])
        #expect(next.rows.last?.state == .completed)
        #expect(rows.cursor.map { $0 > cursor } == true)
        #expect(try await rows.poll(database, excluding: me).rows.isEmpty, "rows read within the overlap are not returned again")
    }

    @Test func moreRowsThanOnePollInsideTheOverlapNeverStallThePoller() async throws {
        let database = CaptureFakeDatabase()
        // 50 rows written by one transaction (one timestamp), 20 per poll.
        for id in 1...50 { await database.write(row(Int64(id), rowID: Int64(id), at: -1)) }
        var rows = poller(pageSize: 10, maxPages: 2)
        var read: [Int64] = []
        for _ in 0..<3 { read += try await rows.poll(database, excluding: me).rows.map(\.key.surgeID) }
        #expect(read == Array(1...50).map(Int64.init))

        // The next polls step back over those 50 rows again, yet each one gets further than the one before.
        await database.write(row(51, rowID: 51, at: 0))
        var later: [Int64] = []
        for _ in 0..<3 { later += try await rows.poll(database, excluding: me).rows.map(\.key.surgeID) }
        #expect(later == [51])
    }

    @Test func whileOtherMacsWriteNothingAPollStepsBackOnlyFromTheServersClock() async throws {
        let database = CaptureFakeDatabase()
        await database.write(row(1, rowID: 1, at: -30))
        var rows = poller(pageSize: 10, maxPages: 5)
        #expect(try await rows.poll(database, excluding: me).rows.count == 1)

        // Only this Mac writes (rows the poll leaves out): each poll starts just behind the previous one's
        // clock, not behind the last row another Mac wrote.
        for step in 1...3 {
            let at = Double(step * 20)
            await database.write(row(Int64(100 + step), rowID: Int64(100 + step), at: at, device: me))
            await database.setServerNow(now.addingTimeInterval(at))
            let poll = try await rows.poll(database, excluding: me)
            #expect(poll.rows.isEmpty && poll.skipped == 0)
            #expect(await database.writtenCursors.last == RequestWriteCursor(updatedAt: now.addingTimeInterval(at - 23), rowID: 0))
            #expect(rows.cursor == RequestWriteCursor(updatedAt: now.addingTimeInterval(at), rowID: 0))
        }
    }

    @Test func aPollThatFellFarBehindSkipsToTheLastMinute() async throws {
        let database = CaptureFakeDatabase()
        await database.write(row(1, rowID: 1, at: -1))
        var rows = poller(pageSize: 10, maxPages: 2)
        #expect(try await rows.poll(database, excluding: me).rows.map(\.key.surgeID) == [1])

        // This Mac slept for ten hours while the other Mac kept writing.
        let gap: TimeInterval = 36_000
        for id in 2...101 { await database.write(row(Int64(id), rowID: Int64(id), at: Double(id - 1) * gap / 100)) }
        await database.setServerNow(now.addingTimeInterval(gap))
        let poll = try await rows.poll(database, excluding: me)
        #expect(poll.rows.map(\.key.surgeID) == [101], "only rows the live table can still show")
        #expect(poll.skipped == gap - 60)
        #expect(await database.writtenCursors.last == RequestWriteCursor(updatedAt: now.addingTimeInterval(gap - 63), rowID: 0))
        #expect(!poll.capped)
        #expect(try await rows.poll(database, excluding: me).skipped == 0)
    }

    @Test func aBurstTooLargeToKeepUpWithIsSkippedOnceItFallsBehind() async throws {
        let database = CaptureFakeDatabase()
        for id in 1...30 { await database.write(row(Int64(id), rowID: Int64(id), at: -1)) }
        var rows = poller(pageSize: 10, maxPages: 1)
        let first = try await rows.poll(database, excluding: me)
        #expect(first.capped && rows.resumeAfter != nil)

        // Two minutes later the rest of the burst is too old to matter: the poll starts from the last minute.
        await database.setServerNow(now.addingTimeInterval(120))
        await database.write(row(31, rowID: 31, at: 119))
        let next = try await rows.poll(database, excluding: me)
        #expect(next.rows.map(\.key.surgeID) == [31])
        #expect(next.skipped == 61 && !next.capped)
        #expect(rows.resumeAfter == nil)
    }

    @Test func aFailedPollChangesNothing() async throws {
        let database = CaptureFakeDatabase()
        var rows = poller(pageSize: 10, maxPages: 5)
        await database.setFailing(true)
        await #expect(throws: DatabaseError.self) { try await rows.poll(database, excluding: me) }
        #expect(rows.cursor == nil, "not seeded")

        await database.setFailing(false)
        for id in 1...3 { await database.write(row(Int64(id), rowID: Int64(id), at: -3 + Double(id) / 10)) }
        #expect(try await rows.poll(database, excluding: me).rows.count == 3)
        let cursor = rows.cursor
        await database.write(row(4, rowID: 4, at: 0))
        await database.setFailing(true)
        await #expect(throws: DatabaseError.self) { try await rows.poll(database, excluding: me) }
        #expect(rows.cursor == cursor)
        await database.setFailing(false)
        #expect(try await rows.poll(database, excluding: me).rows.map(\.key.surgeID) == [4])
    }

    @Test func oneRecordPerRequestItsNewestVersion() {
        let early = row(1, rowID: 1, at: -3)
        let other = row(2, rowID: 2, at: -2)
        let late = row(1, rowID: 1, at: -1, state: .completed)
        #expect(CaptureOtherMacRows.newestVersions([early, other, late]) == [other, late])
    }
}
