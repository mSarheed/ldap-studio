//
//  MCPTools.swift
//  ldap-studio
//
//  The tools the MCP server offers AI agents. Every one is a read: they
//  reach directories through `ReadOnlyDirectory` only, see only the
//  connections the user shared with agents, never see a password, and
//  hand back results small enough to fit in a model's context.
//

import Foundation

@MainActor
final class MCPTools {
    /// The saved connections, read afresh for every call so turning a
    /// connection's sharing off takes effect on the next request.
    private let connections: () -> [SavedConnection]
    /// Attribute names the user added to the always-hidden ones.
    private let extraHidden: () -> [String]

    init(connections: @escaping () -> [SavedConnection], extraHidden: @escaping () -> [String] = { [] }) {
        self.connections = connections
        self.extraHidden = extraHidden
    }

    // MARK: Limits

    nonisolated static let defaultSearchLimit = 50
    nonisolated static let maxSearchLimit = 500
    nonisolated static let defaultChildLimit = 200
    nonisolated static let maxChildLimit = 1000
    /// Results stop growing past this much JSON, however many entries were
    /// asked for — beyond it they'd swamp the agent's context anyway.
    nonisolated static let maxResultBytes = 256 * 1024
    nonisolated static let maxValuesPerAttribute = 100
    nonisolated static let maxValueLength = 2000
    nonisolated static let maxInputLength = 4096
    nonisolated static let maxRequestedAttributes = 100
    /// A call still running after this long is answered with an error and
    /// cancelled.
    nonisolated static let callTimeout: Duration = .seconds(90)

    /// When reading each connection's schema last failed — it isn't asked
    /// for again on every call for a while.
    private var schemaFailures: [SavedConnection: ContinuousClock.Instant] = [:]
    nonisolated private static let schemaRetryInterval: Duration = .seconds(300)

    // MARK: Definitions

    nonisolated static let definitions: [JSONValue] = [
        tool("list_connections",
             title: "List LDAP connections",
             description: "Lists the LDAP directories the user has shared with agents in LDAP Studio. Call this first: every other tool takes one of these connection names.",
             properties: [:], required: []),
        tool("get_server_info",
             title: "Get LDAP server info",
             description: "Reads the server's root DSE: naming contexts (the top-level DNs), vendor and version, supported LDAP controls, extensions and SASL mechanisms.",
             properties: ["connection": connectionProperty], required: ["connection"]),
        tool("search",
             title: "Search an LDAP directory",
             description: "Runs an LDAP search with an RFC 4515 filter, e.g. (&(objectClass=person)(sn=Smith*)). Returns at most `limit` entries; narrow the filter or base_dn rather than raising the limit when results are cut short. Attributes holding secrets (userPassword and the like) are never returned and can't be used in the filter.",
             properties: [
                 "connection": connectionProperty,
                 "filter": ["type": "string", "description": "RFC 4515 filter in parentheses. Default: (objectClass=*)."],
                 "base_dn": ["type": "string", "description": "Where to search from. Default: the connection's base DN."],
                 "scope": ["type": "string", "enum": ["base", "one", "sub"], "description": "base = just base_dn, one = its direct children, sub = everything below it (default)."],
                 "attributes": attributesProperty,
                 "include_operational": operationalProperty,
                 "limit": ["type": "integer", "minimum": 1, "maximum": .int(maxSearchLimit), "description": .string("Most entries to return. Default \(defaultSearchLimit), at most \(maxSearchLimit).")],
             ], required: ["connection"]),
        tool("get_entry",
             title: "Read an LDAP entry",
             description: "Reads one entry by its DN, with all its attributes (or only those asked for).",
             properties: [
                 "connection": connectionProperty,
                 "dn": ["type": "string", "description": "The entry's distinguished name."],
                 "attributes": attributesProperty,
                 "include_operational": operationalProperty,
             ], required: ["connection", "dn"]),
        tool("list_children",
             title: "List an LDAP entry's children",
             description: "Lists the entries directly below a DN — one level of the directory tree — with their object classes and whether they have children of their own. Use it to explore a directory's layout.",
             properties: [
                 "connection": connectionProperty,
                 "dn": ["type": "string", "description": "The parent entry. Default: the connection's base DN. An empty string lists the server's naming contexts."],
                 "limit": ["type": "integer", "minimum": 1, "maximum": .int(maxChildLimit), "description": .string("Most children to return. Default \(defaultChildLimit), at most \(maxChildLimit).")],
             ], required: ["connection"]),
        tool("get_schema",
             title: "Look up the LDAP schema",
             description: "Looks up the directory's schema. With object_class: that class's required (MUST) and optional (MAY) attributes, inherited ones included. With attribute: that attribute type's syntax, matching rules and whether it's single-valued. With neither: the names of every object class and attribute type, optionally narrowed by `contains`.",
             properties: [
                 "connection": connectionProperty,
                 "object_class": ["type": "string", "description": "An object class name, e.g. inetOrgPerson."],
                 "attribute": ["type": "string", "description": "An attribute type name, e.g. mail."],
                 "contains": ["type": "string", "description": "When listing names, only those containing this text (case-insensitive)."],
             ], required: ["connection"]),
    ]

    nonisolated private static let connectionProperty: JSONValue = [
        "type": "string",
        "description": "A connection name from list_connections.",
    ]
    nonisolated private static let attributesProperty: JSONValue = [
        "type": "array", "items": ["type": "string"],
        "description": "Attribute names to return. Default: every user attribute.",
    ]
    nonisolated private static let operationalProperty: JSONValue = [
        "type": "boolean",
        "description": "Also return operational attributes (createTimestamp, modifiersName, entryUUID, memberOf on some servers…). Default false.",
    ]

    nonisolated private static func tool(_ name: String, title: String, description: String,
                                         properties: [String: JSONValue], required: [String]) -> JSONValue {
        [
            "name": .string(name),
            "title": .string(title),
            "description": .string(description),
            "inputSchema": [
                "type": "object",
                "properties": .object(properties),
                "required": JSONValue(required),
                "additionalProperties": false,
            ],
            "annotations": [
                "title": .string(title),
                "readOnlyHint": true,
                "destructiveHint": false,
                "idempotentHint": true,
                "openWorldHint": false,
            ],
        ]
    }

    nonisolated static var toolNames: Set<String> {
        Set(definitions.compactMap { $0["name"]?.stringValue })
    }

    // MARK: Calling

    /// A mistake the agent can correct — reported as a tool error, so the
    /// model sees it, rather than as a protocol error.
    nonisolated struct ToolError: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    /// Runs tool `name`. Returns the result's text and whether it's an
    /// error; `name` must be one of `toolNames`.
    func call(_ name: String, arguments: [String: JSONValue]) async -> (text: String, isError: Bool) {
        do {
            let result = try await withTimeout(Self.callTimeout) {
                // The slot is held for as long as the work really runs —
                // past a timeout too, while a call into the C core that
                // can't be interrupted finishes.
                try await MCPCallLimiter.shared.acquire()
                defer { MCPCallLimiter.shared.release() }
                try Task.checkCancellation()
                return try await OperationOrigin.$current.withValue("MCP") {
                    try await self.run(name, Arguments(arguments))
                }
            }
            let text = result.encodedString
            // Entries and searches keep to the limit as they're built; this
            // catches anything else that grew past it (JSON escaping, a huge
            // schema).
            guard text.utf8.count <= Self.maxResultBytes + 16 * 1024 else {
                return ("The result is too large to return (\(text.utf8.count / 1024) KB). Ask for fewer attributes, or narrow the request.", true)
            }
            return (text, false)
        } catch is TimeoutError {
            return ("Stopped after \(Self.callTimeout.components.seconds) seconds without finishing. Narrow the search (a more specific filter or base_dn).", true)
        } catch is CancellationError {
            return ("Cancelled.", true)
        } catch {
            return ("\(error)", true)
        }
    }

    private func run(_ name: String, _ args: Arguments) async throws -> JSONValue {
        switch name {
        case "list_connections": return listConnections()
        case "get_server_info": return try await serverInfo(args)
        case "search": return try await search(args)
        case "get_entry": return try await entry(args)
        case "list_children": return try await children(args)
        case "get_schema": return try await schema(args)
        default: throw ToolError("Unknown tool \"\(name)\".")
        }
    }

    // MARK: Tools

    private var shared: [SavedConnection] {
        connections()
            .filter(\.allowsMCP)
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func listConnections() -> JSONValue {
        let list: [JSONValue] = shared.map { connection in
            [
                "name": .string(connection.name),
                "server": .string("\(connection.useSSL ? "ldaps" : "ldap")://\(connection.host):\(connection.port)"),
                "base_dn": .string(connection.baseDN),
                "bind": .string(bindDescription(connection)),
            ]
        }
        return [
            "connections": .array(list),
            "note": list.isEmpty
                ? "No directories are shared with agents yet. The user can share one in LDAP Studio → Settings → MCP Server."
                : "Every tool is read-only. What's visible depends on the permissions of each connection's bind.",
        ]
    }

    private func bindDescription(_ connection: SavedConnection) -> String {
        guard connection.bindDN.isEmpty else { return connection.bindDN }
        return connection.authentication == .simple ? "anonymous" : connection.authentication.title
    }

    private func serverInfo(_ args: Arguments) async throws -> JSONValue {
        let (directory, policy) = try await open(args)
        guard let dse = try await directory.entry(dn: "", attributes: ["*", "+"], includeOperational: true) else {
            throw ToolError("The server didn't return its root DSE.")
        }
        return [
            "connection": .string(directory.connection.name),
            // The root DSE is the server describing itself, and on Active
            // Directory most of its attributes aren't in the schema; it
            // holds no directory data, so names the schema doesn't know are
            // shown here (hidden ones still aren't).
            "root_dse": render(dse, policy: policy, unresolved: .show),
        ]
    }

    private func search(_ args: Arguments) async throws -> JSONValue {
        let (directory, policy) = try await open(args)
        let filter = try args.string("filter") ?? "(objectClass=*)"
        try checkLength(filter, "filter")
        do { try policy.check(filter: filter) } catch { throw ToolError("\(error)") }
        let base = try baseDN(args.string("base_dn"), of: directory)
        let scope: LdapSearchScope = switch try args.string("scope") ?? "sub" {
        case "base": .base
        case "one": .oneLevel
        case "sub": .subtree
        case let other: throw ToolError("scope must be base, one or sub, not \"\(other)\".")
        }
        let attributes = try requestedAttributes(args, policy: policy)
        let limit = try args.int("limit", default: Self.defaultSearchLimit, in: 1...Self.maxSearchLimit)

        var collector = ResultCollector()
        let outcome = try await directory.search(LdapSearchRequest(
            baseDn: base, scope: scope, filter: filter, attributes: attributes,
            includeOperational: try args.bool("include_operational"), limit: limit,
            pageSize: scope == .base ? 0 : min(limit, 500)
        )) { page, _ in
            for entry in page where !collector.add(render(entry, policy: policy)) { return false }
            return true
        }
        var result: [String: JSONValue] = [
            "connection": .string(directory.connection.name),
            "base_dn": .string(base),
            "filter": .string(filter),
            "count": .int(collector.items.count),
            "complete": .bool(outcome.isComplete && !collector.isFull),
            "entries": .array(collector.items),
        ]
        if collector.isFull {
            result["note"] = .string("Stopped once the results reached \(Self.maxResultBytes / 1024) KB. Ask for fewer attributes, or narrow the filter or base_dn.")
        } else if outcome.wasTruncated {
            result["note"] = .string("The server stopped early at its own size limit, so these are only some of the matches. Narrow the filter or base_dn.")
        } else if !outcome.isComplete {
            result["note"] = .string("Stopped at the limit of \(limit). There may be more; narrow the filter or base_dn, or raise limit (at most \(Self.maxSearchLimit)).")
        }
        return .object(result)
    }

    private func entry(_ args: Arguments) async throws -> JSONValue {
        let (directory, policy) = try await open(args)
        guard let dn = try args.string("dn") else { throw ToolError("dn is required.") }
        try checkLength(dn, "dn")
        let attributes = try requestedAttributes(args, policy: policy)
        guard let entry = try await directory.entry(dn: dn, attributes: attributes,
                                                    includeOperational: try args.bool("include_operational")) else {
            throw ToolError("There's no entry \"\(dn)\", or this connection's bind isn't allowed to see it.")
        }
        return render(entry, policy: policy)
    }

    private func children(_ args: Arguments) async throws -> JSONValue {
        let (directory, policy) = try await open(args)
        let limit = try args.int("limit", default: Self.defaultChildLimit, in: 1...Self.maxChildLimit)
        let dn = try args.string("dn") ?? directory.connection.baseDN
        try checkLength(dn, "dn")

        // The tree's own attributes, minus any the user hid ("1.1" asks
        // for none at all — an empty list would mean every attribute).
        let visible = TreeRow.treeAttributes.filter { !policy.isHidden($0) }
        let attributes = visible.isEmpty ? ["1.1"] : visible
        func row(_ entry: LdapEntry) -> TreeRow {
            TreeRow(LdapEntry(dn: entry.dn, name: entry.name,
                              attributes: entry.attributes.filter { policy.isShown($0.name) }))
        }
        let showsObjectClasses = policy.isShown("objectClass")

        var rows: [TreeRow] = []
        var isComplete = true
        if dn.isEmpty {
            let dse = try await directory.entry(dn: "", attributes: ["namingContexts"])
            let contexts = dse?.values("namingContexts") ?? []
            for context in contexts.prefix(limit) {
                if let entry = try await directory.entry(dn: context, attributes: attributes) {
                    rows.append(row(entry))
                }
            }
            isComplete = contexts.count <= limit
        } else {
            let outcome = try await directory.search(LdapSearchRequest(
                baseDn: dn, scope: .oneLevel, attributes: attributes,
                limit: limit, pageSize: min(limit, 500)
            )) { page, _ in
                rows += page.map(row)
                return true
            }
            isComplete = outcome.isComplete
        }
        rows.sort { $0.sortKey < $1.sortKey }
        var result: [String: JSONValue] = [
            "connection": .string(directory.connection.name),
            "dn": .string(dn),
            "count": .int(rows.count),
            "complete": .bool(isComplete),
            "children": .array(rows.map { row in
                var child: [String: JSONValue] = [
                    "dn": .string(row.dn),
                    "has_children": .bool(row.mayHaveChildren),
                ]
                if showsObjectClasses { child["object_classes"] = JSONValue(row.objectClasses) }
                return .object(child)
            }),
        ]
        if !isComplete {
            result["note"] = .string("Only the first \(rows.count) children. Use search with a filter to find specific ones.")
        }
        return .object(result)
    }

    private func schema(_ args: Arguments) async throws -> JSONValue {
        let (directory, policy) = try await open(args)
        let schema: LdapSchema
        do { schema = try await directory.schema() } catch {
            throw ToolError("Couldn't read the schema: \(error)")
        }
        func named(_ name: String) -> (String) -> Bool {
            { $0.caseInsensitiveCompare(name) == .orderedSame }
        }

        if let name = try args.string("object_class") {
            guard let objectClass = schema.objectClasses.first(where: { $0.names.contains(where: named(name)) || $0.oid == name }) else {
                throw ToolError("The schema has no object class \"\(name)\".")
            }
            var chain: [String] = []
            var next = objectClass.superiorClasses
            while let superior = next.first, chain.count < 32 {
                next.removeFirst()
                guard !chain.contains(where: named(superior)) else { continue }
                chain.append(superior)
                next += schema.objectClasses.first { $0.names.contains(where: named(superior)) }?.superiorClasses ?? []
            }
            let all = schema.requiredAndOptionalAttributes(forObjectClasses: objectClass.names.prefix(1).map { $0 })
            return [
                "names": JSONValue(objectClass.names),
                "oid": .string(objectClass.oid),
                "description": JSONValue(objectClass.description),
                "kind": .string(objectClass.kind),
                "obsolete": .bool(objectClass.obsolete),
                "superior_classes": JSONValue(chain),
                "must": JSONValue(all.must),
                "may": JSONValue(all.may),
            ]
        }
        if let name = try args.string("attribute") {
            guard let type = schema.attributeTypes.first(where: { $0.names.contains(where: named(name)) || $0.oid == name }) else {
                throw ToolError("The schema has no attribute type \"\(name)\".")
            }
            var result: [String: JSONValue] = [
                "names": JSONValue(type.names),
                "oid": .string(type.oid),
                "description": JSONValue(type.description),
                "superior_type": JSONValue(type.superiorType),
                "syntax": JSONValue(type.syntaxOid),
                "equality": JSONValue(type.equalityMatchingRule),
                "ordering": JSONValue(type.orderingMatchingRule),
                "substring": JSONValue(type.substringMatchingRule),
                "single_valued": .bool(type.singleValued),
                "no_user_modification": .bool(type.noUserModification),
                "usage": JSONValue(type.usage),
                "obsolete": .bool(type.obsolete),
            ]
            if policy.isHidden(type.names.first ?? type.oid) {
                result["note"] = "LDAP Studio never returns this attribute's values to agents."
            }
            return .object(result)
        }
        let contains = try args.string("contains")
        func matching(_ names: [String]) -> [String] {
            names.filter { contains == nil || $0.localizedCaseInsensitiveContains(contains!) }
                .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        }
        return [
            "object_classes": JSONValue(matching(schema.objectClasses.compactMap(\.names.first))),
            "attributes": JSONValue(matching(schema.attributeTypes.compactMap(\.names.first))),
        ]
    }

    // MARK: Helpers

    /// The shared connection the call names, and what it may see. The
    /// schema is read (once per session) to resolve the attribute names an
    /// agent uses; a server that won't give it out still works, but its
    /// filters may only test objectClass (see MCPAttributePolicy).
    private func open(_ args: Arguments) async throws -> (ReadOnlyDirectory, MCPAttributePolicy) {
        guard let name = try args.string("connection"), !name.isEmpty else {
            throw ToolError("connection is required — call list_connections for the names.")
        }
        let shared = shared
        guard let connection = shared.first(where: { $0.name == name })
            ?? shared.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
            let names = shared.map { "\"\($0.name)\"" }.joined(separator: ", ")
            throw ToolError("No connection named \"\(name)\" is shared with agents. "
                + (names.isEmpty ? "None are: the user can share one in LDAP Studio → Settings → MCP Server."
                                 : "Shared connections: \(names)."))
        }
        let directory = ReadOnlyDirectory(connection)
        var schema: LdapSchema?
        if schemaFailures[connection].map({ ContinuousClock.now - $0 > Self.schemaRetryInterval }) ?? true {
            do {
                schema = try await directory.schema()
                schemaFailures[connection] = nil
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                schemaFailures[connection] = .now
            }
        }
        return (directory, MCPAttributePolicy(extraHidden: extraHidden(), schema: schema))
    }

    private func baseDN(_ requested: String?, of directory: ReadOnlyDirectory) throws -> String {
        let base = requested ?? directory.connection.baseDN
        try checkLength(base, "base_dn")
        guard !base.isEmpty else {
            throw ToolError("This connection has no base DN; pass base_dn (get_server_info lists the naming contexts).")
        }
        return base
    }

    private func requestedAttributes(_ args: Arguments, policy: MCPAttributePolicy) throws -> [String]? {
        guard let attributes = try args.strings("attributes"), !attributes.isEmpty else { return nil }
        guard attributes.count <= Self.maxRequestedAttributes else {
            throw ToolError("Ask for at most \(Self.maxRequestedAttributes) attributes.")
        }
        for attribute in attributes where !["*", "+", "1.1"].contains(attribute) {
            do { try policy.check(attribute) } catch { throw ToolError("\(error)") }
        }
        return attributes
    }

    private func checkLength(_ value: String, _ name: String) throws {
        guard value.utf8.count <= Self.maxInputLength else {
            throw ToolError("\(name) is too long (at most \(Self.maxInputLength) bytes).")
        }
    }

    /// One entry as the agent sees it: hidden attributes dropped (but
    /// named), binary values described rather than dumped, and long
    /// values and attributes cut short.
    /// Values that would take the entry past `maxResultBytes` are left
    /// out (and counted), so one entry with huge multi-valued attributes
    /// can't swamp the agent either.
    private enum Unresolved { case show, withhold }

    private func render(_ entry: LdapEntry, policy: MCPAttributePolicy,
                        unresolved: Unresolved = .withhold) -> JSONValue {
        var values: [String: [String]] = [:]
        var totals: [String: Int] = [:]
        var hidden: [String] = []
        var bytes = entry.dn.utf8.count + 128
        for attribute in entry.attributes {
            let shown = unresolved == .show ? !policy.isHidden(attribute.name) : policy.isShown(attribute.name)
            if !shown {
                if !hidden.contains(attribute.name) { hidden.append(attribute.name) }
                continue
            }
            totals[attribute.name, default: 0] += 1
            guard values[attribute.name, default: []].count < Self.maxValuesPerAttribute else { continue }
            let value = Self.displayValue(attribute)
            let cost = value.utf8.count + 4 + (values[attribute.name] == nil ? attribute.name.utf8.count + 8 : 0)
            guard bytes + cost <= Self.maxResultBytes else { continue }
            bytes += cost
            values[attribute.name, default: []].append(value)
        }
        var json: [String: JSONValue] = [
            "dn": .string(entry.dn),
            "attributes": .object(values.mapValues { JSONValue($0) }),
        ]
        let notShown = totals.reduce(into: [String: JSONValue]()) { result, item in
            let missing = item.value - (values[item.key]?.count ?? 0)
            if missing > 0 { result[item.key] = .int(missing) }
        }
        if !notShown.isEmpty {
            json["values_not_shown"] = .object(notShown)
        }
        if !hidden.isEmpty {
            json["hidden_attributes"] = JSONValue(hidden)
        }
        if !policy.knowsSchema, hidden.contains(where: { !policy.isHidden($0) }) {
            json["note"] = "LDAP Studio couldn't read this server's schema, so it can't tell which attributes are other names for hidden ones; only objectClass is shown."
        }
        return .object(json)
    }

    nonisolated static func displayValue(_ attribute: LdapAttribute) -> String {
        if attribute.isBinary {
            let bytes = Data(base64Encoded: attribute.value)?.count ?? attribute.value.count * 3 / 4
            return "(binary value, \(bytes) bytes — not shown)"
        }
        guard attribute.value.count > maxValueLength else { return attribute.value }
        return String(attribute.value.prefix(maxValueLength)) + "… (\(attribute.value.count - maxValueLength) more characters)"
    }

}

// MARK: - Support

/// A tool call's `arguments`, with type checking that tells the agent
/// what it got wrong.
private struct Arguments {
    let values: [String: JSONValue]
    init(_ values: [String: JSONValue]) { self.values = values }

    func string(_ key: String) throws -> String? {
        switch values[key] {
        case nil, .null?: return nil
        case let .string(value)?: return value
        default: throw MCPTools.ToolError("\(key) must be a string.")
        }
    }

    func strings(_ key: String) throws -> [String]? {
        switch values[key] {
        case nil, .null?: return nil
        case let .array(items)?:
            return try items.map {
                guard case let .string(value) = $0 else { throw MCPTools.ToolError("\(key) must be a list of strings.") }
                return value
            }
        default: throw MCPTools.ToolError("\(key) must be a list of strings.")
        }
    }

    func bool(_ key: String) throws -> Bool {
        switch values[key] {
        case nil, .null?: return false
        case let .bool(value)?: return value
        default: throw MCPTools.ToolError("\(key) must be true or false.")
        }
    }

    func int(_ key: String, default value: Int, in range: ClosedRange<Int>) throws -> Int {
        let number: Int
        switch values[key] {
        case nil, .null?: return value
        case let .int(given)?: number = given
        case let .double(given)? where given.rounded() == given && abs(given) < 1e9: number = Int(given)
        default: throw MCPTools.ToolError("\(key) must be a whole number.")
        }
        guard range.contains(number) else {
            throw MCPTools.ToolError("\(key) must be between \(range.lowerBound) and \(range.upperBound).")
        }
        return number
    }
}

/// Gathers rendered entries until they'd pass `MCPTools.maxResultBytes`.
private struct ResultCollector {
    private(set) var items: [JSONValue] = []
    private(set) var isFull = false
    private var bytes = 0

    /// False once full — the item wasn't added.
    mutating func add(_ item: JSONValue) -> Bool {
        let size = item.encoded().count + 1
        guard bytes + size <= MCPTools.maxResultBytes else {
            isFull = true
            return false
        }
        bytes += size
        items.append(item)
        return true
    }
}

/// Tool calls running at once, across every server the app has started
/// (one stopped mid-call still counts until its calls finish); the rest
/// wait their turn. Keeps agents that fire off many requests from taking
/// every pooled connection the app's own windows use.
@MainActor
final class MCPCallLimiter {
    static let shared = MCPCallLimiter(limit: 3)

    private let limit: Int
    private var running = 0
    private var waiting: [(id: UUID, continuation: CheckedContinuation<Void, Error>)] = []

    init(limit: Int) {
        self.limit = limit
    }

    /// Takes a slot, waiting for one if need be. Throws if the task is
    /// cancelled first; then there's nothing to release.
    func acquire() async throws {
        try Task.checkCancellation()
        if running < limit {
            running += 1
            return
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    self.waiting.append((id: id, continuation: continuation))
                }
            }
        } onCancel: {
            Task { @MainActor in self.giveUp(id) }
        }
    }

    /// Hands the slot straight to the next waiter, if there is one.
    func release() {
        if waiting.isEmpty {
            running -= 1
        } else {
            waiting.removeFirst().continuation.resume()
        }
    }

    private func giveUp(_ id: UUID) {
        guard let index = waiting.firstIndex(where: { $0.id == id }) else { return }
        waiting.remove(at: index).continuation.resume(throwing: CancellationError())
    }
}

nonisolated private struct TimeoutError: Error {}

/// Runs `work` and returns its result, or throws `TimeoutError` once
/// `limit` has passed (or `CancellationError` once the caller is
/// cancelled) — without waiting for `work` to notice it's been cancelled.
/// A blocking call into the C core can't be interrupted, so `work` may
/// finish some time later; its result is then dropped.
@MainActor
private func withTimeout<T: Sendable>(_ limit: Duration,
                                      _ work: @escaping @MainActor () async throws -> T) async throws -> T {
    let worker = Task { @MainActor in try await work() }
    let outcome = Outcome<T>()
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
            outcome.continuation = continuation
            let timer = Task { @MainActor in
                try await Task.sleep(for: limit)
                worker.cancel()
                outcome.finish(.failure(TimeoutError()))
            }
            Task { @MainActor in
                let result = await worker.result
                timer.cancel()
                outcome.finish(result)
            }
        }
    } onCancel: {
        worker.cancel()
        Task { @MainActor in outcome.finish(.failure(CancellationError())) }
    }
}

/// Resumes a continuation once — with whichever outcome comes first.
@MainActor
private final class Outcome<T: Sendable> {
    var continuation: CheckedContinuation<T, Error>?

    func finish(_ result: Result<T, Error>) {
        continuation?.resume(with: result)
        continuation = nil
    }
}
