//
//  SearchSession.swift
//  ldap-studio
//

import Foundation
import Observation

/// A search opened in the results table: the query being edited, and the
/// results of the last time it ran. Lives in `BrowserView`, so going to an
/// entry and back keeps both. Results are read with paged searches, so
/// every match comes back however many there are; a long search shows its
/// progress and can be stopped.
@Observable
final class SearchSession {
    /// One match — just enough to list it; anything else is read when used.
    struct Hit: Identifiable, Hashable {
        let dn: String
        let icon: String
        let name: String
        /// The first value of each column's attribute, keyed lowercased.
        let values: [String: String]
        var id: String { dn }
    }

    var query: SearchQuery
    /// The conditions "Edit as Text" turned into the filter being edited,
    /// so "Show as Conditions" can bring them back while it's unchanged —
    /// a name search or an entry type isn't a plain list of conditions.
    @ObservationIgnored var textEditOrigin: (query: SearchQuery, filter: String)?
    /// The connection's base DN — where "Whole Directory" searches from.
    let directoryBaseDN: String
    var selection: Set<String> = []

    /// The matches the table draws — the first `displayLimit` of them.
    private(set) var results: [Hit] = []
    private(set) var totalFound = 0
    private(set) var foundSoFar = 0
    private(set) var isSearching = false
    private(set) var hasSearched = false
    private(set) var wasCancelled = false
    /// The server cut the results short (it ignored paging).
    private(set) var wasTruncated = false
    private(set) var errorMessage: String?
    /// The request the current results came from — what Export re-runs.
    private(set) var lastRequest: LdapSearchRequest?
    /// The attributes shown as columns, read along with the results.
    private(set) var columns: [String] = []

    static let displayStep = 5_000
    private var displayLimit = SearchSession.displayStep
    /// Every match, kept out of SwiftUI's sight: re-diffing a table of
    /// 100,000 rows on each page would slow the search to a crawl.
    @ObservationIgnored private var store = HitStore()
    @ObservationIgnored private var task: Task<Void, Never>?
    /// Bumped by each run, so a stopped search finishing late can't touch
    /// the state of the one that replaced it.
    @ObservationIgnored private var generation = 0

    init(query: SearchQuery, directoryBaseDN: String) {
        self.query = query
        self.directoryBaseDN = directoryBaseDN
    }

    var baseDN: String { query.baseDN ?? directoryBaseDN }

    /// Starts the search, replacing any that's running. Returns the filter
    /// it sent, or nil when the query isn't complete.
    @discardableResult
    func run(target: LdapTarget, schema: LdapSchema?) -> String? {
        guard let filter = query.filter(schema: schema), !filter.isEmpty else { return nil }
        task?.cancel()
        generation += 1
        let generation = generation

        let columns = Array(query.mentionedAttributes.prefix(4))
        var attributes = ["objectClass", "univentionObjectType", "cn", "displayName"]
        for column in columns where !attributes.contains(where: { $0.caseInsensitiveCompare(column) == .orderedSame }) {
            attributes.append(column)
        }
        // The user started this one and can stop it, so it waits on a slow
        // server as long as it takes (exporting the results re-runs it the
        // same way).
        let request = LdapSearchRequest(baseDn: baseDN, scope: query.depth.scope, filter: filter,
                                        attributes: attributes, idleTimeout: 0)
        self.columns = columns
        errorMessage = nil
        wasCancelled = false
        wasTruncated = false
        selection.removeAll()
        store.hits = []
        results = []
        totalFound = 0
        foundSoFar = 0
        displayLimit = Self.displayStep
        isSearching = true

        task = Task {
            var lastShown = ContinuousClock.now
            var outcomeRequest: LdapSearchRequest?
            var error: String?
            var cancelled = false
            var truncated = false
            do {
                let outcome = try await pagedSearch(target, request) { page, progress in
                    guard generation == self.generation else { return false }
                    store.hits += page.map { Self.hit(from: $0, columns: columns) }
                    // Each update redraws the view; a few a second is plenty.
                    if ContinuousClock.now - lastShown > .milliseconds(250) {
                        foundSoFar = progress.entries
                        lastShown = .now
                    }
                    // Only the first rows are drawn, so later pages don't
                    // touch the table at all.
                    if results.count < displayLimit {
                        results = Array(store.hits.prefix(displayLimit))
                    }
                    return true
                }
                truncated = outcome.wasTruncated
                outcomeRequest = request
            } catch is CancellationError {
                cancelled = true
                outcomeRequest = request
            } catch let failure {
                error = "\(failure)"
            }
            guard generation == self.generation else { return }
            wasTruncated = truncated
            wasCancelled = cancelled
            errorMessage = error
            lastRequest = outcomeRequest
            results = Array(store.hits.prefix(displayLimit))
            totalFound = store.hits.count
            foundSoFar = totalFound
            isSearching = false
            hasSearched = true
            task = nil
        }
        return filter
    }

    func stop() {
        task?.cancel()
    }

    func showMore() {
        displayLimit += Self.displayStep
        results = Array(store.hits.prefix(displayLimit))
    }

    private static func hit(from entry: LdapEntry, columns: [String]) -> Hit {
        let icon = DirectoryEntry.icon(forObjectClasses: entry.values("objectClass"),
                                       univentionType: entry.values("univentionObjectType").first,
                                       hasChildren: false)
        var values: [String: String] = [:]
        for column in columns {
            let all = entry.values(column)
            guard let first = all.first else { continue }
            values[column.lowercased()] = all.count > 1 ? "\(first) (+\(all.count - 1))" : first
        }
        return Hit(dn: entry.dn, icon: icon, name: displayName(of: entry), values: values)
    }

    /// displayName or cn when there is one, else the RDN's value.
    nonisolated static func displayName(of entry: LdapEntry) -> String {
        if let name = entry.values("displayName").first ?? entry.values("cn").first, !name.isEmpty {
            return name
        }
        let rdn = DN.rdn(of: entry.dn)
        guard let equals = rdn.firstIndex(of: "=") else { return rdn }
        return String(rdn[rdn.index(after: equals)...])
    }

    /// Keeps the results honest after a delete or move. Keys are worked
    /// out off the main actor, once per search, so deleting or moving many
    /// results doesn't re-normalize 100,000 DNs on the main thread for
    /// each one.
    func apply(_ change: DirectoryChange) async {
        let ancestor: String
        switch change {
        case let .removed(dn): ancestor = dn
        case let .moved(from, _): ancestor = from
        case .added, .modified, .branchChanged: return
        }
        let ancestorKey = DN.normalize(ancestor)
        let generation = generation
        let keys = await store.keys()
        // A search started meanwhile replaced the hits these keys are for.
        guard generation == self.generation, keys.count == store.hits.count else { return }
        let affected = Set(keys.indices.filter { DN.keyIsWithin(keys[$0], ancestorKey) })
        guard !affected.isEmpty else { return }
        switch change {
        case .removed:
            store.remove(at: affected)
            selection = selection.filter { !DN.isWithin($0, ancestor) }
        case let .moved(from, to):
            store.replace(at: affected) { hit in
                Hit(dn: DN.rebase(hit.dn, from: from, to: to), icon: hit.icon, name: hit.name, values: hit.values)
            }
            selection.removeAll()
        default:
            return
        }
        results = Array(store.hits.prefix(displayLimit))
        totalFound = store.hits.count
    }
}

/// See `SearchSession.store`.
private final class HitStore {
    var hits: [SearchSession.Hit] = [] {
        didSet { cachedKeys = nil }
    }
    /// `DN.normalize` of each hit, worked out when first needed.
    private var cachedKeys: [String]?

    func keys() async -> [String] {
        if let cachedKeys, cachedKeys.count == hits.count { return cachedKeys }
        let dns = hits.map(\.dn)
        let keys = await Task.detached(priority: .userInitiated) { dns.map(DN.normalize) }.value
        cachedKeys = keys
        return keys
    }

    func remove(at indices: Set<Int>) {
        let keys = cachedKeys
        hits = hits.indices.filter { !indices.contains($0) }.map { hits[$0] }
        cachedKeys = keys.map { k in k.indices.filter { !indices.contains($0) }.map { k[$0] } }
    }

    func replace(at indices: Set<Int>, with transform: (SearchSession.Hit) -> SearchSession.Hit) {
        var keys = cachedKeys
        var updated = hits
        for i in indices {
            updated[i] = transform(updated[i])
            keys?[i] = DN.normalize(updated[i].dn)
        }
        hits = updated
        cachedKeys = keys
    }
}
