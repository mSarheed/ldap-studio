//
//  DirectoryTreeView.swift
//  ldap-studio
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct DirectoryTreeView: View {
    let tree: DirectoryTree
    @Binding var selection: DirectoryEntry.ID?
    let connection: SavedConnection
    /// Optional — feeds the attribute/object-class autocomplete in New
    /// Entry and the quick search; nil just means no help, never a blocker.
    let schema: LdapSchema?
    /// This connection's pinned DNs, and the callback to add/remove one.
    /// `BrowserView` owns the list and persists it.
    let bookmarks: [String]
    let onToggleBookmark: (String) -> Void
    let onEditSavedSearches: (([SavedLDAPFilter]) -> [SavedLDAPFilter]) -> Void
    /// Opens a search as a table in the detail view.
    let onOpenSearch: (SearchQuery) -> Void
    /// The detail view shows search results rather than the selected entry,
    /// so menu commands for the selected entry are off.
    let isShowingSearchResults: Bool
    /// Shows the selected entry in place of search results — for when it's
    /// picked again while already selected, which changes no selection.
    let onShowEntry: () -> Void
    /// Branch-level delete / move / copy / export, shared with the detail
    /// view; `BrowserView` shows its progress and confirmations.
    let operations: BranchOperations
    /// Tells `BrowserView` what a write changed, so the tree and the
    /// detail view update in place.
    let onChange: (DirectoryChange) async -> Void
    /// Re-reads the selected entry's attributes in the detail view.
    let onRefreshDetail: () -> Void
    @Environment(\.openWindow) private var openWindow

    private struct PickerRequest: Identifiable {
        enum Kind { case move, copy }
        let kind: Kind
        let dn: String
        var id: String { "\(kind)-\(dn)" }
    }

    private struct NewEntryRequest: Identifiable {
        let parentDN: String
        var id: String { parentDN }
    }

    @State private var pickerRequest: PickerRequest?
    @State private var newEntryRequest: NewEntryRequest?
    @State private var groupForMembersEditing: DirectoryEntry?
    @State private var entryForRename: DirectoryEntry?
    @State private var entryForPasswordSet: DirectoryEntry?
    @State private var entryForTestBind: DirectoryEntry?

    @State private var isPerformingAction = false
    @State private var actionError: String?

    @State private var isShowingGoTo = false
    @State private var goToText = ""
    @State private var goToError: String?
    @State private var isRevealing = false
    @FocusState private var goToFieldFocused: Bool

    @State private var treeSelection: Set<DirectoryEntry.ID> = []
    /// Set while the list's selection is changed from here rather than by a
    /// click, so the change isn't taken as the user picking a row.
    @State private var isSettingTreeSelection = false
    /// What every row needs besides its node. One stable object, so a
    /// selection change doesn't make SwiftUI re-evaluate thousands of rows.
    @State private var rowContext = TreeRowContext()

    // The search field. While it's in use, the sidebar shows the search
    // (see QuickSearchPanel) in place of the tree; Esc goes back.
    @State private var searchText = ""
    @State private var searchKind: EntryKind = .all
    @State private var searchBaseDN: String?
    @State private var isSearchMode = false
    @State private var searchResultsFocusRequest = 0
    @FocusState private var isSearchFieldFocused: Bool

    private var actions: EntryActions {
        EntryActions(connection: connection, schema: schema)
    }

    private var selectedNode: TreeNode? {
        guard treeSelection.count <= 1, let selection else { return nil }
        return tree.node(selection)
    }

    private var selectedDNs: [String] {
        Array(treeSelection)
    }

    private var bookmarkSet: Set<String> { Set(bookmarks.map(DN.normalize)) }

    private var isReadOnly: Bool { connection.isReadOnly }

    var body: some View {
        VStack(spacing: 0) {
            toolbar

            searchField

            Divider()

            if isSearchMode {
                QuickSearchPanel(
                    text: $searchText,
                    kind: $searchKind,
                    baseDN: $searchBaseDN,
                    selection: $selection,
                    onShowEntry: onShowEntry,
                    isShowingSearchResults: isShowingSearchResults,
                    focusRequest: searchResultsFocusRequest,
                    tree: tree,
                    connection: connection,
                    schema: schema,
                    onReveal: { dn in
                        endSearch()
                        reveal(dn)
                    },
                    onOpenTable: { query in
                        endSearch()
                        onOpenSearch(query)
                    },
                    onEditSavedSearches: onEditSavedSearches
                )
                // Esc from the results as well as from the field.
                .onExitCommand { endSearch() }
            } else {
                treeList
            }
        }
        .disabled(isPerformingAction)
        .overlay {
            if isPerformingAction {
                ZStack {
                    Color.black.opacity(0.08)
                    ProgressView("Updating Directory…")
                        .padding(16)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                }
            }
        }
        .sheet(item: $pickerRequest) { request in
            let isMove = request.kind == .move
            DestinationPickerSheet(
                tree: tree,
                excluding: [request.dn],
                title: "\(isMove ? "Move" : "Copy") \(DN.rdn(of: request.dn)) To",
                confirmLabel: isMove ? "Move" : "Copy"
            ) { destinationDN in
                if isMove {
                    operations.requestMove([request.dn], to: destinationDN)
                } else {
                    operations.requestCopy(request.dn, to: destinationDN)
                }
            }
        }
        .alert(
            "Action Failed",
            isPresented: Binding(
                get: { actionError != nil },
                set: { if !$0 { actionError = nil } }
            ),
            presenting: actionError
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { message in
            Text(message)
        }
        .sheet(item: $newEntryRequest) { request in
            NewEntrySheet(parentDN: request.parentDN, schema: schema) { dn, attributes in
                createEntry(dn: dn, attributes: attributes)
            }
        }
        .sheet(item: $groupForMembersEditing) { group in
            GroupMembersSheet(group: group, connection: connection) {
                await onChange(.modified(group.dn))
            }
        }
        .sheet(item: $entryForRename) { entry in
            RenameEntrySheet(entry: entry) { newRDN in
                rename(entry.dn, to: newRDN)
            }
        }
        .sheet(item: $entryForPasswordSet) { entry in
            SetPasswordSheet { plaintext, scheme in
                setPassword(plaintext, scheme: scheme, for: entry.dn)
            }
        }
        .sheet(item: $entryForTestBind) { entry in
            TestBindSheet(connection: connection, dn: entry.dn)
        }
        .focusedSceneValue(\.directoryCommands, isShowingSearchResults ? directoryCommands.withoutSelection : directoryCommands)
    }

    private var directoryCommands: DirectoryCommands {
        DirectoryCommands(
            newEntry: { newEntryRequest = NewEntryRequest(parentDN: selection ?? tree.baseDN) },
            importLDIF: { importLDIF() },
            openSchema: { openWindow(id: "schema", value: connection) },
            openLDIFEditor: { openWindow(id: "ldif", value: connection) },
            openServerInfo: { openWindow(id: "serverInfo", value: connection) },
            find: { beginSearch() },
            advancedSearch: { openSearchWithConditions() },
            goToDN: { openGoTo() },
            reloadTree: { reloadTree() },
            toggleBookmark: selection.map { dn in { onToggleBookmark(dn) } },
            isSelectedBookmarked: selection.map { bookmarkSet.contains(DN.normalize($0)) } ?? false,
            isReadOnly: isReadOnly,
            editEntry: selection.map { dn in
                { openWindow(id: "editEntry", value: EditEntryRequest(connection: connection, dn: dn)) }
            },
            refreshSelected: selection.map { dn in { refresh(dn) } },
            renameSelected: (selectedNode != nil && !isReadOnly)
                ? { if let node = selectedNode { entryForRename = node.summaryEntry } } : nil,
            copyDN: selection.map { dn in { copyToPasteboard(dn) } },
            copySelectedLDIF: treeSelection.isEmpty ? nil : { copyLDIF(selectedDNs) },
            exportSelected: treeSelection.isEmpty ? nil : { exportLDIF(selectedDNs) },
            setPassword: selectedNode.flatMap { node in
                (!isReadOnly && canSet("userPassword", on: node)) ? { entryForPasswordSet = node.summaryEntry } : nil
            },
            setPhoto: selectedNode.flatMap { node in
                (!isReadOnly && canSet("jpegPhoto", on: node)) ? { setPhoto(for: node.dn) } : nil
            },
            testBind: selectedNode.flatMap { node in
                canBind(as: node) ? { entryForTestBind = node.summaryEntry } : nil
            },
            deleteSelected: (!treeSelection.isEmpty && !isReadOnly)
                ? { operations.requestDelete(selectedDNs) } : nil,
            editMembers: selectedNode.flatMap { node in
                (!isReadOnly && GroupMembersSheet.isGroup(node.summaryEntry))
                    ? { groupForMembersEditing = node.summaryEntry } : nil
            }
        )
    }

    // MARK: - Tree

    private var treeList: some View {
        ScrollViewReader { proxy in
            List(selection: $treeSelection) {
                if let root = tree.root {
                    TreeNodeRow(node: root, tree: tree, context: rowContext)
                }
            }
            .contextMenu(forSelectionType: DirectoryEntry.ID.self) { ids in
                let nodes = ids.compactMap { tree.node($0) }
                if nodes.count > 1 {
                    bulkContextMenuContent(nodes)
                } else if let node = nodes.first {
                    contextMenuContent(for: node)
                }
            }
            .onChange(of: treeSelection) { oldValue, newValue in
                rowContext.selection = newValue
                if isSettingTreeSelection {
                    isSettingTreeSelection = false
                    return
                }
                // Marked as a click only when the list is what changes the
                // selection — not when it's echoing one made elsewhere.
                if let added = newValue.subtracting(oldValue).first {
                    if added != selection { rowContext.pickedInList = added }
                    selection = added
                    // Shown in place of search results even when it was
                    // already the selected entry.
                    onShowEntry()
                } else if let selection, !newValue.contains(selection) {
                    rowContext.pickedInList = newValue.first
                    self.selection = newValue.first
                } else if newValue.isEmpty {
                    rowContext.pickedInList = nil
                    selection = nil
                }
            }
            .onChange(of: selection) { _, newValue in
                guard let newValue else {
                    rowContext.pickedInList = nil
                    treeSelection.removeAll()
                    return
                }
                // A row clicked (or arrowed to) is already on screen; only a
                // selection made elsewhere — Go to DN, a search result, a
                // bookmark — needs selecting in the list and scrolling to.
                // Animating that scroll on every click also cost more than
                // the rest of the click put together. The mark is for this
                // change only, so it can't stop a later one being scrolled to.
                let isClick = newValue == rowContext.pickedInList
                rowContext.pickedInList = nil
                guard !isClick else { return }
                // Not while the table is up: it stands in for the entry.
                if !isShowingSearchResults, tree.node(newValue) != nil {
                    setTreeSelection([newValue])
                }
                withAnimation {
                    proxy.scrollTo(newValue, anchor: .center)
                }
            }
            .onAppear {
                if isShowingSearchResults {
                    setTreeSelection([])
                } else if let selection, tree.node(selection) != nil {
                    setTreeSelection([selection])
                }
                updateRowContext()
                rowContext.onDrop = { ids, destination in
                    guard !connection.isReadOnly else { return }
                    operations.requestMove(ids, to: destination)
                }
            }
            .onChange(of: bookmarks) { updateRowContext() }
            .onChange(of: isReadOnly) { updateRowContext() }
            .onChange(of: isShowingSearchResults) { _, isShowing in
                // Nothing is highlighted while the table is up, so clicking
                // the entry it replaced is a change, and shows it again.
                if isShowing {
                    setTreeSelection([])
                } else if let selection, tree.node(selection) != nil {
                    setTreeSelection([selection])
                }
            }
        }
    }

    private func updateRowContext() {
        if rowContext.bookmarks != bookmarkSet { rowContext.bookmarks = bookmarkSet }
        if rowContext.isReadOnly != isReadOnly { rowContext.isReadOnly = isReadOnly }
    }

    // MARK: - Search field

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search people, groups, OUs…", text: $searchText)
                .textFieldStyle(.plain)
                .focused($isSearchFieldFocused)
                .onExitCommand { endSearch() }
                .onKeyPress(.downArrow) {
                    guard isSearchMode, !searchText.isEmpty else { return .ignored }
                    searchResultsFocusRequest += 1
                    return .handled
                }
                .help("Finds entries whose name, uid or e-mail starts with this (* is a wildcard, mail:… looks at one attribute, and a filter in parentheses runs as it is)")
            if isSearchMode {
                Button {
                    endSearch()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Back to the Tree (Esc)")
            } else {
                Text("⌘F")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 7))
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(isSearchFieldFocused ? Color.accentColor.opacity(0.7) : .clear, lineWidth: 1.5)
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 6)
        .background {
            // Here as well as in the Entry menu: a window's own shortcuts
            // come before the menu bar's, where Edit › Find (for the LDIF
            // editor's find bar) would otherwise take ⌘F first.
            Button("Find") { beginSearch() }
                .keyboardShortcut("f", modifiers: .command)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
        // A click, ⌘F or typing opens the search — not focus alone, which
        // also lands here when a popover or sheet elsewhere closes.
        .simultaneousGesture(TapGesture().onEnded { isSearchMode = true })
        .onChange(of: searchText) { _, text in
            if !text.isEmpty { isSearchMode = true }
        }
    }

    private func beginSearch() {
        isSearchMode = true
        isSearchFieldFocused = true
    }

    /// Opens the table: with what the search field holds while it's in use,
    /// else a blank search.
    private func openSearchWithConditions() {
        let query = isSearchMode
            ? QuickSearchPanel.query(text: searchText, kind: searchKind, baseDN: searchBaseDN)
            : SearchQuery()
        endSearch()
        onOpenSearch(query)
    }

    /// Leaves the search for the tree, keeping the chips as they were.
    private func endSearch() {
        searchText = ""
        isSearchMode = false
        isSearchFieldFocused = false
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 14) {
            Button {
                newEntryRequest = NewEntryRequest(parentDN: selection ?? tree.baseDN)
            } label: {
                Image(systemName: "plus")
            }
            .help("New Entry (⌘N)")
            .disabled(isReadOnly)

            Button {
                importLDIF()
            } label: {
                Image(systemName: "square.and.arrow.down")
            }
            .help("Import LDIF")
            .disabled(isReadOnly)

            Button {
                exportLDIF(selectedDNs)
            } label: {
                Image(systemName: "square.and.arrow.up")
            }
            .help("Export Selected as LDIF")
            .disabled(treeSelection.isEmpty)

            Button {
                copyLDIF(selectedDNs)
            } label: {
                Image(systemName: "doc.on.clipboard")
            }
            .help("Copy Selected as LDIF")
            .disabled(treeSelection.isEmpty)

            Button(role: .destructive) {
                operations.requestDelete(selectedDNs)
            } label: {
                Image(systemName: "trash")
            }
            .help("Delete Selected (⌘⌫)")
            .disabled(treeSelection.isEmpty || isReadOnly)

            Button {
                openWindow(id: "schema", value: connection)
            } label: {
                Image(systemName: "list.bullet.rectangle")
            }
            .help("Schema")

            Button {
                openWindow(id: "ldif", value: connection)
            } label: {
                Image(systemName: "curlybraces")
            }
            .help("LDIF Editor")

            Button {
                openWindow(id: "serverInfo", value: connection)
            } label: {
                Image(systemName: "server.rack")
            }
            .help("Server Info (⌘I)")

            Spacer()

            if isRevealing {
                ProgressView().controlSize(.small)
            }

            Button {
                reloadTree()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("Refresh Entire Tree (⌥⌘R)")

            Button {
                openGoTo()
            } label: {
                Image(systemName: "arrow.right.to.line")
            }
            .help("Go to DN (⌘L)")
            .popover(isPresented: $isShowingGoTo, arrowEdge: .bottom) {
                goToPopover
            }

            bookmarksMenu

            Button {
                openSearchWithConditions()
            } label: {
                Image(systemName: "slider.horizontal.3")
            }
            .help("Search with Conditions (⇧⌘F)")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    private var bookmarksMenu: some View {
        Menu {
            if bookmarks.isEmpty {
                Text("No bookmarks")
            } else {
                ForEach(bookmarks, id: \.self) { dn in
                    Button {
                        reveal(dn)
                    } label: {
                        Text(DN.rdn(of: dn))
                    }
                    .help(dn)
                }
            }
            if let selection {
                Divider()
                let isBookmarked = bookmarkSet.contains(DN.normalize(selection))
                Button {
                    onToggleBookmark(selection)
                } label: {
                    Label(
                        isBookmarked
                            ? "Remove Bookmark for “\(DN.rdn(of: selection))”"
                            : "Bookmark “\(DN.rdn(of: selection))”",
                        systemImage: isBookmarked ? "bookmark.slash" : "bookmark"
                    )
                }
            }
        } label: {
            Image(systemName: "bookmark")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Bookmarks (⌘D)")
    }

    private var goToPopover: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Go to DN").font(.caption).foregroundStyle(.secondary)
            TextField("cn=…,dc=…", text: $goToText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 340)
                .focused($goToFieldFocused)
                .onSubmit { goTo(goToText) }
            if let goToError {
                Text(goToError).font(.caption).foregroundStyle(.red)
            }
            HStack {
                if isRevealing {
                    ProgressView().controlSize(.small)
                    Text("Loading the way there…").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Go") { goTo(goToText) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(goToText.trimmingCharacters(in: .whitespaces).isEmpty || isRevealing)
            }
        }
        .padding(12)
    }

    // MARK: - Context menus

    @ViewBuilder
    private func bulkContextMenuContent(_ nodes: [TreeNode]) -> some View {
        let dns = nodes.map(\.dn)

        Button {
            exportLDIF(dns)
        } label: {
            Label("Export \(nodes.count) Entries as LDIF", systemImage: "square.and.arrow.up")
        }

        Button {
            copyLDIF(dns)
        } label: {
            Label("Copy \(nodes.count) Entries as LDIF", systemImage: "doc.on.clipboard")
        }
        .keyboardShortcut("c", modifiers: [.command, .shift, .option])

        Divider()

        Button(role: .destructive) {
            DispatchQueue.main.async { operations.requestDelete(dns) }
        } label: {
            Label("Delete \(nodes.count) Selected Entries", systemImage: "trash")
        }
        .disabled(isReadOnly)
    }

    @ViewBuilder
    private func contextMenuContent(for node: TreeNode) -> some View {
        Button {
            selection = node.id
        } label: {
            Label("Open", systemImage: "arrow.right.circle")
        }

        Button {
            openWindow(id: "editEntry", value: EditEntryRequest(connection: connection, dn: node.dn))
        } label: {
            Label("Edit Entry…", systemImage: "square.and.pencil")
        }
        .keyboardShortcut("e", modifiers: .command)

        Button {
            DispatchQueue.main.async {
                newEntryRequest = NewEntryRequest(parentDN: node.dn)
            }
        } label: {
            Label("New Entry…", systemImage: "plus")
        }
        .keyboardShortcut("n", modifiers: .command)
        .disabled(isReadOnly)

        Button {
            // Deferred to the next run loop tick so the context menu has
            // fully dismissed before a new sheet/panel is presented —
            // presenting synchronously from inside the menu's own action
            // can crash (same issue as NSSavePanel below, and the one
            // ConnectionListPanel's export works around the same way).
            DispatchQueue.main.async { entryForRename = node.summaryEntry }
        } label: {
            Label("Rename…", systemImage: "pencil.line")
        }
        .keyboardShortcut("e", modifiers: [.command, .shift])
        .disabled(isReadOnly)

        Button {
            refresh(node.dn)
        } label: {
            Label("Refresh", systemImage: "arrow.clockwise")
        }
        .keyboardShortcut("r", modifiers: .command)

        Button {
            onOpenSearch(SearchQuery(baseDN: node.dn))
        } label: {
            Label("Search in This Branch…", systemImage: "magnifyingglass")
        }

        let isBookmarked = bookmarkSet.contains(DN.normalize(node.dn))
        Button {
            onToggleBookmark(node.dn)
        } label: {
            Label(
                isBookmarked ? "Remove Bookmark" : "Add Bookmark",
                systemImage: isBookmarked ? "bookmark.slash" : "bookmark"
            )
        }
        .keyboardShortcut("d", modifiers: .command)

        Divider()

        // Shown for every entry, but only enabled when this entry's object
        // classes actually allow the attribute — the shortcuts here mirror
        // the Entry menu, which is where they're actually registered.
        Button {
            DispatchQueue.main.async { entryForPasswordSet = node.summaryEntry }
        } label: {
            Label("Set Password…", systemImage: "key")
        }
        .keyboardShortcut("k", modifiers: [.command, .shift])
        .disabled(isReadOnly || !canSet("userPassword", on: node))

        Button {
            setPhoto(for: node.dn)
        } label: {
            Label("Set Photo…", systemImage: "photo")
        }
        .keyboardShortcut("i", modifiers: [.command, .shift])
        .disabled(isReadOnly || !canSet("jpegPhoto", on: node))

        Button {
            DispatchQueue.main.async { entryForTestBind = node.summaryEntry }
        } label: {
            Label("Test Bind…", systemImage: "checkmark.shield")
        }
        .keyboardShortcut("b", modifiers: [.command, .shift])
        .disabled(!canBind(as: node))

        if GroupMembersSheet.isGroup(node.summaryEntry) {
            Button {
                DispatchQueue.main.async {
                    groupForMembersEditing = node.summaryEntry
                }
            } label: {
                Label("Edit Members…", systemImage: "person.2.badge.gearshape")
            }
            .keyboardShortcut("u", modifiers: [.command, .shift])
            .disabled(isReadOnly)
        }

        Divider()

        Button {
            DispatchQueue.main.async {
                pickerRequest = PickerRequest(kind: .move, dn: node.dn)
            }
        } label: {
            Label("Move to…", systemImage: "arrow.turn.up.right")
        }
        .keyboardShortcut("m", modifiers: [.command, .shift])
        .disabled(isReadOnly)

        Button {
            DispatchQueue.main.async {
                pickerRequest = PickerRequest(kind: .copy, dn: node.dn)
            }
        } label: {
            Label("Copy to…", systemImage: "square.on.square")
        }
        .keyboardShortcut("d", modifiers: [.command, .shift])
        .disabled(isReadOnly)

        Button {
            copyToPasteboard(node.dn)
        } label: {
            Label("Copy DN", systemImage: "doc.on.doc")
        }
        .keyboardShortcut("c", modifiers: [.command, .shift])

        Button {
            exportLDIF([node.dn])
        } label: {
            Label("Export as LDIF", systemImage: "square.and.arrow.up")
        }
        .keyboardShortcut("x", modifiers: [.command, .shift])

        Button {
            copyLDIF([node.dn])
        } label: {
            Label("Copy as LDIF", systemImage: "doc.on.clipboard")
        }
        .keyboardShortcut("c", modifiers: [.command, .shift, .option])

        Divider()

        Button(role: .destructive) {
            DispatchQueue.main.async {
                operations.requestDelete([node.dn])
            }
        } label: {
            Label("Delete", systemImage: "trash")
        }
        .keyboardShortcut(.delete, modifiers: .command)
        .disabled(isReadOnly)
    }

    /// Whether `attribute` may be set on `node`, per the loaded schema.
    /// With no schema — or object classes the schema doesn't know — this
    /// stays permissive rather than blocking a legitimate edit.
    private func canSet(_ attribute: String, on node: TreeNode) -> Bool {
        guard let schema else { return true }
        let objectClasses = node.objectClasses
        guard schema.recognizesAnyObjectClass(objectClasses) else { return true }
        return schema.permitsAttribute(attribute, forObjectClasses: objectClasses)
    }

    /// Whether binding as this entry means anything — accounts, not
    /// containers. (The tree doesn't read userPassword, and Active
    /// Directory never returns it anyway, so this goes by object class.)
    private func canBind(as node: TreeNode) -> Bool {
        let accountClasses: Set<String> = [
            "person", "organizationalperson", "inetorgperson", "user", "account",
            "posixaccount", "shadowaccount", "simplesecurityobject", "inetuser",
            "sambasamaccount", "computer",
        ]
        return !Set(node.objectClasses.map { $0.lowercased() }).isDisjoint(with: accountClasses)
    }

    private func copyToPasteboard(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }

    private func mayHaveChildren(_ dns: [String]) -> Bool {
        dns.contains { tree.node($0)?.showsDisclosure ?? true }
    }

    private func exportLDIF(_ dns: [String]) {
        operations.exportLDIF(dns, mayHaveChildren: mayHaveChildren(dns))
    }

    private func copyLDIF(_ dns: [String]) {
        operations.copyLDIF(dns, mayHaveChildren: mayHaveChildren(dns))
    }

    // MARK: - Single-entry writes

    /// Runs a write against the server, then tells the tree what changed.
    private func perform(_ operation: @escaping () async throws -> DirectoryChange) {
        Task {
            isPerformingAction = true
            defer { isPerformingAction = false }
            do {
                await onChange(try await operation())
            } catch {
                actionError = "\(error)"
            }
        }
    }

    private func createEntry(dn: String, attributes: [(name: String, value: String)]) {
        Task {
            isPerformingAction = true
            defer { isPerformingAction = false }
            do {
                try await actions.createEntry(dn: dn, attributes: attributes)
                await onChange(.added(dn))
                _ = try? await tree.reveal(dn)
                selection = tree.node(dn)?.dn ?? dn
            } catch {
                actionError = "\(error)"
            }
        }
    }

    private func refresh(_ dn: String) {
        guard let node = tree.node(dn) else { return }
        if node.mayHaveChildren || node.isExpanded || node.childrenState == .loaded {
            Task { await tree.refresh(node) }
        } else {
            // A leaf by its looks: check whether it has children after all
            // (an AD computer with BitLocker keys under it, say).
            Task {
                await tree.refresh(node)
                tree.loadChildren(of: node)
            }
        }
        if DN.same(dn, selection ?? "") { onRefreshDetail() }
    }

    /// Re-reads the whole tree from the server, keeping whatever is
    /// expanded and selected wherever those entries still exist.
    private func reloadTree() {
        Task { await tree.refreshAll() }
        onRefreshDetail()
    }

    private func rename(_ dn: String, to newRDN: String) {
        Task {
            isPerformingAction = true
            defer { isPerformingAction = false }
            do {
                let newDN = try await actions.rename(dn, toRDN: newRDN)
                await onChange(.moved(from: dn, to: newDN))
                selection = tree.node(newDN)?.dn ?? newDN
            } catch {
                actionError = "\(error)"
            }
        }
    }

    private func setPassword(_ plaintext: String, scheme: PasswordScheme, for dn: String) {
        perform {
            try await actions.setPassword(plaintext, scheme: scheme, forDN: dn)
            return .modified(dn)
        }
    }

    private func setPhoto(for dn: String) {
        // Deferred so the context menu is fully gone before the panel opens
        // — same crash guard as the sheet presentations above.
        DispatchQueue.main.async {
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [.image]
            panel.allowsMultipleSelection = false
            panel.canChooseDirectories = false
            panel.begin { response in
                guard response == .OK, let url = panel.url else { return }
                perform {
                    try await actions.setPhoto(fileURL: url, forDN: dn, attribute: "jpegPhoto")
                    return .modified(dn)
                }
            }
        }
    }

    private func importLDIF() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "ldif") ?? .plainText, .plainText]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        DispatchQueue.main.async {
            panel.begin { response in
                guard response == .OK, let url = panel.url else { return }
                guard let text = try? String(contentsOf: url, encoding: .utf8) else {
                    actionError = "Couldn't read \(url.lastPathComponent) as text."
                    return
                }
                let entries = LDIFParser.parse(text)
                guard !entries.isEmpty else {
                    actionError = "No entries found in \(url.lastPathComponent)."
                    return
                }
                operations.importLDIF(entries)
            }
        }
    }

    // MARK: - Go to DN

    /// Expands every ancestor of `dn` — reading each one's children from
    /// the server first if they haven't been — then selects it and scrolls
    /// to it. Used by Go to DN, bookmarks, quick search and Advanced Search.
    private func reveal(_ dn: String) {
        Task {
            isRevealing = true
            defer { isRevealing = false }
            do {
                select(try await tree.reveal(dn))
            } catch is CancellationError {
            } catch {
                actionError = error.localizedDescription
            }
        }
    }

    /// Changes the list's selection without it counting as a click.
    private func setTreeSelection(_ ids: Set<DirectoryEntry.ID>) {
        guard ids != treeSelection else { return }
        isSettingTreeSelection = true
        treeSelection = ids
    }

    /// Selects a revealed entry. A new selection is selected in the list
    /// and scrolled to by onChange(of: selection); setting the list's
    /// selection here too would make it look like a click, which isn't
    /// scrolled to. One that's already selected (a search hit) just needs
    /// its row selected now that the tree shows it.
    private func select(_ dn: String) {
        rowContext.pickedInList = nil
        if selection == dn {
            treeSelection = [dn]
            onShowEntry()
        } else {
            selection = dn
        }
    }

    private func openGoTo() {
        goToText = selection ?? ""
        goToError = nil
        isShowingGoTo = true
        DispatchQueue.main.async { goToFieldFocused = true }
    }

    /// Jump to `input`, loading the tree down to it. DNs are matched the
    /// way people type them — case and spacing don't matter.
    private func goTo(_ input: String) {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        goToError = nil
        Task {
            isRevealing = true
            defer { isRevealing = false }
            do {
                select(try await tree.reveal(trimmed))
                isShowingGoTo = false
                goToText = ""
            } catch {
                goToError = error.localizedDescription
            }
        }
    }
}

/// Shared by every tree row. A class, so passing it down doesn't make
/// SwiftUI see "new" row inputs on every parent update; rows only redraw
/// for the properties they actually read.
@MainActor
@Observable
final class TreeRowContext {
    var bookmarks: Set<String> = []
    var isReadOnly = false
    /// The tree's current selection — read only when a drag starts, so
    /// not observed.
    @ObservationIgnored var selection: Set<String> = []
    /// The entry last selected by clicking in the list, which therefore
    /// needs no scrolling to.
    @ObservationIgnored var pickedInList: String?
    @ObservationIgnored var onDrop: ([String], String) -> Void = { _, _ in }

    /// A drag carries the whole selection if it started on a selected row.
    func draggedIDs(for id: String) -> [String] {
        let ids = selection.contains(id) ? Array(selection) : [id]
        return BranchOperations.operationRoots(ids)
    }
}

/// One row of the tree, and — when expanded — the rows under it. Reads its
/// `TreeNode` directly, so a branch loading or refreshing only redraws the
/// rows that belong to it.
private struct TreeNodeRow: View {
    let node: TreeNode
    let tree: DirectoryTree
    let context: TreeRowContext

    var body: some View {
        if node.showsDisclosure {
            DisclosureGroup(isExpanded: Binding(
                get: { node.isExpanded },
                set: { tree.setExpanded(node, $0) }
            )) {
                ForEach(node.visibleChildren) { child in
                    TreeNodeRow(node: child, tree: tree, context: context)
                }
                statusRow
            } label: {
                droppableRowLabel
                    .tag(node.id)
            }
            .id(node.id)
        } else {
            droppableRowLabel
                .tag(node.id)
                .id(node.id)
        }
    }

    /// Below the children: loading progress, a per-branch error with Retry,
    /// or the controls to draw more of a very large branch.
    @ViewBuilder
    private var statusRow: some View {
        switch node.childrenState {
        case .notLoaded, .loading:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(node.loadedCount > 0 ? "Loading… \(node.loadedCount.formatted())" : "Loading…")
                    .foregroundStyle(.secondary)
            }
            .font(.callout)
        case let .failed(message):
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(message)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .help(message)
                Button("Retry") { tree.retry(node) }
                    .controlSize(.small)
            }
            .font(.callout)
        case .loaded:
            if node.isTruncated {
                Label("The server returned only these \(node.children.count.formatted()) entries (its size limit). Use Search to find the rest.",
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }
            if node.hiddenChildCount > 0 {
                HStack(spacing: 8) {
                    Text("\(node.hiddenChildCount.formatted()) more")
                        .foregroundStyle(.secondary)
                    Button("Show \(min(TreeNode.displayStep, node.hiddenChildCount).formatted()) More") {
                        tree.showMore(node)
                    }
                    .controlSize(.small)
                    if node.children.count <= TreeNode.maxShowAll {
                        Button("Show All") { tree.showAll(node) }
                            .controlSize(.small)
                    }
                }
                .font(.callout)
                .help("To find one entry in a large branch, use Search or Go to DN (⌘L).")
            }
        }
    }

    private var countSuffix: String {
        switch node.childrenState {
        case .loaded: return " (\(node.children.count.formatted()))"
        case .loading where node.loadedCount > 0: return " (\(node.loadedCount.formatted())…)"
        default: return ""
        }
    }

    /// Only rows that can have children take drops. A drop target is most
    /// of what a row costs SwiftUI to set up as it scrolls into view, and
    /// leaf rows (users, groups) are the bulk of any large branch — so they
    /// aren't drop targets, though the server would accept children under
    /// them; the rare move there goes through Move to… instead.
    @ViewBuilder
    private var droppableRowLabel: some View {
        if node.acceptsDrops || node.showsDisclosure {
            rowLabel.modifier(TreeDropTarget(node: node, context: context))
        } else {
            rowLabel
        }
    }

    private var rowLabel: some View {
        HStack(spacing: 4) {
            Label(node.name + countSuffix, systemImage: node.icon)
            if node.isRefreshing {
                ProgressView().controlSize(.mini)
            }
            if context.bookmarks.contains(node.key) {
                Spacer(minLength: 4)
                Image(systemName: "bookmark.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .help("Bookmarked")
            }
        }
        .contentShape(Rectangle())
        .draggable(dragPayload)
    }

    private var dragPayload: Data {
        (try? JSONEncoder().encode(context.draggedIDs(for: node.id))) ?? Data()
    }
}

/// Lets entries dragged from the tree be dropped onto `node`, to move them
/// under it.
private struct TreeDropTarget: ViewModifier {
    let node: TreeNode
    let context: TreeRowContext

    @State private var isTargeted = false

    func body(content: Content) -> some View {
        content
            .background(isTargeted ? Color.accentColor.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 4))
            .dropDestination(for: Data.self) { items, _ in
                guard !context.isReadOnly,
                      let data = items.first,
                      let ids = try? JSONDecoder().decode([DirectoryEntry.ID].self, from: data) else { return false }
                context.onDrop(ids, node.dn)
                return true
            } isTargeted: { isTargeted in
                self.isTargeted = isTargeted
            }
    }
}
