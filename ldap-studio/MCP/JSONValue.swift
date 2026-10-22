//
//  JSONValue.swift
//  ldap-studio
//
//  Any JSON value, for the MCP server's JSON-RPC messages — whose
//  parameters and results are free-form objects rather than fixed types.
//

import Foundation

nonisolated enum JSONValue: Sendable, Equatable, Encodable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case let .bool(value): try container.encode(value)
        case let .int(value): try container.encode(value)
        case let .double(value): try container.encode(value)
        case let .string(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case let .object(value): try container.encode(value)
        }
    }

    subscript(key: String) -> JSONValue? {
        if case let .object(object) = self { return object[key] }
        return nil
    }

    var stringValue: String? {
        if case let .string(value) = self { return value }
        return nil
    }

    var objectValue: [String: JSONValue]? {
        if case let .object(value) = self { return value }
        return nil
    }

    /// Compact, with keys in a stable order.
    func encoded() -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(self)) ?? Data("null".utf8)
    }

    var encodedString: String { String(decoding: encoded(), as: UTF8.self) }

    struct DecodingError: Error {}

    /// Deeper than this is refused; MCP messages are a few levels deep.
    static let maxDepth = 64

    /// Parses with JSONSerialization — one linear pass. (Decoding this
    /// enum with Decodable means trying each case in turn, which on nested
    /// input backtracks exponentially: a 16 KB request took seconds.)
    static func decode(_ data: Data) throws -> JSONValue {
        let object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        return try convert(object, depth: 0)
    }

    private static func convert(_ object: Any, depth: Int) throws -> JSONValue {
        guard depth <= maxDepth else { throw DecodingError() }
        switch object {
        case is NSNull:
            return .null
        case let string as String:
            return .string(string)
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return .bool(number.boolValue) }
            if CFNumberIsFloatType(number) { return .double(number.doubleValue) }
            return .int(number.intValue)
        case let array as [Any]:
            return .array(try array.map { try convert($0, depth: depth + 1) })
        case let dictionary as [String: Any]:
            return .object(try dictionary.mapValues { try convert($0, depth: depth + 1) })
        default:
            throw DecodingError()
        }
    }
}

nonisolated extension JSONValue: ExpressibleByStringLiteral, ExpressibleByBooleanLiteral,
    ExpressibleByIntegerLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral {
    init(stringLiteral value: String) { self = .string(value) }
    init(booleanLiteral value: Bool) { self = .bool(value) }
    init(integerLiteral value: Int) { self = .int(value) }
    init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
}

nonisolated extension JSONValue {
    init(_ strings: [String]) { self = .array(strings.map(JSONValue.string)) }
    init(_ string: String?) { self = string.map(JSONValue.string) ?? .null }
}
