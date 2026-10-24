import Foundation

/// Splits a byte stream into lines at `\n` only.
///
/// `AsyncLineSequence` also breaks at U+2028, U+2029 and NEL, which JSON allows unescaped inside strings
/// (request notes can contain them), so a dedicated splitter keeps every JSON object on one line.
/// A trailing `\r` is dropped and empty lines are skipped.
struct SurgeLineSplitter {
    private var pending = Data()

    /// Appends a chunk and returns the lines it completed.
    mutating func append(_ chunk: Data) -> [Data] {
        var lines: [Data] = []
        var start = chunk.startIndex
        while let newline = chunk[start...].firstIndex(of: 0x0A) {
            if pending.isEmpty {
                Self.emit(Data(chunk[start..<newline]), into: &lines)
            } else {
                pending.append(chunk[start..<newline])
                Self.emit(pending, into: &lines)
                pending = Data()
            }
            start = chunk.index(after: newline)
        }
        if start < chunk.endIndex { pending.append(chunk[start...]) }
        return lines
    }

    /// Returns the unterminated last line, if any, and resets the splitter.
    mutating func finish() -> Data? {
        defer { pending = Data() }
        var lines: [Data] = []
        Self.emit(pending, into: &lines)
        return lines.first
    }

    private static func emit(_ line: Data, into lines: inout [Data]) {
        var line = line
        if line.last == 0x0D { line.removeLast() }
        if !line.isEmpty { lines.append(line) }
    }
}
