//
//  BrowserView.swift
//  ldap-studio
//

import SwiftUI

struct BrowserView: View {
    @Environment(ConnectionStore.self) private var store

    /// Always the store's current copy (see LiveConnection), never a private
    /// one — so a setting edited in the Home window applies here, and a
    /// bookmark written back from here can't undo it. Changes made here go
    /// through `store.update` and arrive back in this property.
    let connection: SavedConnection

    init(connection: SavedConnection) {
        self.connection = connection
        _tree = State(initialValue: DirectoryTree(connection: connection))
        _operations = State(initialValue: BranchOperations(connection: connection))
        _searchOperations = State(initialValue: BranchOperations(connection: connection))
    }

    /// The lazily loaded directory tree — see DirectoryTree.swift.
    @State private var tree: DirectoryTree
    /// Delete / move / copy / export of whole branches; its progress and
    /// confirmations show over this whole window.
    @State private var operations: BranchOperations
    @State private var loadError: String?
    /// Bumped by every loadDirectory call, and when the settings change —
    /// see there and onChange(of: connectSettings).
    @State private var loadGeneration = 0
    /// Bumped to make the detail view re-read the selected entry.
    @State private var detailReloadToken = 0
    @State private var isShowingCertTrust = false
    /// An SSH host key seen for the first time, waiting on the user's say-so.
    @State private var pendingSSHHostKey: PendingSSHHostKey?

    private struct PendingSSHHostKey {
        let host: String
        let port: UInt16
        /// Hex SHA-256 of the key, as reported by the core.
        let fingerprint: String
    }
    @State private var selection: DirectoryEntry.ID?
    /// Fetched alongside the tree for attribute/object-class autocomplete —
    /// optional and non-blocking on purpose: if it fails to load (or the
    /// server doesn't expose a usable schema), autocomplete just has no
    /// suggestions rather than the whole browser failing to open.
    @State private var schema: LdapSchema?
    /// The search last opened as a table, kept while an entry is shown so
    /// its results are one click away.
    @State private var searchSession: SearchSession?
    @State private var isShowingSearch = false
    /// Export / move / delete of search results. Shown over the whole
    /// window, like `operations`, so a delete keeps its progress and Cancel
    /// when an entry is opened meanwhile — but it leaves the selection
    /// alone, where `operations` selects what it moved.
    @State private var searchOperations: BranchOperations

    private var endpoint: String { connection.endpoint }

    var body: some View {
        VStack(spacing: 0) {
            content
            OperationLogStrip(endpoint: endpoint)
        }
        .branchOperations(operations)
        .branchOperations(searchOperations)
        .onDisappear {
            tree.cancelAll()
            searchSession?.stop()
        }
        .onAppear {
            operations.onChange = { change in await apply(change) }
            searchOperations.onChange = { change in await apply(change) }
            operations.onSelect = { dn in
                Task {
                    _ = try? await tree.reveal(dn)
                    selection = tree.node(dn)?.dn ?? dn
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .ldapEntryDidChange)) { note in
            // A detached window (Edit Entry, …) wrote to this server —
            // re-read that entry so the tree and detail table reflect it.
            guard note.userInfo?["endpoint"] as? String == endpoint,
                  let dn = note.userInfo?["dn"] as? String else { return }
            Task { await apply(.modified(dn)) }
        }
    }

    @ViewBuilder
    private var content: some View {
        Group {
            if let loadError {
                ContentUnavailableView {
                    Label("Couldn't Load Directory", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(loadError)
                } actions: {
                    Button("Try Again") {
                        retry()
                    }
                }
            } else {
                // Up before the connection is: building the split view and
                // window chrome takes as long as connecting to a nearby
                // server, so it's done while waiting rather than after.
                NavigationSplitView {
                    if tree.root == nil {
                        ProgressView("Connecting to \(connection.host)…")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .navigationSplitViewColumnWidth(min: 200, ideal: 260)
                    } else {
                        treeView
                    }
                } detail: {
                    detail
                }
            }
        }
        .frame(minWidth: 700, minHeight: 420)
        .navigationTitle("Ldap Studio - \(connection.name)\(connection.isReadOnly ? "  (Read-Only)" : "")")
        .task {
            await loadDirectory()
        }
        .onChange(of: connectSettings) {
            // Edited in the Home window, or a certificate / host key was just
            // trusted here. Whatever is on screen came from the old settings
            // (or failed with them), so take it down rather than leave it up
            // and usable while connecting with the new ones. That includes a
            // trust prompt still open for the old server — the new load
            // raises a fresh one if it's still needed. A password-only edit
            // doesn't land here (the password lives in the Keychain, not the
            // connection) — Try Again picks that up.
            //
            // Bumping the generation here, not just in the Task's load, also
            // drops an old load whose result is already queued to run before
            // that Task starts — it would otherwise put the old server's
            // tree, error or trust prompt straight back.
            loadGeneration += 1
            // A fresh tree: the old one's nodes came from the old server, and
            // its base DN is fixed when it's made.
            tree.cancelAll()
            tree = DirectoryTree(connection: connection)
            schema = nil
            operations.schema = nil
            searchOperations.schema = nil
            searchSession?.stop()
            searchSession = nil
            isShowingSearch = false
            loadError = nil
            isShowingCertTrust = false
            pendingSSHHostKey = nil
            Task { await reload(selecting: selection) }
        }
        .onChange(of: selection) {
            // An entry picked in the tree or the search field is shown in
            // place of the table.
            isShowingSearch = false
        }
        .onChange(of: connection) {
            // Every edit, connect settings or not — branch operations check
            // `isReadOnly`, for one.
            tree.connection = connection
            operations.connection = connection
            searchOperations.connection = connection
        }
        .sheet(isPresented: $isShowingCertTrust) {
            CertificateTrustSheet(
                host: connection.host,
                port: UInt16(clamping: connection.port),
                useSSL: connection.useSSL,
                useStartTLS: connection.useStartTLS
            ) { sha256 in
                var updated = connection
                updated.trustedCertSHA256 = sha256
                // Reconnects through onChange(of: connectSettings) — retrying
                // right here would still see the connection without the pin.
                if !store.update(updated) {
                    loadError = "This connection has been deleted, so the certificate couldn't be trusted."
                }
            }
        }
        .alert(
            "Trust SSH Host Key?",
            isPresented: Binding(
                get: { pendingSSHHostKey != nil },
                set: { if !$0 { pendingSSHHostKey = nil } }
            ),
            presenting: pendingSSHHostKey
        ) { pending in
            Button("Trust and Connect") {
                pendingSSHHostKey = nil
                var updated = connection
                updated.sshHostKeySHA256 = pending.fingerprint
                // Reconnects through onChange(of: connectSettings).
                if !store.update(updated) {
                    loadError = "This connection has been deleted, so the SSH host key couldn't be trusted."
                }
            }
            Button("Cancel", role: .cancel) {
                pendingSSHHostKey = nil
                loadError = "The SSH host key for \(pending.host):\(pending.port) wasn't trusted, so no connection was made."
            }
        } message: { pending in
            Text("""
                LDAP Studio hasn't connected through \(pending.host):\(pending.port) before. \
                Check this fingerprint against the server's own (for example with \
                `ssh-keygen -lf` on its host key) before trusting it:

                \(SSHHostKeyFingerprint.openSSH(fromHex: pending.fingerprint))
                """)
        }
    }

    private var treeView: some View {
        DirectoryTreeView(
            tree: tree,
            selection: $selection,
            connection: connection,
            schema: schema,
            bookmarks: connection.bookmarks,
            onToggleBookmark: toggleBookmark,
            onEditSavedSearches: editSavedSearches,
            onOpenSearch: openSearch,
            operations: operations,
            onChange: { change in await apply(change) },
            onRefreshDetail: { detailReloadToken += 1 }
        )
        .navigationSplitViewColumnWidth(min: 200, ideal: 260)
    }

    @ViewBuilder
    private var detail: some View {
        if isShowingSearch, let searchSession, tree.root != nil {
            SearchResultsView(
                session: searchSession,
                connection: connection,
                tree: tree,
                schema: schema,
                selectedDN: selection,
                operations: searchOperations,
                onOpen: { dn in openFromSearch(dn) },
                onClose: { isShowingSearch = false },
                onEditSavedSearches: editSavedSearches
            )
            .id(ObjectIdentifier(searchSession))
        } else {
            VStack(spacing: 0) {
                if let searchSession, tree.root != nil {
                    backToResultsBar(searchSession)
                }
                entryDetail
            }
        }
    }

    private func backToResultsBar(_ session: SearchSession) -> some View {
        HStack(spacing: 8) {
            Button {
                isShowingSearch = true
            } label: {
                Label("Back to Search Results", systemImage: "chevron.left")
            }
            .buttonStyle(.borderless)
            Text(session.query.summary)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Button {
                session.stop()
                searchSession = nil
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("Close the Search")
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    @ViewBuilder
    private var entryDetail: some View {
        // Not while (re)connecting: a selection kept across a settings
        // change may not exist on the server being connected to.
        if let selection, tree.root != nil {
            EntryDetailLoader(
                dn: selection,
                reloadToken: detailReloadToken,
                tree: tree,
                connection: connection,
                schema: schema,
                operations: operations,
                isBookmarked: connection.bookmarks.contains { DN.same($0, selection) },
                onToggleBookmark: { toggleBookmark(selection) },
                onChange: { change in await apply(change) }
            )
        } else {
            ContentUnavailableView(
                "No Selection",
                systemImage: "sidebar.left",
                description: Text("Select an entry from the tree to view its attributes.")
            )
        }
    }

    /// Opens `query` as a table in the detail view, running it straight
    /// away unless it's blank (which would list the whole directory).
    private func openSearch(_ query: SearchQuery) {
        searchSession?.stop()
        let session = SearchSession(query: query, directoryBaseDN: tree.baseDN)
        searchSession = session
        isShowingSearch = true
        if query != SearchQuery(baseDN: query.baseDN),
           let filter = session.run(target: connection.ldapTarget, schema: schema) {
            editSavedSearches { SavedSearches.recording(query, filter: filter, in: $0) }
        }
    }

    /// Shows a result: in the tree, and its attributes in place of the
    /// table — which stays a click away.
    private func openFromSearch(_ dn: String) {
        isShowingSearch = false
        Task {
            let found = try? await tree.reveal(dn)
            selection = found ?? tree.node(dn)?.dn ?? dn
        }
    }

    private func retry() {
        loadError = nil
        Task {
            await loadDirectory()
        }
    }

    /// Everything about the connection that shapes how it connects. Built by
    /// blanking out what's only bookkeeping, so a field added later counts
    /// as a connection setting by default.
    private var connectSettings: SavedConnection {
        var settings = connection
        settings.name = ""
        settings.bookmarks = []
        settings.savedFilters = []
        settings.isFavorite = false
        settings.isReadOnly = false
        return settings
    }

    /// Pin or unpin `dn` in this connection's bookmark list, then persist.
    private func toggleBookmark(_ dn: String) {
        var updated = connection
        if let index = updated.bookmarks.firstIndex(where: { DN.same($0, dn) }) {
            updated.bookmarks.remove(at: index)
        } else {
            updated.bookmarks.insert(dn, at: 0)
        }
        store.update(updated)
    }

    /// Changes this connection's saved and recent searches, starting from
    /// the store's current list rather than one a view may have kept.
    private func editSavedSearches(_ edit: ([SavedLDAPFilter]) -> [SavedLDAPFilter]) {
        var updated = store.latest(connection)
        updated.savedFilters = edit(updated.savedFilters)
        store.update(updated)
    }

    /// Opens the tree — the base entry and its direct children, nothing
    /// more — with the schema (for autocomplete) loading alongside.
    private func loadDirectory() async {
        // The store's copy rather than `self.connection`, so a load always
        // uses the current settings.
        let connection = store.latest(connection)
        // Loads can overlap — settings edited mid-connect, Try Again — and
        // the core runs them one at a time, so an older one can finish
        // last. Only the newest may change the screen.
        loadGeneration += 1
        let generation = loadGeneration
        // This load's tree: a settings change swaps in a new one meanwhile.
        let tree = self.tree
        tree.connection = connection
        let target = connection.ldapTarget
        // Run together rather than one after the other — the schema fetch
        // is a nice-to-have for autocomplete, not something worth making
        // the user wait an extra round trip for.
        async let schemaTask: LdapSchema? = try? await fetchSchema(target)
        await tree.loadRoot()

        guard generation == loadGeneration else { return }
        if let error = tree.rootError {
            showLoadFailure(error, for: connection)
            return
        }
        let loadedSchema = await schemaTask
        guard generation == loadGeneration else { return }
        schema = loadedSchema
        operations.schema = loadedSchema
        searchOperations.schema = loadedSchema
        loadError = nil
    }

    /// What a failed load leaves on screen: the error, plus a prompt to
    /// trust the certificate / SSH host key when it's a first sighting.
    private func showLoadFailure(_ error: Error, for connection: SavedConnection) {
        guard let error = error as? ConnectionError else {
            loadError = "\(error)"
            return
        }
        if case let .TLSUntrusted(host, port, _) = error, connection.trustedCertSHA256 == nil {
            // An untrusted certificate isn't a dead end — offer to inspect
            // and pin it. The error underneath is what's left if the user
            // cancels. Anything already pinned that still fails is a real
            // problem, so that's shown plainly below.
            loadError = "The certificate for \(host):\(port) isn't trusted, so no connection was made."
            isShowingCertTrust = true
        } else if case let .TLSUntrusted(host, port, _) = error {
            // With a pin set the core only reports TLSUntrusted when the
            // fingerprint doesn't match. Like a changed SSH host key, that
            // is never a one-click decision — but say where to go, since
            // the fix lives in another window. Over an SSH tunnel nothing
            // but the pin checks the certificate (it can't match the host
            // name of the local forward), so say what clearing it gives up.
            let afterClearing = connection.useSSHTunnel
                ? "This window will then reconnect, but through the SSH tunnel the certificate can't be checked against the host name, so it will accept whatever certificate the server presents."
                : "This window will then reconnect, and if the system doesn't trust the new certificate, it will show it to you to check first."
            loadError = """
                The certificate for \(host):\(port) no longer matches the one you trusted.

                This usually means the certificate was renewed, or that the host name points at \
                several servers (an Active Directory domain name, for example) and a different one \
                answered. It can also mean someone is intercepting the connection. If you know the \
                change is legitimate, clear the trusted certificate under Edit Connection › Network \
                and save. \(afterClearing)
                """
        } else if case let .SSHHostKeyUntrusted(host, port, fingerprint) = error {
            if connection.sshHostKeySHA256 == nil {
                pendingSSHHostKey = PendingSSHHostKey(host: host, port: port, fingerprint: fingerprint)
            } else {
                // A key we already trusted no longer matches. Unlike a
                // first sighting, that is never a one-click decision —
                // it can mean the connection is being intercepted.
                loadError = """
                    The SSH host key for \(host):\(port) has changed since you trusted it.

                    It is now \(SSHHostKeyFingerprint.openSSH(fromHex: fingerprint)).

                    This can mean the server was rebuilt, or that someone is intercepting the connection. \
                    If you know the change is legitimate, clear the trusted host key under Edit Connection \
                    › SSH Tunnel and save. This window will then reconnect and ask you to check the new key.
                    """
            }
        } else {
            loadError = "\(error)"
        }
    }

    /// Brings the tree and the detail view up to date after a write,
    /// touching only the entries it affected.
    private func apply(_ change: DirectoryChange) async {
        await searchSession?.apply(change)
        switch change {
        case let .added(dn):
            await tree.entryAdded(dn)
        case let .removed(dn):
            tree.entryRemoved(dn)
            if let selected = selection, DN.isWithin(selected, dn) { selection = nil }
        case let .moved(from, to):
            await tree.entryMoved(from: from, to: to)
            if let selected = selection, DN.isWithin(selected, from) {
                let moved = DN.rebase(selected, from: from, to: to)
                // The server's spelling, so it matches the tree row's tag.
                selection = tree.node(moved)?.dn ?? moved
            }
        case let .modified(dn):
            await tree.entryModified(dn)
            if let selected = selection, DN.same(selected, dn) { detailReloadToken += 1 }
        case let .branchChanged(dn):
            await tree.branchChanged(dn)
            if let selected = selection, DN.isWithin(selected, dn) { detailReloadToken += 1 }
        }
    }

    /// Reconnects, keeping `dn` selected if the new tree can reach it.
    private func reload(selecting dn: String?) async {
        await loadDirectory()
        if let dn, let found = try? await tree.reveal(dn) {
            selection = found
        } else {
            selection = nil
        }
    }
}

/// The Operation Log's summary line under the browser, expanding into the
/// full log. A view of its own so that only it redraws as operations are
/// logged — every search adds a row, and the browser around it shouldn't
/// be rebuilt each time.
private struct OperationLogStrip: View {
    let endpoint: String

    @State private var isExpanded = false
    private let operationLog = OperationLog.shared

    var body: some View {
        let mine = operationLog.entries.filter { $0.endpoint == endpoint }
        return VStack(spacing: 0) {
            Divider()

            Button {
                withAnimation(.easeOut(duration: 0.15)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .foregroundStyle(.secondary)
                    Image(systemName: "list.bullet.rectangle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Operation Log")
                        .font(.caption.weight(.semibold))
                    if !mine.isEmpty {
                        Text("\(mine.count)")
                            .font(.caption2.weight(.medium).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                    }
                    if let last = mine.last {
                        Text("·").foregroundStyle(.tertiary)
                        Text(last.summary)
                            .foregroundStyle(last.outcome.isOK ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.red))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 8)
                    Text("⇧⌘Y")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .font(.caption)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut("y", modifiers: [.command, .shift])

            if isExpanded {
                Divider()
                OperationLogPanel(endpoint: endpoint)
                    .frame(height: 220)
            }
        }
        .background(.bar)
    }
}

#Preview {
    BrowserView(connection: SavedConnection(name: "Corp Directory", host: "ldap.corp.example.com", port: 389, useSSL: false, baseDN: "dc=corp,dc=example,dc=com", bindDN: ""))
        .environment(ConnectionStore())
}
