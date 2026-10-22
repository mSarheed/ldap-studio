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

    /// At most `maxBytes` of UTF-8, cut at a scalar boundary — for text
    /// that quotes what a client sent. (Counting Characters isn't enough:
    /// one letter with 400,000 combining accents is a single Character.)
    static func truncated(_ text: some StringProtocol, maxBytes: Int) -> String {
        guard text.utf8.count > maxBytes else { return String(text) }
        var result = String.UnicodeScalarView()
        var bytes = 0
        for scalar in text.unicodeScalars {
            bytes += String(scalar).utf8.count
            guard bytes <= maxBytes else { break }
            result.append(scalar)
        }
        return String(result) + "…"
    }

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
            // Whole numbers become .int only when that's exact — 42.0 is 42,
            // but 2^63 (which Int can't hold) stays a double rather than
            // wrapping, so a request id is never silently changed.
            if CFNumberIsFloatType(number) {
                let value = number.doubleValue
                if value.rounded() == value, abs(value) < 9_007_199_254_740_992 { return .int(Int(value)) }
                return .double(value)
            }
            var value: Int64 = 0
            guard CFNumberGetValue(number, .sInt64Type, &value),
                  number.compare(NSNumber(value: value)) == .orderedSame else {
                return .double(number.doubleValue)
            }
            return .int(Int(value))
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
