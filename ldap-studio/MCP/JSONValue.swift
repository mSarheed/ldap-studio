//
//  JSONValue.swift
//  ldap-studio
//
//  Any JSON value, for the MCP server's JSON-RPC messages — whose
//  parameters and results are free-form objects rather than fixed types.
//

import Foundation

nonisolated enum JSONValue: Sendable, Equatable, Codable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

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

    static func decode(_ data: Data) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: data)
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
