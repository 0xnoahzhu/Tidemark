import Foundation
import PostgresNIO

extension PostgresDatabase {
    /// Builds an SQL statement with numbered binds (`$1`, `$2`, …) for dynamic queries and multi-row
    /// `VALUES` lists. Placeholders carry explicit casts at the call site where the column type is not
    /// the bind's natural type (`inet`, `jsonb`, `real`, …).
    struct SQL: Sendable {
        private(set) var text: String
        private(set) var binds = PostgresBindings()

        init(_ text: String = "") { self.text = text }

        var query: PostgresQuery { PostgresQuery(unsafeSQL: text, binds: binds) }
        var bindCount: Int { binds.count }

        mutating func append(_ fragment: String) { text += fragment }

        /// Appends a value and returns its placeholder.
        mutating func bind<Value: PostgresDynamicTypeEncodable>(_ value: Value) -> String {
            binds.append(value)
            return "$\(binds.count)"
        }

        /// Appends a value or NULL and returns its placeholder.
        mutating func bind<Value: PostgresDynamicTypeEncodable>(_ value: Value?) -> String {
            binds.append(value)
            return "$\(binds.count)"
        }

        /// Appends a timestamp that must compare exactly against a stored one (a cursor read back
        /// from the database). `to_timestamp(epoch)` rounds to the nearest microsecond, whereas a bound
        /// `Date` is truncated and can land a microsecond early after a decode/encode round trip.
        mutating func bindInstant(_ date: Date) -> String {
            "to_timestamp(\(bind(date.timeIntervalSince1970))::float8)"
        }

        /// Appends `value` as JSON text and returns `$n::jsonb`.
        mutating func bindJSON<Value: Encodable>(_ value: Value?) throws -> String {
            guard let value else { return bind(String?.none) + "::jsonb" }
            return bind(try PostgresDatabase.jsonText(value)) + "::jsonb"
        }
    }

    /// Bind limit of the extended query protocol.
    static let maxBinds = Int(UInt16.max)

    // MARK: - JSON

    static let jsonEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    static let jsonDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }()

    static func jsonText<Value: Encodable>(_ value: Value) throws -> String {
        String(decoding: try jsonEncoder.encode(value), as: UTF8.self)
    }

    // MARK: - Text helpers

    /// `%value%` for ILIKE, with `\`, `%` and `_` escaped (backslash is LIKE's default escape).
    static func containsPattern(_ value: String) -> String {
        "%" + escapeLike(value) + "%"
    }

    static func escapeLike(_ value: String) -> String {
        var escaped = ""
        escaped.reserveCapacity(value.count)
        for character in value {
            if character == "\\" || character == "%" || character == "_" { escaped.append("\\") }
            escaped.append(character)
        }
        return escaped
    }

    /// An IP address as PostgreSQL's `inet` accepts it (no brackets, no zone), or nil.
    static func inetText(_ value: String?) -> String? {
        guard var ip = value?.trimmingCharacters(in: .whitespaces), !ip.isEmpty else { return nil }
        if ip.hasPrefix("["), ip.hasSuffix("]") { ip = String(ip.dropFirst().dropLast()) }
        if let zone = ip.firstIndex(of: "%") { ip = String(ip[..<zone]) }
        return HostName.isIPAddress(ip) ? ip : nil
    }

    /// Splits `items` into chunks whose bind count stays under the protocol limit.
    static func chunks<Element>(_ items: [Element], bindsPerItem: Int, maxItems: Int = 1_000) -> [ArraySlice<Element>] {
        let size = max(1, min(maxItems, maxBinds / max(1, bindsPerItem)))
        return stride(from: 0, to: items.count, by: size).map { items[$0..<min($0 + size, items.count)] }
    }
}

/// Column access by name with typed decoding.
struct PostgresRowReader {
    private let row: PostgresRandomAccessRow

    init(_ row: PostgresRow) { self.row = row.makeRandomAccess() }

    func callAsFunction<Value: PostgresDecodable>(_ column: String, as type: Value.Type = Value.self) throws -> Value {
        try row[column].decode(Value.self)
    }

    /// Decodes a `json`/`jsonb` (or JSON text) column; NULL decodes to nil.
    func json<Value: Decodable>(_ column: String, as type: Value.Type = Value.self) throws -> Value? {
        guard let text = try row[column].decode(String?.self) else { return nil }
        do {
            return try PostgresDatabase.jsonDecoder.decode(Value.self, from: Data(text.utf8))
        } catch {
            throw DatabaseError.query("Could not read JSON column \(column): \(error.localizedDescription)")
        }
    }

    /// `real` / `double precision` as Double.
    func double(_ column: String) throws -> Double {
        try row[column].decode(Double.self)
    }
}
