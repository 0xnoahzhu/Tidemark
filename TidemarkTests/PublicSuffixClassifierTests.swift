import Foundation
import Testing
@testable import Tidemark

@Suite("Public Suffix List")
struct PublicSuffixClassifierTests {
    let classifier = PublicSuffixClassifier()

    @Test(arguments: [
        // Platforms from the list's private section stay one site (only ICANN rules are bundled).
        ("objects.githubusercontent.com", "githubusercontent.com"),
        ("raw.githubusercontent.com", "githubusercontent.com"),
        ("docker-images-prod.r2.cloudflarestorage.com", "cloudflarestorage.com"),
        // Multi-label public suffixes.
        ("a.b.example.co.uk", "example.co.uk"),
        ("gateway.icloud.com.cn", "icloud.com.cn"),
        ("www.bilibili.com", "bilibili.com"),
        ("api2.cursor.sh", "cursor.sh"),
        ("k12.ak.us", "k12.ak.us"),
        ("school.k12.ak.us", "school.k12.ak.us"),
        ("www.school.k12.ak.us", "school.k12.ak.us"),
        // Wildcard `*.kawasaki.jp` and its exception `!city.kawasaki.jp`.
        ("www.shop.foo.kawasaki.jp", "shop.foo.kawasaki.jp"),
        ("www.city.kawasaki.jp", "city.kawasaki.jp"),
        // Wildcard `*.ck` and exception `!www.ck`.
        ("a.b.c.ck", "b.c.ck"),
        ("www.ck", "www.ck"),
        // Unknown TLDs fall back to the default rule `*`.
        ("intranet.corp.internal-tld", "corp.internal-tld"),
        // Normalization.
        ("WWW.Example.COM.", "example.com"),
        // Internationalized rules match their punycode form (`公司.cn` → `xn--55qx5d.cn`).
        ("shop.example.xn--55qx5d.cn", "example.xn--55qx5d.cn"),
        ("shop.example.公司.cn", "example.公司.cn"),
        ("www.example.xn--fiqs8s", "example.xn--fiqs8s"),
    ])
    func findsTheRegistrableDomain(_ host: String, _ site: String) {
        #expect(classifier.site(for: host) == site)
    }

    @Test(arguments: ["183.3.226.35", "2001:db8::1", "[2001:db8::1]", "localhost", "co.uk", "com.cn"])
    func returnsIPLiteralsSingleLabelsAndPublicSuffixesUnchanged(_ host: String) {
        #expect(classifier.site(for: host) == host)
    }

    @Test func bundlesOnlyTheICANNSection() throws {
        let rules = PublicSuffixRules.bundled
        #expect(rules.count > 6_000)
        let url = try #require(Bundle.main.url(forResource: "public_suffix_list", withExtension: "dat"))
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.hasPrefix("// This Source Code Form is subject to the terms of the Mozilla Public"))
        #expect(text.contains("===BEGIN ICANN DOMAINS==="))
        #expect(!text.contains("===BEGIN PRIVATE DOMAINS==="))
    }

    @Test func parsesTheListFormat() {
        let rules = PublicSuffixRules(listText: """
        // comment
        com
        *.test-wildcard.com
        !keep.test-wildcard.com

        example.org trailing text is ignored
        """)
        let classifier = PublicSuffixClassifier(rules: rules)
        #expect(classifier.site(for: "a.b.c.test-wildcard.com") == "b.c.test-wildcard.com")
        #expect(classifier.site(for: "a.keep.test-wildcard.com") == "keep.test-wildcard.com")
        #expect(classifier.site(for: "a.b.example.org") == "b.example.org")
        #expect(classifier.site(for: "a.b.com") == "b.com")
    }

    @Test(arguments: [
        ("公司", "55qx5d"),
        ("中国", "fiqs8s"),
        ("香港", "j6w193g"),
        ("bücher", "bcher-kva"),
        ("münchen", "mnchen-3ya"),
        ("ελ", "qxam"),
    ])
    func encodesPunycode(_ label: String, _ encoded: String) {
        #expect(PublicSuffixPunycode.encode(label) == encoded)
    }

    @Test func encodesInternationalizedDomains() {
        #expect(PublicSuffixPunycode.encodeDomain("公司.cn") == "xn--55qx5d.cn")
        #expect(PublicSuffixPunycode.encodeDomain("example.com") == "example.com")
    }
}
