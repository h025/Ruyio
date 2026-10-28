import Foundation

/// Untyped JSON used for payloads and parameters. Decoding never instantiates arbitrary Swift types.
public enum JSONValue: Hashable, Sendable, Codable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    /// Nesting is bounded while decoding, not afterwards: recursion on a reader thread must never be
    /// able to exhaust its stack (a deeply nested frame would otherwise crash the host).
    public static let maxDecodingDepth = 48

    public init(from decoder: Decoder) throws {
        guard decoder.codingPath.count <= Self.maxDecodingDepth else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "JSON nested too deeply"))
        }
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
        else if let value = try? container.decode([String: JSONValue].self) { self = .object(value) }
        else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    public var stringValue: String? { if case .string(let v) = self { return v }; return nil }
    public var boolValue: Bool? { if case .bool(let v) = self { return v }; return nil }
    public var doubleValue: Double? { if case .number(let v) = self { return v }; return nil }
    public var intValue: Int? { doubleValue.flatMap { $0.isFinite ? Int(exactly: $0.rounded()) : nil } }
    public var arrayValue: [JSONValue]? { if case .array(let v) = self { return v }; return nil }
    public var objectValue: [String: JSONValue]? { if case .object(let v) = self { return v }; return nil }

    public subscript(key: String) -> JSONValue? { objectValue?[key] }

    /// Nesting depth, used to enforce protocol limits.
    public var depth: Int {
        switch self {
        case .array(let values): return 1 + (values.map(\.depth).max() ?? 0)
        case .object(let values): return 1 + (values.values.map(\.depth).max() ?? 0)
        default: return 0
        }
    }
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByFloatLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral, ExpressibleByNilLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
    public init(nilLiteral: ()) { self = .null }
}

public enum JSONCoding {
    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// Converts any Encodable into a JSONValue tree.
    public static func value<T: Encodable>(_ value: T) throws -> JSONValue {
        let data = try encoder().encode(value)
        return try decoder().decode(JSONValue.self, from: data)
    }

    /// Decodes a typed value from a JSONValue tree.
    public static func decode<T: Decodable>(_ type: T.Type, from value: JSONValue) throws -> T {
        let data = try encoder().encode(value)
        return try decoder().decode(T.self, from: data)
    }
}
