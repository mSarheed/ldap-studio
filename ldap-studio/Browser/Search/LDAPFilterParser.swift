//
//  LDAPFilterParser.swift
//  ldap-studio
//

import Foundation

/// A parsed RFC 4515 filter — enough to check one as it's typed, list the
/// attributes it looks at, and turn simple ones back into conditions.
nonisolated indirect enum LDAPFilterNode: Equatable {
    case and([LDAPFilterNode])
    case or([LDAPFilterNode])
    case not(LDAPFilterNode)
    /// `value` as written, escapes and wildcards included.
    case item(attribute: String, comparison: Comparison, value: String)

    enum Comparison: Equatable {
        case equal, greaterOrEqual, lessOrEqual, approximately
        /// `attr:dn:rule:=value` and friends — valid, but never a condition.
        case extensible
    }

    /// Every attribute named, in order, repeats included.
    var attributes: [String] {
        switch self {
        case let .and(nodes), let .or(nodes): nodes.flatMap(\.attributes)
        case let .not(node): node.attributes
        case let .item(attribute, comparison, _):
            comparison == .extensible
                ? [String(attribute.split(separator: ":").first ?? "")].filter { !$0.isEmpty }
                : [attribute]
        }
    }
}

nonisolated struct LDAPFilterError: Error, Equatable, CustomStringConvertible {
    let message: String
    /// Character offset the problem was found at.
    let offset: Int

    var description: String { message }
}

nonisolated enum LDAPFilterParser {
    /// The filter as sent: trimmed, with a missing outer pair of
    /// parentheses added, so `uid=jdoe` works as well as `(uid=jdoe)`.
    static func normalized(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }
        return trimmed.hasPrefix("(") ? trimmed : "(\(trimmed))"
    }

    static func parse(_ text: String) throws(LDAPFilterError) -> LDAPFilterNode {
        let source = normalized(text)
        guard !source.isEmpty else { throw LDAPFilterError(message: "Type a filter", offset: 0) }
        var parser = Parser(characters: Array(source))
        let node = try parser.filter()
        guard parser.position == parser.characters.count else {
            throw LDAPFilterError(message: "Unexpected text after the filter’s closing parenthesis",
                                  offset: parser.position)
        }
        return node
    }

    /// Conditions equivalent to `text` — a single comparison, or an AND or
    /// OR of comparisons (each maybe negated). Nil for anything deeper,
    /// which only the text editor can show.
    static func conditions(from text: String) -> (join: LDAPFilterJoin, clauses: [LDAPFilterClause])? {
        guard let node = try? parse(text) else { return nil }
        let join: LDAPFilterJoin
        let nodes: [LDAPFilterNode]
        switch node {
        case let .and(list): (join, nodes) = (.and, list)
        case let .or(list): (join, nodes) = (.or, list)
        default: (join, nodes) = (.and, [node])
        }
        guard !nodes.isEmpty else { return nil }
        let clauses = nodes.compactMap(clause)
        guard clauses.count == nodes.count else { return nil }
        return (join, clauses)
    }

    private static func clause(_ node: LDAPFilterNode) -> LDAPFilterClause? {
        switch node {
        case let .not(inner):
            guard var clause = clause(inner), !clause.isNegated else { return nil }
            clause.isNegated = true
            return clause
        case let .item(attribute, comparison, raw):
            let operation: LDAPFilterOperator
            var value = raw
            switch comparison {
            case .extensible:
                return nil
            case .greaterOrEqual: operation = .greaterOrEqual
            case .lessOrEqual: operation = .lessOrEqual
            case .approximately: operation = .approximately
            case .equal:
                let stars = raw.filter { $0 == "*" }.count
                if raw == "*" {
                    operation = .present
                    value = ""
                } else if stars == 0 {
                    operation = .equals
                } else if stars == 2, raw.count > 2, raw.hasPrefix("*"), raw.hasSuffix("*") {
                    operation = .contains
                    value = String(raw.dropFirst().dropLast())
                } else if stars == 1, raw.hasSuffix("*") {
                    operation = .beginsWith
                    value = String(raw.dropLast())
                } else if stars == 1, raw.hasPrefix("*") {
                    operation = .endsWith
                    value = String(raw.dropFirst())
                } else {
                    return nil
                }
            }
            guard let unescaped = unescape(value) else { return nil }
            return LDAPFilterClause(attribute: attribute, operation: operation, value: unescaped)
        case .and, .or:
            return nil
        }
    }

    /// `\xx` escapes turned back into the bytes they stand for.
    static func unescape(_ value: String) -> String? {
        var bytes: [UInt8] = []
        var iterator = Array(value.utf8).makeIterator()
        while let byte = iterator.next() {
            guard byte == UInt8(ascii: "\\") else {
                bytes.append(byte)
                continue
            }
            guard let high = iterator.next(), let low = iterator.next(),
                  let decoded = UInt8(String(bytes: [high, low], encoding: .ascii) ?? "", radix: 16)
            else { return nil }
            bytes.append(decoded)
        }
        return String(bytes: bytes, encoding: .utf8)
    }

    private struct Parser {
        let characters: [Character]
        var position = 0

        private var current: Character? {
            position < characters.count ? characters[position] : nil
        }

        mutating func filter() throws(LDAPFilterError) -> LDAPFilterNode {
            try expect("(")
            let node: LDAPFilterNode
            switch current {
            case "&":
                position += 1
                node = .and(try list())
            case "|":
                position += 1
                node = .or(try list())
            case "!":
                position += 1
                node = .not(try filter())
            case nil:
                throw LDAPFilterError(message: "The filter ends too soon", offset: position)
            default:
                node = try item()
            }
            try expect(")")
            return node
        }

        private mutating func list() throws(LDAPFilterError) -> [LDAPFilterNode] {
            var nodes: [LDAPFilterNode] = []
            while current == "(" {
                nodes.append(try filter())
            }
            return nodes
        }

        private mutating func item() throws(LDAPFilterError) -> LDAPFilterNode {
            let start = position
            var attribute = ""
            while let character = current, !"=~<>()".contains(character) {
                attribute.append(character)
                position += 1
            }
            let comparison: LDAPFilterNode.Comparison
            switch current {
            case "=":
                comparison = attribute.hasSuffix(":") ? .extensible : .equal
                position += 1
            case "~", "<", ">":
                let op = current!
                position += 1
                guard current == "=" else {
                    throw LDAPFilterError(message: "Expected “=” after “\(op)”", offset: position)
                }
                position += 1
                comparison = op == "~" ? .approximately : op == "<" ? .lessOrEqual : .greaterOrEqual
            default:
                throw LDAPFilterError(
                    message: attribute.isEmpty ? "Expected an attribute name" : "Expected “=” after “\(attribute)”",
                    offset: position)
            }
            if comparison == .extensible {
                attribute.removeLast()
            }
            let name = comparison == .extensible ? attribute.split(separator: ":").first.map(String.init) ?? "" : attribute
            guard comparison == .extensible ? !attribute.isEmpty : !name.isEmpty else {
                throw LDAPFilterError(message: "Expected an attribute name", offset: start)
            }
            let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-.;:"))
            guard attribute.unicodeScalars.allSatisfy({ allowed.contains($0) }),
                  comparison == .extensible || !attribute.contains(":") else {
                throw LDAPFilterError(message: "“\(attribute)” isn’t a valid attribute name", offset: start)
            }

            var value = ""
            while let character = current, character != ")" {
                if character == "(" {
                    throw LDAPFilterError(message: "“(” in a value must be written \\28", offset: position)
                }
                if character == "\\" {
                    let digits = characters[min(position + 1, characters.count)..<min(position + 3, characters.count)]
                    guard digits.count == 2, digits.allSatisfy(\.isHexDigit) else {
                        throw LDAPFilterError(message: "“\\” must be followed by two hex digits", offset: position)
                    }
                    value.append(contentsOf: "\\" + String(digits))
                    position += 3
                    continue
                }
                if character == "*", comparison != .equal {
                    throw LDAPFilterError(message: "Wildcards only work with “=”", offset: position)
                }
                value.append(character)
                position += 1
            }
            return .item(attribute: attribute, comparison: comparison, value: value)
        }

        private mutating func expect(_ character: Character) throws(LDAPFilterError) {
            guard current == character else {
                let found = current.map { "“\($0)”" } ?? "the end"
                throw LDAPFilterError(message: "Expected “\(character)” but found \(found)", offset: position)
            }
            position += 1
        }
    }
}
