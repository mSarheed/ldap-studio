//
//  SearchResultsView.swift
//  ldap-studio
//

import SwiftUI

/// A search opened as a table, in place of the entry details: what the
/// search field found, narrowed with conditions (or a filter typed by
/// hand), with the results ready to export, move or delete. Replaces the
/// Advanced Search sheet, so the directory stays in view, and the
/// filter is always shown but never required.
struct SearchResultsView: View {
    @Bindable var session: SearchSession
    let connection: SavedConnection
    let tree: DirectoryTree
    let schema: LdapSchema?
    /// The entry selected in the tree, offered as a place to search in.
    let selectedDN: String?
    let onOpen: (String) -> Void
    let onClose: () -> Void
    let onChange: (DirectoryChange) async -> Void
    let onEditSavedSearches: (([SavedLDAPFilter]) -> [SavedLDAPFilter]) -> Void

    @State private var operations: BranchOperations
    @State private var isAddingCondition = false
    @State private var editingCondition: LDAPFilterClause?
    @State private var isChoosingMoveDestination = false
    @State private var isNamingSavedSearch = false
    @State private var savedSearchName = ""
    @FocusState private var isFilterFieldFocused: Bool

    init(session: SearchSession, connection: SavedConnection, tree: DirectoryTree, schema: LdapSchema?,
         selectedDN: String?, onOpen: @escaping (String) -> Void, onClose: @escaping () -> Void,
         onChange: @escaping (DirectoryChange) async -> Void,
         onEditSavedSearches: @escaping (([SavedLDAPFilter]) -> [SavedLDAPFilter]) -> Void) {
        self.session = session
        self.connection = connection
        self.tree = tree
        self.schema = schema
        self.selectedDN = selectedDN
        self.onOpen = onOpen
        self.onClose = onClose
        self.onChange = onChange
        self.onEditSavedSearches = onEditSavedSearches
        _operations = State(initialValue: BranchOperations(connection: connection, schema: schema))
    }

    private var query: SearchQuery { session.query }

    private var filter: String? { query.filter(schema: schema) }

    /// The hand-typed filter's problem, if it has one.
    private var filterError: LDAPFilterError? {
        guard let rawFilter = query.rawFilter else { return nil }
        do {
            _ = try LDAPFilterParser.parse(rawFilter)
            return nil
        } catch {
            return error
        }
    }

    private var canSearch: Bool { filter != nil && filterError == nil }

    private var savedSearch: SavedLDAPFilter? {
        guard let filter else { return nil }
        return connection.savedFilters.first { $0.filter == filter && $0.isPinned }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if query.isRaw {
                rawFilterEditor
            } else {
                conditionsBar
            }
            actionsBar
            resultsTable
            if !query.isRaw, let filter {
                filterLine(filter)
            }
        }
        .branchOperations(operations)
        .onAppear {
            operations.onChange = onChange
            operations.onSelect = { _ in }
        }
        .onChange(of: connection) {
            operations.connection = connection
        }
        .onChange(of: schema) {
            operations.schema = schema
        }
        .sheet(isPresented: $isChoosingMoveDestination) {
            let selection = Array(session.selection)
            DestinationPickerSheet(
                tree: tree,
                excluding: selection,
                title: "Move \(selection.count) Selected \(selection.count == 1 ? "Entry" : "Entries") To",
                confirmLabel: "Move"
            ) { destinationDN in
                operations.requestMove(selection, to: destinationDN)
            }
        }
        .alert("Save Search", isPresented: $isNamingSavedSearch) {
            TextField("Name", text: $savedSearchName)
            Button("Save") { save() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Saved searches are listed under the search field for this connection.")
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            Text("Search")
                .font(.headline)
            Spacer()
            savedSearchesMenu
            if let savedSearch {
                Button("Saved", systemImage: "star.fill") {
                    onEditSavedSearches { SavedSearches.unpinning(savedSearch, in: $0) }
                }
                .help("Remove from Saved Searches")
            } else {
                Button("Save Search…", systemImage: "star") {
                    savedSearchName = ""
                    isNamingSavedSearch = true
                }
                .disabled(!canSearch)
            }
            Button("Done") {
                session.stop()
                onClose()
            }
            .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var savedSearchesMenu: some View {
        let pinned = SavedSearches.pinned(connection.savedFilters)
        let recent = SavedSearches.recent(connection.savedFilters)
        return Menu {
            if !pinned.isEmpty {
                Section("Saved Searches") {
                    ForEach(pinned) { item in
                        Button(item.title, systemImage: "star.fill") { open(item) }
                    }
                }
            }
            if !recent.isEmpty {
                Section("Recent") {
                    ForEach(recent) { item in
                        Button(item.title) { open(item) }
                    }
                }
                Divider()
                Button("Clear Recent Searches", role: .destructive) {
                    onEditSavedSearches { SavedSearches.clearingRecent($0) }
                }
            }
            if pinned.isEmpty && recent.isEmpty {
                Text("No Saved Searches")
            }
        } label: {
            Label("Saved & Recent", systemImage: "clock.arrow.circlepath")
        }
        .fixedSize()
        .help("Saved and Recent Searches")
    }

    // MARK: - Conditions

    private var conditionsBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            FlowLayout(spacing: 6) {
                kindToken
                nameToken
                ForEach(session.query.conditions) { clause in
                    conditionToken(clause)
                }
                Button {
                    isAddingCondition = true
                } label: {
                    Label("Condition", systemImage: "plus")
                }
                .buttonStyle(.borderless)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color.accentColor.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [3]))
                }
                .popover(isPresented: $isAddingCondition, arrowEdge: .bottom) {
                    ConditionEditor(clause: LDAPFilterClause(), isNew: true, schema: schema) { clause in
                        session.query.conditions.append(clause)
                        isAddingCondition = false
                        search()
                    } onRemove: {
                        isAddingCondition = false
                    }
                }
                if session.query.conditions.count > 1 {
                    HStack(spacing: 4) {
                        Text("Match").foregroundStyle(.secondary)
                        Picker("Match", selection: $session.query.join) {
                            ForEach(LDAPFilterJoin.allCases) { join in
                                Text(join.title).tag(join)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .fixedSize()
                        .onChange(of: session.query.join) { search() }
                    }
                    .font(.callout)
                }
            }
            HStack(spacing: 8) {
                scopeMenu
                Spacer()
                searchButton
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }

    private var kindToken: some View {
        Menu {
            Picker("Type", selection: $session.query.kind) {
                ForEach(EntryKind.allCases) { kind in
                    Label(kind == .all ? "Any Type" : kind.title, systemImage: kind.symbol).tag(kind)
                }
            }
            .pickerStyle(.inline)
        } label: {
            tokenLabel(key: "Type", operation: "is", value: query.kind == .all ? "any" : query.kind.title)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .fixedSize()
        .onChange(of: session.query.kind) { search() }
    }

    private var nameToken: some View {
        HStack(spacing: 4) {
            Text("Name, uid or e-mail").foregroundStyle(Color.accentColor)
            Text("starts with").foregroundStyle(.secondary)
            TextField("anything", text: Binding(
                get: { session.query.text },
                // A field still editing as the view switches to the filter
                // editor writes its text back as it goes; that's not an edit.
                set: { if !session.query.isRaw { session.query.text = $0 } }
            ))
                .textFieldStyle(.plain)
                .frame(minWidth: 70, maxWidth: 160)
                .fixedSize(horizontal: true, vertical: false)
                .onSubmit(search)
        }
        .font(.callout)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
    }

    private func conditionToken(_ clause: LDAPFilterClause) -> some View {
        HStack(spacing: 2) {
            Button {
                editingCondition = clause
            } label: {
                tokenLabel(key: clause.attribute,
                           operation: (clause.isNegated ? "not " : "") + clause.operation.rawValue,
                           value: clause.operation.needsValue ? clause.value : nil,
                           trailingPadding: 2)
            }
            .buttonStyle(.plain)
            .help("Edit Condition")
            .popover(isPresented: Binding(
                get: { editingCondition?.id == clause.id },
                set: { if !$0 { editingCondition = nil } }
            ), arrowEdge: .bottom) {
                ConditionEditor(clause: clause, isNew: false, schema: schema) { edited in
                    if let index = session.query.conditions.firstIndex(where: { $0.id == clause.id }) {
                        session.query.conditions[index] = edited
                    }
                    editingCondition = nil
                    search()
                } onRemove: {
                    editingCondition = nil
                    removeCondition(clause)
                }
            }
            Button {
                removeCondition(clause)
            } label: {
                Image(systemName: "xmark")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.trailing, 6)
            }
            .buttonStyle(.plain)
            .help("Remove Condition")
        }
        .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
    }

    private func tokenLabel(key: String, operation: String, value: String?, trailingPadding: CGFloat = 8) -> some View {
        HStack(spacing: 4) {
            Text(key).foregroundStyle(Color.accentColor)
            Text(operation).foregroundStyle(.secondary)
            if let value {
                Text(value).lineLimit(1)
            }
        }
        .font(.callout)
        .padding(.leading, 8)
        .padding(.trailing, trailingPadding)
        .padding(.vertical, 4)
        .background(trailingPadding == 8 ? Color.accentColor.opacity(0.12) : .clear,
                    in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
    }

    private func removeCondition(_ clause: LDAPFilterClause) {
        session.query.conditions.removeAll { $0.id == clause.id }
        search()
    }

    /// Where to search: the whole directory, the entry selected in the tree
    /// or the place this search started in, and how deep.
    private var scopeMenu: some View {
        let base = session.baseDN
        return HStack(spacing: 6) {
            Text("In").foregroundStyle(.secondary)
            Menu {
                Button("Whole Directory", systemImage: "globe") { setBase(nil) }
                if let selectedDN, !DN.same(selectedDN, session.directoryBaseDN) {
                    Button("\(DN.rdn(of: selectedDN)) (Selected)", systemImage: "folder") { setBase(selectedDN) }
                }
                if let current = query.baseDN, selectedDN.map({ !DN.same($0, current) }) ?? true {
                    Button(DN.rdn(of: current), systemImage: "folder") { setBase(current) }
                }
                Divider()
                Picker("Depth", selection: $session.query.depth) {
                    ForEach(SearchDepth.allCases) { depth in
                        Text(depth.title).tag(depth)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                Label(query.baseDN == nil ? "Whole Directory" : DN.rdn(of: base),
                      systemImage: query.baseDN == nil ? "globe" : "folder")
            }
            .fixedSize()
            .help(base)
            .onChange(of: session.query.depth) { search() }
            if query.depth != .subtree {
                Text(query.depth.title)
                    .foregroundStyle(.secondary)
            }
        }
        .font(.callout)
    }

    private func setBase(_ dn: String?) {
        session.query.baseDN = dn
        search()
    }

    @ViewBuilder
    private var searchButton: some View {
        if session.isSearching {
            Button("Stop") { session.stop() }
                .keyboardShortcut(".", modifiers: .command)
        } else {
            Button("Search") { search() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!canSearch)
        }
    }

    // MARK: - Hand-typed filter

    private var rawFilterEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("(&(objectClass=person)(mail=*@example.com))",
                      text: Binding(get: { session.query.rawFilter ?? "" },
                                    // Likewise as it switches back to conditions.
                                    set: { if session.query.isRaw { session.query.rawFilter = $0 } }),
                      axis: .vertical)
                .font(.system(.body, design: .monospaced))
                .textFieldStyle(.plain)
                .lineLimit(1...6)
                .focused($isFilterFieldFocused)
                .onSubmit(search)
                .padding(8)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(filterError == nil ? Color.accentColor.opacity(0.6) : .red.opacity(0.7))
                }
            HStack(spacing: 12) {
                if let filterError {
                    Label(filterError.message, systemImage: "xmark.circle.fill")
                        .foregroundStyle(.red)
                } else {
                    Label("Valid filter", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
                Spacer()
                Button("Show as Conditions") {
                    showAsConditions()
                }
                .buttonStyle(.link)
                .disabled(conditionsForFilter == nil)
                .help(conditionsForFilter == nil
                      ? "Only one comparison, or an AND or OR of comparisons, can be shown as conditions"
                      : "Edit this filter as conditions")
            }
            .font(.caption)
            HStack(spacing: 8) {
                scopeMenu
                Spacer()
                searchButton
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .onAppear { isFilterFieldFocused = true }
    }

    private func editAsText() {
        let filter = filter ?? ""
        session.textEditOrigin = (session.query, filter)
        session.query.rawFilter = filter
        session.query.text = ""
        session.query.kind = .all
        session.query.conditions = []
    }

    /// The conditions the filter being edited can be shown as: the ones it
    /// came from while it's unchanged, else whatever it parses into.
    private var conditionsForFilter: SearchQuery? {
        guard let rawFilter = query.rawFilter else { return nil }
        if let origin = session.textEditOrigin,
           LDAPFilterParser.normalized(rawFilter) == LDAPFilterParser.normalized(origin.filter) {
            var restored = origin.query
            restored.baseDN = query.baseDN
            restored.depth = query.depth
            return restored
        }
        guard let parsed = LDAPFilterParser.conditions(from: rawFilter) else { return nil }
        return SearchQuery(conditions: parsed.clauses, join: parsed.join,
                           baseDN: query.baseDN, depth: query.depth)
    }

    private func showAsConditions() {
        guard let conditions = conditionsForFilter else { return }
        session.query = conditions
        session.textEditOrigin = nil
    }

    private func filterLine(_ filter: String) -> some View {
        HStack(spacing: 10) {
            Text("LDAP FILTER")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
            Text(filter)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(2)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            Button("Edit as Text") { editAsText() }
                .buttonStyle(.link)
                .font(.caption)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
    }

    // MARK: - Results

    private var actionsBar: some View {
        HStack(spacing: 10) {
            statusText
            Spacer()
            if session.totalFound > session.results.count, !session.isSearching {
                Button("Show \(min(SearchSession.displayStep, session.totalFound - session.results.count).formatted()) More") {
                    session.showMore()
                }
            }
            Button("Export LDIF…", systemImage: "square.and.arrow.up") {
                if let request = session.lastRequest {
                    operations.exportLDIF(of: request, selected: session.selection.isEmpty ? nil : session.selection)
                }
            }
            .disabled(session.totalFound == 0 || session.isSearching)
            .help(session.selection.isEmpty ? "Export every result" : "Export the selected results")
            Button("Move…", systemImage: "arrow.turn.up.right") {
                isChoosingMoveDestination = true
            }
            .disabled(session.selection.isEmpty || connection.isReadOnly || session.isSearching)
            Button("Delete", systemImage: "trash", role: .destructive) {
                operations.requestDelete(Array(session.selection))
            }
            .disabled(session.selection.isEmpty || connection.isReadOnly || session.isSearching)
        }
        .controlSize(.small)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var statusText: some View {
        Group {
            if let errorMessage = session.errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .lineLimit(2)
            } else if session.isSearching {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Searching… \(session.foundSoFar.formatted()) found")
                        .foregroundStyle(.secondary)
                }
            } else if session.hasSearched {
                let count = "\(session.totalFound.formatted()) result\(session.totalFound == 1 ? "" : "s")"
                let selected = session.selection.isEmpty ? "" : " · \(session.selection.count.formatted()) selected"
                let note = session.wasCancelled ? " (stopped)"
                    : session.wasTruncated ? " — incomplete: the server’s size limit cut the search short" : ""
                Text(count + selected + note)
                    .foregroundStyle(.secondary)
            } else {
                Text("Add a name or a condition, then Search")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.callout.monospacedDigit())
    }

    private var resultsTable: some View {
        Table(session.results, selection: $session.selection) {
            TableColumn("Name") { hit in
                HStack(spacing: 6) {
                    Image(systemName: hit.icon)
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 16)
                    Text(hit.name)
                        .lineLimit(1)
                }
                .help(hit.dn)
            }
            .width(min: 140, ideal: 200)
            TableColumnForEach(session.columns, id: \.self) { column in
                TableColumn(column) { hit in
                    Text(hit.values[column.lowercased()] ?? "")
                        .lineLimit(1)
                        .help(hit.values[column.lowercased()] ?? "")
                }
                .width(min: 80, ideal: 160)
            }
            TableColumn("Location") { hit in
                Text(Self.location(of: hit.dn, under: session.directoryBaseDN))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .help(DN.parent(of: hit.dn) ?? "")
            }
            .width(min: 100, ideal: 200)
        }
        .contextMenu(forSelectionType: String.self) { dns in
            if dns.count == 1, let dn = dns.first {
                Button("Open", systemImage: "arrow.right.circle") { onOpen(dn) }
                Button("Copy DN", systemImage: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(dn, forType: .string)
                }
            }
        } primaryAction: { dns in
            if let dn = dns.first { onOpen(dn) }
        }
        .overlay {
            if session.isSearching && session.results.isEmpty {
                ProgressView()
            } else if session.hasSearched, !session.isSearching, session.results.isEmpty,
                      session.errorMessage == nil {
                ContentUnavailableView.search
            }
        }
    }

    /// Where an entry is, from the top: "ou=People › ou=Visitors". Its
    /// parent's own name when that's the base.
    static func location(of dn: String, under base: String) -> String {
        guard let parent = DN.parent(of: dn) else { return "" }
        guard let path = DN.path(to: dn, from: base), !path.isEmpty else { return DN.rdn(of: parent) }
        let below = path.dropFirst().map(DN.rdn(of:))
        return below.isEmpty ? DN.rdn(of: parent) : below.joined(separator: " › ")
    }

    // MARK: - Running

    private func search() {
        guard canSearch else { return }
        guard let filter = session.run(target: connection.ldapTarget, schema: schema) else { return }
        onEditSavedSearches { SavedSearches.recording(session.query, filter: filter, in: $0) }
    }

    private func save() {
        guard let filter else { return }
        let name = savedSearchName.trimmingCharacters(in: .whitespacesAndNewlines)
        onEditSavedSearches { SavedSearches.pinning(session.query, filter: filter,
                                                   name: name.isEmpty ? nil : name, in: $0) }
    }

    private func open(_ item: SavedLDAPFilter) {
        session.query = item.searchQuery
        session.textEditOrigin = nil
        search()
    }
}

/// Adds or edits one condition: suggests the attributes people search on
/// most, as far as the schema has them, and takes any other.
private struct ConditionEditor: View {
    @State var clause: LDAPFilterClause
    let isNew: Bool
    let schema: LdapSchema?
    let onSave: (LDAPFilterClause) -> Void
    let onRemove: () -> Void

    @FocusState private var isValueFocused: Bool

    private static let common: [(name: String, label: String)] = [
        ("mail", "E-mail address"), ("memberOf", "Member of group"), ("title", "Job title"),
        ("description", "Description"), ("telephoneNumber", "Phone"), ("departmentNumber", "Department"),
        ("employeeType", "Employee type"), ("loginShell", "Login shell"), ("uidNumber", "UID number"),
        ("member", "Has member"), ("l", "City"), ("department", "Department"),
    ]

    /// The schema's attribute names starting with what's typed, for the
    /// attribute field's completions.
    private var attributeMatches: [String] {
        let typed = clause.attribute.trimmingCharacters(in: .whitespaces).lowercased()
        guard !typed.isEmpty, let schema else { return [] }
        let names = schema.attributeTypes.flatMap(\.names)
        guard !names.contains(where: { $0.lowercased() == typed }) else { return [] }
        return Array(names
            .filter { $0.lowercased().hasPrefix(typed) }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            .prefix(8))
    }

    private var suggestions: [(name: String, label: String)] {
        guard let schema else { return Array(Self.common.prefix(6)) }
        let known = Set(schema.attributeTypes.flatMap(\.names).map { $0.lowercased() })
        return Array(Self.common.filter { known.contains($0.name.lowercased()) }.prefix(6))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(isNew ? "Add a Condition" : "Edit Condition")
                .font(.headline)
            if !suggestions.isEmpty {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 4) {
                    ForEach(suggestions, id: \.name) { suggestion in
                        let isChosen = clause.attribute.caseInsensitiveCompare(suggestion.name) == .orderedSame
                        Button {
                            clause.attribute = suggestion.name
                            isValueFocused = true
                        } label: {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(suggestion.name)
                                Text(suggestion.label)
                                    .font(.caption)
                                    .foregroundStyle(isChosen ? AnyShapeStyle(.white.opacity(0.8)) : AnyShapeStyle(.secondary))
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .foregroundStyle(isChosen ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                            .background(isChosen ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary),
                                        in: RoundedRectangle(cornerRadius: 6))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            HStack(spacing: 6) {
                TextField("Attribute", text: $clause.attribute)
                    .textInputSuggestions {
                        ForEach(attributeMatches, id: \.self) { name in
                            Text(name).textInputCompletion(name)
                        }
                    }
                    .frame(width: 130)
                Picker("Comparison", selection: $clause.operation) {
                    ForEach(LDAPFilterOperator.allCases) { operation in
                        Text(operation.rawValue).tag(operation)
                    }
                }
                .labelsHidden()
                .fixedSize()
                if clause.operation.needsValue {
                    TextField("Value", text: $clause.value)
                        .focused($isValueFocused)
                        .frame(maxWidth: .infinity)
                        .onSubmit { if clause.filter != nil { onSave(clause) } }
                } else {
                    Spacer()
                }
            }
            Toggle("Exclude matches (NOT)", isOn: $clause.isNegated)
                .toggleStyle(.checkbox)
            HStack {
                if !isNew {
                    Button("Remove", role: .destructive) { onRemove() }
                }
                Spacer()
                Button(isNew ? "Add" : "Update") { onSave(clause) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(clause.filter == nil)
            }
        }
        .padding(14)
        .frame(width: 460)
    }
}
