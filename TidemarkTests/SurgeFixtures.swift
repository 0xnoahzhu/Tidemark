import Foundation
@testable import Tidemark

/// Loads JSON captured from `surge-cli --raw` (Surge Mac 6.10) in `Fixtures/Surge/`, sanitized.
enum SurgeFixtures {
    static func data(_ fileName: String) throws -> Data {
        try Data(contentsOf: url(fileName))
    }

    static func url(_ fileName: String) -> URL {
        let name = (fileName as NSString).deletingPathExtension
        let ext = (fileName as NSString).pathExtension
        if let bundled = Bundle(for: BundleToken.self).url(forResource: name, withExtension: ext) {
            return bundled
        }
        return URL(filePath: #filePath).deletingLastPathComponent().appending(path: "Fixtures/Surge/\(fileName)")
    }

    /// Non-empty lines of a JSON-lines fixture.
    static func lines(_ fileName: String) throws -> [Data] {
        var splitter = SurgeLineSplitter()
        var lines = splitter.append(try data(fileName))
        if let last = splitter.finish() { lines.append(last) }
        return lines
    }

    private final class BundleToken {}
}
