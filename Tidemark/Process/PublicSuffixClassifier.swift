import Foundation
import OSLog

/// `SiteClassifying` backed by the Public Suffix List bundled as `Resources/PublicSuffix/public_suffix_list.dat`.
///
/// Only the list's ICANN section is bundled, on purpose: the private section names hosting platforms such
/// as `githubusercontent.com` and `r2.cloudflarestorage.com`, which would make every customer subdomain its
/// own site, while Tidemark wants `objects.githubusercontent.com` to belong to `githubusercontent.com`.
struct PublicSuffixClassifier: SiteClassifying {
    private let custom: PublicSuffixRules?

    /// Uses the bundled list, parsed once per process on the first classification (not here, so creating
    /// the classifier on the main actor costs nothing).
    init() {
        custom = nil
    }

    init(rules: PublicSuffixRules) {
        custom = rules
    }

    var rules: PublicSuffixRules { custom ?? .bundled }

    /// The registrable domain (public suffix plus one label), lowercased and without a trailing dot.
    /// IP literals are returned unchanged; single labels and public suffixes themselves are returned as is.
    func site(for host: String) -> String {
        if HostName.isIPAddress(host) { return host }
        var name = host.lowercased()
        while name.hasSuffix(".") { name.removeLast() }
        let labels = name.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count > 1, !labels.contains(where: \.isEmpty) else { return name }
        return rules.registrableDomain(labels: labels) ?? name
    }
}

/// Parsed Public Suffix List rules (https://publicsuffix.org/list/).
///
/// Normal rules are matched label by label from the right, `*.` rules match any one label, `!` exception
/// rules override wildcards, and the implicit default rule `*` makes every TLD a public suffix.
/// Internationalized rules are stored in both their Unicode and their punycode (`xn--`) form, since Surge
/// reports hosts in ASCII.
struct PublicSuffixRules: Sendable {
    private(set) var normal: Set<String> = []
    /// `*.ck` is stored as `ck`.
    private(set) var wildcards: Set<String> = []
    /// `!www.ck` is stored as `www.ck`.
    private(set) var exceptions: Set<String> = []

    var count: Int { normal.count + wildcards.count + exceptions.count }

    /// Parses the list format: one rule per line, `//` comments, everything after the first space ignored.
    init(listText: String) {
        for rawLine in listText.split(whereSeparator: \.isNewline) {
            guard let token = rawLine.split(whereSeparator: \.isWhitespace).first, !token.hasPrefix("//") else { continue }
            var rule = token.lowercased()
            while rule.hasSuffix(".") { rule.removeLast() }
            if rule.hasPrefix("!") {
                insert(String(rule.dropFirst()), into: \.exceptions)
            } else if rule.hasPrefix("*.") {
                insert(String(rule.dropFirst(2)), into: \.wildcards)
            } else if !rule.isEmpty {
                insert(rule, into: \.normal)
            }
        }
    }

    /// The bundled ICANN rules, loaded on first use (static initialization is lazy and thread-safe).
    static let bundled: PublicSuffixRules = {
        let logger = Logger(subsystem: "io.tidemark.Tidemark", category: "PublicSuffix")
        guard let url = Bundle.main.url(forResource: "public_suffix_list", withExtension: "dat"),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else {
            logger.fault("public_suffix_list.dat is missing from the app bundle; every TLD is treated as the only public suffix.")
            return PublicSuffixRules(listText: "")
        }
        return PublicSuffixRules(listText: text)
    }()

    /// Registrable domain of a lowercased host split into non-empty labels, or nil when the host is itself
    /// a public suffix.
    func registrableDomain(labels: [Substring]) -> String? {
        let count = labels.count
        guard count > 0 else { return nil }
        // suffixes[i] = labels[i...] joined by dots.
        var suffixes = [String](repeating: "", count: count)
        suffixes[count - 1] = String(labels[count - 1])
        for index in stride(from: count - 2, through: 0, by: -1) {
            suffixes[index] = String(labels[index]) + "." + suffixes[index + 1]
        }

        let publicSuffixStart: Int
        if let exception = suffixes.firstIndex(where: { exceptions.contains($0) }) {
            // An exception rule wins; its public suffix drops the rule's leftmost label.
            publicSuffixStart = exception + 1
        } else if let match = suffixes.indices.first(where: { index in
            normal.contains(suffixes[index]) || (index + 1 < count && wildcards.contains(suffixes[index + 1]))
        }) {
            // The first match from the left is the rule with the most labels.
            publicSuffixStart = match
        } else {
            publicSuffixStart = count - 1
        }
        guard publicSuffixStart > 0 else { return nil }
        return suffixes[publicSuffixStart - 1]
    }

    private mutating func insert(_ rule: String, into set: WritableKeyPath<PublicSuffixRules, Set<String>>) {
        self[keyPath: set].insert(rule)
        if !rule.allSatisfy(\.isASCII), let ascii = PublicSuffixPunycode.encodeDomain(rule) {
            self[keyPath: set].insert(ascii)
        }
    }
}

/// Punycode (RFC 3492) encoding of internationalized domain labels, as used by IDNA's `xn--` labels.
enum PublicSuffixPunycode {
    private static let base = 36
    private static let tMin = 1
    private static let tMax = 26
    private static let skew = 38
    private static let damp = 700
    private static let initialBias = 72
    private static let initialN = 128

    /// `公司.cn` → `xn--55qx5d.cn`. ASCII labels are kept; nil if a label cannot be encoded.
    static func encodeDomain(_ domain: String) -> String? {
        var labels: [String] = []
        for label in domain.split(separator: ".", omittingEmptySubsequences: false) {
            if label.allSatisfy(\.isASCII) {
                labels.append(String(label))
            } else if let encoded = encode(String(label)) {
                labels.append("xn--" + encoded)
            } else {
                return nil
            }
        }
        return labels.joined(separator: ".")
    }

    /// The punycode form of one label, without the `xn--` prefix (`bücher` → `bcher-kva`).
    static func encode(_ label: String) -> String? {
        let input = label.unicodeScalars.map { Int($0.value) }
        var output = input.filter { $0 < 0x80 }.compactMap { Unicode.Scalar(UInt32($0)).map(Character.init) }
        let basicCount = output.count
        var handled = basicCount
        if basicCount > 0 { output.append("-") }

        var n = initialN
        var delta = 0
        var bias = initialBias
        while handled < input.count {
            guard let next = input.filter({ $0 >= n }).min() else { return nil }
            let (product, overflow) = (next - n).multipliedReportingOverflow(by: handled + 1)
            guard !overflow else { return nil }
            delta += product
            n = next
            for scalar in input {
                if scalar < n { delta += 1 }
                guard scalar == n else { continue }
                var q = delta
                var k = base
                while true {
                    let t = k <= bias ? tMin : (k >= bias + tMax ? tMax : k - bias)
                    if q < t { break }
                    output.append(digit(t + (q - t) % (base - t)))
                    q = (q - t) / (base - t)
                    k += base
                }
                output.append(digit(q))
                bias = adapt(delta: delta, points: handled + 1, first: handled == basicCount)
                delta = 0
                handled += 1
            }
            delta += 1
            n += 1
        }
        return String(output)
    }

    private static func digit(_ value: Int) -> Character {
        let scalar = value < 26 ? 0x61 + value : 0x30 + value - 26
        return Character(Unicode.Scalar(UInt8(scalar)))
    }

    private static func adapt(delta: Int, points: Int, first: Bool) -> Int {
        var delta = first ? delta / damp : delta / 2
        delta += delta / points
        var k = 0
        while delta > ((base - tMin) * tMax) / 2 {
            delta /= base - tMin
            k += base
        }
        return k + (base - tMin + 1) * delta / (delta + skew)
    }
}
