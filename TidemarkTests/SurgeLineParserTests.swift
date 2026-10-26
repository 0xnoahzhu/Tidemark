import Foundation
import Testing
@testable import Tidemark

@Suite("Surge watch lines")
struct SurgeLineParserTests {
    @Test func classifiesCapturedWatchOutput() throws {
        let events = try SurgeFixtures.lines("surge-watch.jsonl").map(SurgeLineParser.event(from:))
        try #require(events.count == 4)

        guard case .subscribed = events[0] else { Issue.record("expected .subscribed, got \(events[0])"); return }

        guard case .speed(let speed) = events[1] else { Issue.record("expected .speed, got \(events[1])"); return }
        #expect(speed.in == 11192)
        #expect(speed.out == 2612)
        #expect(speed.downloadSpeedHistory?.count == 20)

        // The first `request` event of a connection: no policy, notes or remote address yet.
        guard case .request(let created) = events[2] else { Issue.record("expected .request, got \(events[2])"); return }
        #expect(created.id == 58452)
        #expect(created.remoteHost == "api3.cursor.sh:443")
        #expect(created.policyName == nil)
        #expect(created.notes == nil)
        #expect(created.pid == 19938)
        #expect(created.processPath?.hasSuffix("Cursor Helper (Plugin)") == true)
        #expect(created.setupCompletedDate == nil, "0 means not yet and is normalized to nil")
        #expect(created.completedDate == nil)

        // The `request-update` for the same connection.
        guard case .request(let updated) = events[3] else { Issue.record("expected .request, got \(events[3])"); return }
        #expect(updated.id == created.id)
        #expect(updated.policyName == "AT&T-RackNerd-Hysteria2")
        #expect(updated.remoteAddress == "203.0.113.10 (Proxy)")
        #expect(updated.pathForStatistics == "/Applications/Cursor.app/")
        #expect(updated.notes?.count == 6)
        #expect(updated.status == "Active")
        #expect(updated.startDate == 1792871241.320689)
    }

    @Test func classifiesDNSEvents() throws {
        // Recorded with `surge-cli --raw watch dns` (Surge Mac 6.10).
        let events = try SurgeFixtures.lines("surge-watch-dns.jsonl").map(SurgeLineParser.event(from:))
        try #require(events.count == 3)
        guard case .subscribed = events[0] else { Issue.record("expected .subscribed, got \(events[0])"); return }
        guard case .dns(let proxycheck) = events[1], case .dns(let qualcomm) = events[2] else {
            Issue.record("expected .dns, got \(events[1]), \(events[2])")
            return
        }
        #expect(proxycheck.domain == "proxycheck.io")
        #expect(proxycheck.server == "https://cloudflare-dns.com/dns-query")
        #expect(proxycheck.interface == "")
        #expect(proxycheck.addresses == ["104.26.8.187", "104.26.9.187", "172.67.75.219"])
        #expect(qualcomm.domain == "www.qualcomm.cn" && qualcomm.addresses == ["172.64.144.37", "104.18.43.219"])

        // Only addresses count; a request record that names a domain stays a request.
        guard case .dns(let mixed) = SurgeLineParser.event(from: #"{"domain":"a.test","server":"system","data":["10.0.0.1","alias.test"]}"#) else {
            Issue.record("expected .dns")
            return
        }
        #expect(mixed.addresses == ["10.0.0.1"])
        guard case .request = SurgeLineParser.event(from: #"{"id":1,"remoteHost":"a.test:443","domain":"a.test","server":"x","data":[]}"#) else {
            Issue.record("expected .request")
            return
        }
    }

    @Test(arguments: [
        #"{"ProxyGroupSelection":{"AI":"AT&T-RackNerd-SNELL"}}"#,
        #"{"ProxyMode":2}"#,
        #"{"environment":{"ProxyMode":"1"}}"#,
        #"{"event":"environment","data":{}}"#,
    ])
    func classifiesEnvironmentChanges(_ line: String) {
        guard case .environmentChanged = SurgeLineParser.event(from: line) else {
            Issue.record("expected .environmentChanged for \(line)")
            return
        }
    }

    @Test func classifiesReloadAndShutdown() {
        guard case .reload = SurgeLineParser.event(from: #"{"event":"reload"}"#) else { Issue.record("reload"); return }
        guard case .reload = SurgeLineParser.event(from: #"{"reloaded":true}"#) else { Issue.record("reloaded"); return }
        guard case .shutdown = SurgeLineParser.event(from: #"{"shutdown":true}"#) else { Issue.record("shutdown"); return }
        guard case .shutdown = SurgeLineParser.event(from: #"{"event-name":"shutdown"}"#) else { Issue.record("event-name"); return }
    }

    @Test(arguments: [
        "Error: The controller connection has been closed",
        #"{"something":"else"}"#,
        "[1, 2, 3]",
        #"{"id":"not-a-number","remoteHost":"x:443"}"#,
        #"{"in":"fast","out":1,"downloadSpeedHistory":[]}"#,
    ])
    func keepsUnknownLinesForDiagnostics(_ line: String) {
        guard case .other(let text) = SurgeLineParser.event(from: line) else {
            Issue.record("expected .other for \(line)")
            return
        }
        #expect(text == line)
    }

    @Test func splitsLinesOnlyAtNewlines() {
        var splitter = SurgeLineSplitter()
        // U+2028 is legal unescaped inside JSON strings and must not end a line.
        let first = splitter.append(Data("{\"notes\":[\"a\u{2028}b\"]}\n{\"id\":".utf8))
        #expect(first.map { String(decoding: $0, as: UTF8.self) } == ["{\"notes\":[\"a\u{2028}b\"]}"])
        let second = splitter.append(Data("1}\r\n\n{\"partial\"".utf8))
        #expect(second.map { String(decoding: $0, as: UTF8.self) } == ["{\"id\":1}"])
        #expect(splitter.finish().map { String(decoding: $0, as: UTF8.self) } == "{\"partial\"")
        #expect(splitter.finish() == nil)
    }

    @Test func splitsLinesAcrossManyChunks() {
        let lines = (0..<50).map { #"{"id":\#($0),"URL":"h\#($0):443","notes":["\#(String(repeating: "x", count: $0 * 37))"]}"# }
        let bytes = Data(lines.joined(separator: "\n").utf8)
        var splitter = SurgeLineSplitter()
        var output: [Data] = []
        var index = bytes.startIndex
        while index < bytes.endIndex {
            let end = bytes.index(index, offsetBy: 7, limitedBy: bytes.endIndex) ?? bytes.endIndex
            output += splitter.append(bytes[index..<end])
            index = end
        }
        if let last = splitter.finish() { output.append(last) }
        #expect(output.map { String(decoding: $0, as: UTF8.self) } == lines)
    }
}
