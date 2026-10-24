import Foundation
import Testing
@testable import Tidemark

struct FoundationTests {
    @Test func splitsHostAndPort() {
        #expect(HostName.splitHostPort("api2.cursor.sh:443") == ("api2.cursor.sh", 443))
        #expect(HostName.splitHostPort("[2001:db8::1]:8443") == ("2001:db8::1", 8443))
        #expect(HostName.splitHostPort("149.154.175.60:443") == ("149.154.175.60", 443))
    }

    @Test func detectsIPLiterals() {
        #expect(HostName.isIPAddress("183.3.226.35"))
        #expect(HostName.isIPAddress("2001:db8::1"))
        #expect(!HostName.isIPAddress("api.github.com"))
        #expect(!HostName.isIPAddress("999.1.1.1"))
    }

    @Test func matchesMutePatterns() {
        let patterns = ["*.apple.com", "api.notion.com"]
        #expect(AlertState.matches("gateway.icloud.apple.com", patterns: patterns))
        #expect(AlertState.matches("apple.com", patterns: patterns))
        #expect(AlertState.matches("API.notion.com", patterns: patterns))
        #expect(!AlertState.matches("notapple.com", patterns: patterns))
    }

    @Test func formatsGeo() {
        let geo = GeoInfo(countryCode: "us", asn: 13335, organization: "Cloudflare, Inc.")
        #expect(geo.display == "US · AS13335 Cloudflare")
        #expect(GeoInfo.shortOrganization("Amazon.com, Inc.") == "Amazon")
    }

    @Test func parsesSurgeNotes() throws {
        let note = try #require(RequestTiming.parse(note: "12:07:22.102428 [TLS] TLS Client Hello SNI: api2.cursor.sh"))
        #expect(note.tag == "TLS")
        #expect(note.text == "TLS Client Hello SNI: api2.cursor.sh")
        #expect(abs(note.secondsOfDay - (12 * 3600 + 7 * 60 + 22.102428)) < 0.0001)
    }

    @Test func formatsBytes() {
        #expect(Fmt.bytes(512) == "512 B")
        #expect(Fmt.bytes(15_770) == "15.4 KB")
        #expect(Fmt.bytes(1_258_291) == "1.2 MB")
    }
}
