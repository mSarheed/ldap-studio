//
//  QuickSearchPanel.swift
//  ldap-studio
//

import SwiftUI

/// What the sidebar shows in place of the tree while the search field is
/// in use: chips for the kind of entry and where to look, then either the
/// saved and recent searches (nothing typed yet) or the matches, grouped
/// by kind, each saying why it matched. Selecting a match shows it in the
/// detail view; Return or a double-click shows it in the tree.
struct QuickSearchPanel: View {
    /// A binding rather than a value: the ⌘↩ shortcut keeps the action it
    /// was first given, and must still see what's typed now.
    @Binding var text: String
    @Binding var kind: EntryKind
    /// nil = the whole directory.
    @Binding var baseDN: String?
    @Binding var selection: DirectoryEntry.ID?
    /// Shows the selected entry in the detail view — needed as well as
    /// setting `selection`, which may already be this entry.
    let onShowEntry: () -> Void
    /// Bumped by ↓ in the search field: move into the results.
    let focusRequest: Int
    let tree: DirectoryTree
    let connection: SavedConnection
    let schema: LdapSchema?
    let onReveal: (String) -> Void
    let onOpenTable: (SearchQuery) -> Void
    let onEditSavedSearches: (([SavedLDAPFilter]) -> [SavedLDAPFilter]) -> Void

    @State private var hits: [Match] = []
    @State private var state: SearchState = .idle
    @State private var listSelection: String?
    @FocusState private var isListFocused: Bool
    static let limit = 200

    private enum SearchState: Equatable {
        case idle, searching
        case done(isComplete: Bool)
        case failed(String)
    }

    /// One match, worked out once when the results arrive.
    struct Match: Identifiable, Hashable {
        let dn: String
        let icon: String
        let kind: EntryKind?
        let name: String
        /// Where it is, under the directory's base.
        let location: String
        /// The attribute and value that matched, when the name didn't.
        let reason: (attribute: String, value: String)?
        var id: String { dn }

        static func == (lhs: Match, rhs: Match) -> Bool { lhs.dn == rhs.dn }
        func hash(into hasher: inout Hasher) { hasher.combine(dn) }
    }

    private var trimmedText: String { text.trimmingCharacters(in: .whitespaces) }

    private var query: SearchQuery { Self.query(text: text, kind: kind, baseDN: baseDN) }

    /// The search the field, chips and branch menu describe; a filter in
    /// parentheses is used as it is.
    static func query(text: String, kind: EntryKind, baseDN: String?) -> SearchQuery {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("(") {
            return SearchQuery(kind: kind, rawFilter: trimmed, baseDN: baseDN)
        }
        return SearchQuery(text: trimmed, kind: kind, baseDN: baseDN)
    }

    private struct SearchKey: Equatable {
        let text: String
        let kind: EntryKind
        let baseDN: String?
    }

    var body: some View {
        VStack(spacing: 0) {
            chips
            Divider()
            if trimmedText.isEmpty {
                savedAndRecent
            } else {
                results
            }
        }
        .task(id: SearchKey(text: trimmedText, kind: kind, baseDN: baseDN)) { await search() }
        .background {
            // Here rather than on the results' button, so it works before
            // anything is typed too.
            Button("Open as Table") { openTable() }
                .keyboardShortcut(.return, modifiers: .command)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
    }

    // MARK: - Chips

    private var chips: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                ForEach(EntryKind.allCases) { option in
                    Button {
                        kind = option
                    } label: {
                        Text(option.title)
                            .font(.caption.weight(kind == option ? .semibold : .regular))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .foregroundStyle(kind == option ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                            .background(kind == option ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary),
                                        in: Capsule())
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .help(option == .all ? "Every kind of entry" : "Only \(option.title.lowercased())")
                }
            }
            HStack(spacing: 4) {
                Text("In").foregroundStyle(.secondary)
                Menu {
                    Button("Whole Directory", systemImage: "globe") { baseDN = nil }
                    if let branch = selectedBranch, !DN.same(branch, tree.baseDN) {
                        Button(DN.rdn(of: branch), systemImage: "folder") { baseDN = branch }
                    }
                } label: {
                    Label(baseDN.map(DN.rdn(of:)) ?? "Whole Directory",
                          systemImage: baseDN == nil ? "globe" : "folder")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help(baseDN ?? tree.baseDN)
            }
            .font(.caption)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The branch to offer searching in: the selected entry, or its parent
    /// when it's a leaf.
    private var selectedBranch: String? {
        guard let selection else { return nil }
        if let node = tree.node(selection), !node.showsDisclosure {
            return DN.parent(of: selection)
        }
        return selection
    }

    // MARK: - Saved and recent

    private var savedAndRecent: some View {
        let pinned = SavedSearches.pinned(connection.savedFilters)
        let recent = SavedSearches.recent(connection.savedFilters)
        return List {
            if !pinned.isEmpty {
                Section("Saved Searches") {
                    ForEach(pinned) { item in
                        savedRow(item, systemImage: "star.fill", tint: .orange)
                    }
                }
            }
            if !recent.isEmpty {
                Section {
                    ForEach(recent) { item in
                        savedRow(item, systemImage: "clock.arrow.circlepath", tint: .secondary)
                    }
                } header: {
                    HStack {
                        Text("Recent")
                        Spacer()
                        Button("Clear") {
                            onEditSavedSearches { SavedSearches.clearingRecent($0) }
                        }
                        .buttonStyle(.borderless)
                        .font(.caption)
                    }
                }
            }
            Section("Tips") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Type the start of a name, uid or e-mail.")
                    Text("`mail:ana` or `uid:ana` looks at one attribute.")
                    Text("A filter in parentheses, like `(mail=*@example.com)`, runs as it is.")
                    Text("⌘↩ opens the results as a table, to add conditions.")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .listStyle(.sidebar)
    }

    private func savedRow(_ item: SavedLDAPFilter, systemImage: String, tint: Color) -> some View {
        Button {
            onOpenTable(item.searchQuery)
        } label: {
            Label {
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.title).lineLimit(1)
                    if item.name != nil {
                        Text(item.query?.summary ?? item.filter)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            } icon: {
                Image(systemName: systemImage).foregroundStyle(tint)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(item.filter)
    }

    // MARK: - Results

    /// The matches grouped by kind, in the chips' order; anything else last.
    private var groups: [(title: String, matches: [Match])] {
        var groups: [(title: String, matches: [Match])] = []
        for option in EntryKind.allCases where option != .all {
            let matches = hits.filter { $0.kind == option }
            if !matches.isEmpty { groups.append((option.title, matches)) }
        }
        let other = hits.filter { $0.kind == nil }
        if !other.isEmpty { groups.append(("Other", other)) }
        return groups
    }

    private var results: some View {
        VStack(spacing: 0) {
            List(selection: $listSelection) {
                ForEach(groups, id: \.title) { group in
                    Section("\(group.title) · \(group.matches.count)") {
                        ForEach(group.matches) { match in
                            row(match)
                                .tag(match.dn)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .contextMenu(forSelectionType: String.self) { dns in
                if let dn = dns.first, dns.count == 1 {
                    Button("Show in Tree", systemImage: "arrow.right.circle") { reveal(dn) }
                }
            } primaryAction: { dns in
                if let dn = dns.first { reveal(dn) }
            }
            .focused($isListFocused)
            .onChange(of: focusRequest) {
                guard let first = groups.first?.matches.first else { return }
                isListFocused = true
                if listSelection == nil { listSelection = first.dn }
            }
            .onChange(of: listSelection) { _, dn in
                guard let dn else { return }
                selection = dn
                onShowEntry()
            }
            .onKeyPress(.return) {
                guard let dn = listSelection else { return .ignored }
                reveal(dn)
                return .handled
            }
            .overlay {
                if state == .done(isComplete: true), hits.isEmpty {
                    ContentUnavailableView.search(text: trimmedText)
                }
            }

            Divider()

            HStack(spacing: 6) {
                switch state {
                case .idle, .searching:
                    ProgressView().controlSize(.small)
                    Text("Searching…")
                case let .done(isComplete):
                    Text(isComplete
                         ? "\(hits.count) match\(hits.count == 1 ? "" : "es")"
                         : "First \(hits.count) matches")
                case let .failed(message):
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(message).lineLimit(2)
                }
                Spacer(minLength: 4)
                Button("Open as Table") { openTable() }
                    .buttonStyle(.link)
                    .help("Show these results as a table, to add conditions or act on many (⌘↩)")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
        }
    }

    private func row(_ match: Match) -> some View {
        HStack(spacing: 8) {
            Image(systemName: match.icon)
                .foregroundStyle(Color.accentColor)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(highlighted(match.name, isNameMatch: match.reason == nil))
                    .lineLimit(1)
                Text(match.location)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                if let reason = match.reason {
                    Text("\(reason.attribute): \(highlighted(reason.value, isNameMatch: true))")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            .font(.body)
            Spacer(minLength: 0)
        }
        .help(match.dn)
    }

    /// `value` with the part the search text matched marked — the start,
    /// for a plain name search.
    private func highlighted(_ value: String, isNameMatch: Bool) -> AttributedString {
        var string = AttributedString(value)
        let text = queryText
        guard isNameMatch, !text.isEmpty, !text.contains("*"),
              value.lowercased().hasPrefix(text.lowercased()),
              let range = string.range(of: String(value.prefix(text.count)))
        else { return string }
        string[range].backgroundColor = .yellow.opacity(0.35)
        return string
    }

    /// The text names are matched against: after `attr:` for a shortcut.
    private var queryText: String {
        if let shortcut = SearchQuery.attributeShortcut(in: trimmedText, schema: schema) {
            return shortcut.value
        }
        return trimmedText
    }

    // MARK: - Searching

    private func search() async {
        let query = query
        guard !trimmedText.isEmpty, let filter = query.filter(schema: schema) else {
            hits = []
            state = .idle
            return
        }
        if let rawFilter = query.rawFilter {
            do {
                _ = try LDAPFilterParser.parse(rawFilter)
            } catch {
                hits = []
                state = .failed(error.message)
                return
            }
        }
        state = .searching
        // Debounce: typing again cancels this task before it searches.
        try? await Task.sleep(for: .milliseconds(300))
        guard !Task.isCancelled else { return }
        let naming = SearchQuery.namingAttributes(schema: schema)
        let shortcut = SearchQuery.attributeShortcut(in: trimmedText, schema: schema)
        let matchText = shortcut?.value ?? trimmedText
        let matchAttributes = shortcut.map { [$0.attribute] } ?? naming
        let base = query.baseDN ?? tree.baseDN
        let directoryBase = tree.baseDN
        do {
            let result = try await searchAll(tree.target, LdapSearchRequest(
                baseDn: base, scope: .subtree, filter: filter,
                attributes: ["objectClass", "univentionObjectType"] + matchAttributes
                    + (matchAttributes.contains("cn") ? [] : ["cn"])
                    + (matchAttributes.contains("displayName") ? [] : ["displayName"]),
                limit: Self.limit
            ))
            guard !Task.isCancelled else { return }
            let isFilter = query.isRaw
            hits = result.entries
                .sorted { (DN.depth($0.dn), $0.dn.lowercased()) < (DN.depth($1.dn), $1.dn.lowercased()) }
                .map { Self.match($0, text: isFilter ? "" : matchText, attributes: matchAttributes,
                                  directoryBase: directoryBase) }
            state = .done(isComplete: result.isComplete)
        } catch is CancellationError {
        } catch {
            guard !Task.isCancelled else { return }
            hits = []
            state = .failed("\(error)")
        }
    }

    private static func match(_ entry: LdapEntry, text: String, attributes: [String], directoryBase: String) -> Match {
        let icon = DirectoryEntry.icon(forObjectClasses: entry.values("objectClass"),
                                       univentionType: entry.values("univentionObjectType").first,
                                       hasChildren: false)
        let name = SearchSession.displayName(of: entry)
        var reason: (String, String)?
        if !text.isEmpty, !SearchQuery.value(name, matches: text) {
            for attribute in attributes {
                if let value = entry.values(attribute).first(where: { SearchQuery.value($0, matches: text) }) {
                    reason = (attribute, value)
                    break
                }
            }
        }
        return Match(dn: entry.dn, icon: icon, kind: EntryKind.of(icon: icon), name: name,
                     location: SearchResultsView.location(of: entry.dn, under: directoryBase),
                     reason: reason)
    }

    private func reveal(_ dn: String) {
        record()
        onReveal(dn)
    }

    /// The table records the search when it runs it.
    private func openTable() {
        onOpenTable(query)
    }

    /// Remembers this search among the recent ones.
    private func record() {
        guard let filter = query.filter(schema: schema) else { return }
        onEditSavedSearches { SavedSearches.recording(query, filter: filter, in: $0) }
    }
}
