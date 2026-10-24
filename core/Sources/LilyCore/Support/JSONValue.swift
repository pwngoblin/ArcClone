import Foundation

/// A type-safe representation of arbitrary JSON, used for every IPC payload.
public enum JSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else if let o = try? c.decode([String: JSONValue].self) { self = .object(o) }
        else { throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unsupported JSON value") }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n): try c.encode(n)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    // MARK: Accessors

    public subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    public var string: String? { if case .string(let s) = self { return s }; return nil }
    public var double: Double? { if case .number(let n) = self { return n }; return nil }
    public var int: Int? { double.map { Int($0) } }
    public var bool: Bool? { if case .bool(let b) = self { return b }; return nil }
    public var array: [JSONValue]? { if case .array(let a) = self { return a }; return nil }
    public var object: [String: JSONValue]? { if case .object(let o) = self { return o }; return nil }
    public var isNull: Bool { self == .null }

    // MARK: Conversion

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.withoutEscapingSlashes]
        return e
    }()

    public static func parse(_ string: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(string.utf8))
    }

    public static func parse(_ data: Data) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: data)
    }

    public static func from<T: Encodable>(_ value: T) throws -> JSONValue {
        try parse(encoder.encode(value))
    }

    public func decode<T: Decodable>(_ type: T.Type) throws -> T {
        try JSONDecoder().decode(type, from: Self.encoder.encode(self))
    }

    public func jsonData() -> Data {
        (try? Self.encoder.encode(self)) ?? Data("null".utf8)
    }

    public func jsonString() -> String {
        String(decoding: jsonData(), as: UTF8.self)
    }
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral,
    ExpressibleByBooleanLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral, ExpressibleByNilLiteral
{
    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
    public init(nilLiteral: ()) { self = .null }
}

public extension JSONValue {
    init(_ string: String?) { self = string.map(JSONValue.string) ?? .null }
    init(_ int: Int) { self = .number(Double(int)) }
    init(_ bool: Bool) { self = .bool(bool) }
}
