import Foundation

/// A JSON value of any shape, for surge-cli outputs whose value types vary between keys and versions
/// (`environment` mixes `"0"`, `0`, `true` and nested objects).
enum SurgeJSONValue: Decodable, Sendable, Hashable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: SurgeJSONValue])
    case array([SurgeJSONValue])
    case null

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([SurgeJSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: SurgeJSONValue].self))
        }
    }

    subscript(key: String) -> SurgeJSONValue? {
        if case .object(let object) = self { return object[key] }
        return nil
    }

    var objectValue: [String: SurgeJSONValue]? {
        if case .object(let object) = self { return object }
        return nil
    }

    var arrayValue: [SurgeJSONValue]? {
        if case .array(let array) = self { return array }
        return nil
    }

    /// Strings as is, integral numbers without a fraction, booleans as `true` / `false`.
    var stringValue: String? {
        switch self {
        case .string(let value): value
        case .number(let value): value.rounded() == value && abs(value) < 1e15 ? String(Int64(value)) : String(value)
        case .bool(let value): value ? "true" : "false"
        case .object, .array, .null: nil
        }
    }

    /// Integral numbers, numeric strings and booleans (as 0 / 1).
    var intValue: Int? {
        switch self {
        case .number(let value): value.rounded() == value && abs(value) < 1e15 ? Int(value) : nil
        case .string(let value): Int(value.trimmingCharacters(in: .whitespaces))
        case .bool(let value): value ? 1 : 0
        case .object, .array, .null: nil
        }
    }
}
