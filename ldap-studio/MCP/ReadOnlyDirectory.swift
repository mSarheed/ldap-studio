//
//  ReadOnlyDirectory.swift
//  ldap-studio
//
//  The only way the MCP server reaches a directory. Every write in the
//  core (`addEntry`, `modifyEntry`, `renameEntry`, `deleteEntry`) takes an
//  `LdapTarget`; this keeps the target private and offers searches, entry
//  reads and the schema only, so nothing an agent asks for can be turned
//  into a write — there's no target in the MCP code to pass to one. Kept
//  in its own file so `private` really does hide it from the rest.
//

import Foundation

struct ReadOnlyDirectory {
    let connection: SavedConnection
    private let target: LdapTarget

    init(_ connection: SavedConnection) {
        self.connection = connection
        target = connection.ldapTarget
    }

    @discardableResult
    func search(_ request: LdapSearchRequest,
                onPage: ([LdapEntry], LdapSearchProgress) async throws -> Bool) async throws -> LdapSearchOutcome {
        try await pagedSearch(target, request, onPage: onPage)
    }

    func entry(dn: String, attributes: [String]? = nil,
               includeOperational: Bool = false) async throws -> LdapEntry? {
        try await fetchEntry(target, dn: dn, attributes: attributes,
                             includeOperational: includeOperational)
    }

    /// The copy read earlier this session if there is one — a directory's
    /// schema hardly ever changes, and it's large.
    func schema() async throws -> LdapSchema {
        if let schema = cachedSchema(target) { return schema }
        return try await fetchSchema(target)
    }
}
