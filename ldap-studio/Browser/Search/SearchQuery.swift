//
//  SearchQuery.swift
//  ldap-studio
//

import Foundation

/// The kinds of entry the search field's chips narrow a search to — what
/// "Find Users, Contacts, and Groups" asks first, instead of an objectClass
/// filter.
enum EntryKind: String, CaseIterable, Identifiable, Codable {
    case all, people, groups, containers, computers

    var id: Self { self }

    var title: String {
        switch self {
        case .all: "All"
        case .people: "People"
        case .groups: "Groups"
        case .containers: "OUs"
        case .computers: "Computers"
        }
    }

    var symbol: String {
        switch self {
        case .all: "square.grid.2x2"
        case .people: "person.fill"
        case .groups: "person.2.fill"
        case .containers: "folder.fill"
        case .computers: "desktopcomputer"
        }
    }

    /// The object classes that make an entry this kind, across OpenLDAP
    /// and Active Directory spellings.
    private var objectClasses: [String] {
        switch self {
        case .all: []
        case .people: ["person", "inetOrgPerson", "posixAccount", "account"]
        case .groups: ["groupOfNames", "groupOfUniqueNames", "groupOfMembers", "groupOfURLs", "posixGroup", "group"]
        case .containers: ["organizationalUnit", "container", "nsContainer"]
        case .computers: ["computer", "device", "ipHost"]
        }
    }

    /// The filter that picks out this kind; nil for everything. Only
    /// classes the schema knows are named: a server compares an unknown one
    /// as Undefined, and inside a NOT that would match nothing at all.
    func filter(schema: LdapSchema?) -> String? {
        guard self != .all else { return nil }
        let known = schema.map { schema in
            Set(schema.objectClasses.flatMap(\.names).map { $0.lowercased() })
        }
        func isKnown(_ name: String) -> Bool { known?.contains(name.lowercased()) ?? true }
        var classes = objectClasses.filter(isKnown)
        if classes.isEmpty { classes = objectClasses }
        let any = classes.count == 1
            ? "(objectClass=\(classes[0]))"
            : "(|" + classes.map { "(objectClass=\($0))" }.joined() + ")"
        // An Active Directory computer is also a person and a user.
        if self == .people, let known, known.contains("computer") {
            return "(&\(any)(!(objectClass=computer)))"
        }
        return any
    }

    /// Which kind an entry is, going by the icon the tree gives it — so a
    /// result is grouped the way it's drawn. Nil for anything else.
    nonisolated static func of(icon: String) -> EntryKind? {
        switch icon {
        case "person.fill": .people
        case "person.2.fill": .groups
        case "folder.fill": .containers
        case "desktopcomputer", "server.rack": .computers
        default: nil
        }
    }
}

/// How far below the base a search looks.
enum SearchDepth: String, CaseIterable, Identifiable, Codable {
    case subtree, oneLevel, base

    var id: Self { self }

    var title: String {
        switch self {
        case .subtree: "All Levels"
        case .oneLevel: "Direct Children Only"
        case .base: "The Entry Itself"
        }
    }

    var scope: LdapSearchScope {
        switch self {
        case .subtree: .subtree
        case .oneLevel: .oneLevel
        case .base: .base
        }
    }
}

nonisolated enum LDAPFilterJoin: String, CaseIterable, Identifiable, Codable {
    case and, or

    var id: Self { self }
    var title: String { self == .and ? "all" : "any" }
    var marker: Character { self == .and ? "&" : "|" }
}

nonisolated enum LDAPFilterOperator: String, CaseIterable, Identifiable, Codable {
    case equals = "is"
    case contains = "contains"
    case beginsWith = "begins with"
    case endsWith = "ends with"
    case greaterOrEqual = "is ≥"
    case lessOrEqual = "is ≤"
    case approximately = "is approximately"
    case present = "is set"

    var id: Self { self }
    var needsValue: Bool { self != .present }
}

/// One condition of a search: an attribute, how it's compared, and a value.
nonisolated struct LDAPFilterClause: Identifiable, Hashable, Codable {
    var id = UUID()
    var attribute = ""
    var operation: LDAPFilterOperator = .equals
    var value = ""
    var isNegated = false

    /// Nil until the clause is complete — an attribute, and a value when
    /// the operator takes one.
    var filter: String? {
        let attribute = attribute.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !attribute.isEmpty else { return nil }
        guard !operation.needsValue || !value.isEmpty else { return nil }

        let escaped = DN.escapeFilterValue(value)
        let assertion: String
        switch operation {
        case .equals: assertion = "\(attribute)=\(escaped)"
        case .contains: assertion = "\(attribute)=*\(escaped)*"
        case .beginsWith: assertion = "\(attribute)=\(escaped)*"
        case .endsWith: assertion = "\(attribute)=*\(escaped)"
        case .greaterOrEqual: assertion = "\(attribute)>=\(escaped)"
        case .lessOrEqual: assertion = "\(attribute)<=\(escaped)"
        case .approximately: assertion = "\(attribute)~=\(escaped)"
        case .present: assertion = "\(attribute)=*"
        }

        let filter = "(\(assertion))"
        return isNegated ? "(!\(filter))" : filter
    }

    /// "mail ends with @cbpf.br", "not loginShell is /bin/false".
    var summary: String {
        let body = operation.needsValue
            ? "\(attribute) \(operation.rawValue) \(value)"
            : "\(attribute) \(operation.rawValue)"
        return isNegated ? "not \(body)" : body
    }
}

/// Everything one search asks for. The search field fills in the kind,
/// the text and where to look; the results view adds conditions, or
/// replaces it all with a filter typed by hand.
struct SearchQuery: Hashable, Codable {
    /// Matched against names, as the search field does (see `nameFilter`).
    var text = ""
    var kind: EntryKind = .all
    var conditions: [LDAPFilterClause] = []
    /// How the conditions combine with each other. The kind and the text
    /// always narrow the search.
    var join: LDAPFilterJoin = .and
    /// A filter typed by hand. When set it is the whole search, and the
    /// fields above are ignored.
    var rawFilter: String?
    /// Where to search from; nil = the connection's base DN.
    var baseDN: String?
    var depth: SearchDepth = .subtree

    var isRaw: Bool { rawFilter != nil }

    /// The filter sent to the server; nil while a condition is unfinished.
    func filter(schema: LdapSchema?) -> String? {
        if let rawFilter {
            return LDAPFilterParser.normalized(rawFilter)
        }
        var parts: [String] = []
        if let kindFilter = kind.filter(schema: schema) { parts.append(kindFilter) }
        let text = text.trimmingCharacters(in: .whitespaces)
        if !text.isEmpty { parts.append(Self.nameFilter(for: text, schema: schema)) }
        if !conditions.isEmpty {
            let clauses = conditions.compactMap(\.filter)
            guard clauses.count == conditions.count else { return nil }
            parts.append(clauses.count == 1 ? clauses[0] : "(\(join.marker)\(clauses.joined()))")
        }
        switch parts.count {
        case 0: return "(objectClass=*)"
        case 1: return parts[0]
        default: return "(&\(parts.joined()))"
        }
    }

    /// A short description, for recent and saved searches: "ana · People".
    var summary: String {
        if let rawFilter { return rawFilter }
        var parts: [String] = []
        let text = text.trimmingCharacters(in: .whitespaces)
        if !text.isEmpty { parts.append(text) }
        parts += conditions.map(\.summary)
        if parts.isEmpty { parts.append("Everything") }
        var summary = parts.joined(separator: conditions.count > 1 && join == .or ? " or " : ", ")
        if kind != .all { summary += " · \(kind.title)" }
        if let baseDN { summary += " in \(DN.rdn(of: baseDN))" }
        return summary
    }

    /// The attributes the conditions (or the hand-typed filter) look at,
    /// which the results table shows as columns. objectClass is left out:
    /// the icon already says what an entry is.
    var mentionedAttributes: [String] {
        let names: [String]
        if let rawFilter {
            names = (try? LDAPFilterParser.parse(rawFilter).attributes) ?? []
        } else {
            names = conditions.map { $0.attribute.trimmingCharacters(in: .whitespaces) }
        }
        var seen = Set<String>()
        // Nor the names the Name column already shows.
        let shown: Set<String> = ["objectclass", "cn", "displayname", "name"]
        return names.filter {
            !$0.isEmpty && !shown.contains($0.lowercased()) && seen.insert($0.lowercased()).inserted
        }
    }

    // MARK: - Matching names

    /// The attributes a name is looked for in, as far as the server's
    /// schema knows them.
    static func namingAttributes(schema: LdapSchema?) -> [String] {
        let attributes = ["cn", "uid", "ou", "o", "dc", "sn", "givenName", "displayName",
                          "mail", "sAMAccountName", "name"]
        guard let schema else { return attributes }
        let known = Set(schema.attributeTypes.flatMap(\.names).map { $0.lowercased() })
        let filtered = attributes.filter { known.contains($0.lowercased()) }
        return filtered.isEmpty ? attributes : filtered
    }

    /// `mail:ana` → ("mail", "ana"): the text looks for one attribute
    /// only. Nil for plain text, or when the schema has no such attribute
    /// (so "Note: see below" is still searched as a name).
    static func attributeShortcut(in text: String, schema: LdapSchema?) -> (attribute: String, value: String)? {
        guard let colon = text.firstIndex(of: ":") else { return nil }
        let attribute = String(text[..<colon])
        let value = text[text.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty,
              let first = attribute.unicodeScalars.first, CharacterSet.letters.contains(first),
              attribute.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || $0 == "-" })
        else { return nil }
        if let schema {
            let known = schema.attributeTypes.contains { type in
                type.names.contains { $0.caseInsensitiveCompare(attribute) == .orderedSame }
            }
            guard known else { return nil }
        }
        return (attribute, value)
    }

    /// Names starting with `text` (a `*` anywhere is a wildcard) across the
    /// naming attributes, or one attribute for `attribute:value`. A whole
    /// filter in parentheses is used as it is.
    static func nameFilter(for text: String, schema: LdapSchema?) -> String {
        if text.hasPrefix("("), text.hasSuffix(")") { return text }
        if let shortcut = attributeShortcut(in: text, schema: schema) {
            return "(\(shortcut.attribute)=\(pattern(for: shortcut.value)))"
        }
        let pattern = pattern(for: text)
        return "(|" + namingAttributes(schema: schema).map { "(\($0)=\(pattern))" }.joined() + ")"
    }

    /// The assertion value for a name search: escaped, starts-with unless
    /// the text has its own wildcards.
    private static func pattern(for text: String) -> String {
        text.contains("*")
            ? text.split(separator: "*", omittingEmptySubsequences: false)
                .map { DN.escapeFilterValue(String($0)) }
                .joined(separator: "*")
            : DN.escapeFilterValue(text) + "*"
    }

    /// Whether `value` matches the search text the way the server would
    /// have — what decides which attribute a result is shown as matching.
    static func value(_ value: String, matches text: String) -> Bool {
        let parts = text.lowercased().split(separator: "*", omittingEmptySubsequences: false).map(String.init)
        let value = value.lowercased()
        guard parts.count > 1 else { return value.hasPrefix(parts[0]) }
        guard value.hasPrefix(parts[0]) else { return false }
        var rest = value.dropFirst(parts[0].count)
        for (index, part) in parts.dropFirst().enumerated() {
            if part.isEmpty { continue }
            let isLast = index == parts.count - 2
            if isLast { return rest.hasSuffix(part) }
            guard let range = rest.range(of: part) else { return false }
            rest = rest[range.upperBound...]
        }
        return true
    }
}

extension SavedLDAPFilter {
    /// What the search menus show for it.
    var title: String { name ?? query?.summary ?? filter }

    /// The search it reopens: the one it was saved from, or its filter.
    var searchQuery: SearchQuery { query ?? SearchQuery(rawFilter: filter) }
}

/// Recent and pinned searches, kept per connection: pinned ones stay,
/// the last ten others are kept newest first.
enum SavedSearches {
    static let recentLimit = 10

    static func pinned(_ filters: [SavedLDAPFilter]) -> [SavedLDAPFilter] {
        filters
            .filter(\.isPinned)
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    static func recent(_ filters: [SavedLDAPFilter]) -> [SavedLDAPFilter] {
        filters
            .filter { !$0.isPinned }
            .sorted { $0.lastUsed > $1.lastUsed }
    }

    /// Whether `item` is the search `query` makes with `filter`: the same
    /// filter, searched from the same place, as deep.
    static func item(_ item: SavedLDAPFilter, isSearch query: SearchQuery, filter: String) -> Bool {
        item.filter == filter
            && item.query?.baseDN == query.baseDN
            && (item.query?.depth ?? .subtree) == query.depth
    }

    /// `filters` with `query` marked as just used.
    static func recording(_ query: SearchQuery, filter: String, in filters: [SavedLDAPFilter]) -> [SavedLDAPFilter] {
        var updated = filters
        if let index = updated.firstIndex(where: { item($0, isSearch: query, filter: filter) }) {
            updated[index].lastUsed = .now
            updated[index].query = query
        } else {
            updated.append(SavedLDAPFilter(filter: filter, query: query))
        }
        return trimmed(updated)
    }

    /// `filters` with `query` pinned under `name`.
    static func pinning(_ query: SearchQuery, filter: String, name: String?,
                        in filters: [SavedLDAPFilter]) -> [SavedLDAPFilter] {
        var updated = filters
        if let index = updated.firstIndex(where: { item($0, isSearch: query, filter: filter) }) {
            updated[index].name = name
            updated[index].isPinned = true
            updated[index].query = query
            updated[index].lastUsed = .now
        } else {
            updated.append(SavedLDAPFilter(name: name, filter: filter, isPinned: true, query: query))
        }
        return trimmed(updated)
    }

    static func unpinning(_ item: SavedLDAPFilter, in filters: [SavedLDAPFilter]) -> [SavedLDAPFilter] {
        var updated = filters
        guard let index = updated.firstIndex(where: { $0.id == item.id }) else { return filters }
        updated[index].isPinned = false
        updated[index].name = nil
        updated[index].lastUsed = .now
        return trimmed(updated)
    }

    static func clearingRecent(_ filters: [SavedLDAPFilter]) -> [SavedLDAPFilter] {
        filters.filter(\.isPinned)
    }

    private static func trimmed(_ filters: [SavedLDAPFilter]) -> [SavedLDAPFilter] {
        filters.filter(\.isPinned) + recent(filters).prefix(recentLimit)
    }
}
