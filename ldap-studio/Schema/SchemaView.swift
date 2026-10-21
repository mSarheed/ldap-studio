//
//  SchemaView.swift
//  ldap-studio
//

import SwiftUI

/// Lets any window ask an open (or about-to-open) Schema window to jump to
/// a specific attribute type or object class — used by "Jump to Schema" /
/// "Jump to Object Class" on an attribute row in the entry detail table.
/// State-based rather than a one-shot notification, so it's caught whether
/// the Schema window is brand new (picked up once its own schema fetch
/// finishes) or already open and just not frontmost (picked up via
/// `onChange`).
@MainActor
@Observable
final class SchemaJumpCoordinator {
    static let shared = SchemaJumpCoordinator()
    private init() {}

    enum Target: Equatable {
        case attribute(String)
        case objectClass(String)
    }

    struct Request: Equatable {
        /// "host:port" — so a jump only lands in the Schema window for the
        /// same connection.
        let endpoint: String
        let target: Target
        private let token = UUID()
    }

    private(set) var pending: Request?

    func jump(toAttribute name: String, endpoint: String) {
        pending = Request(endpoint: endpoint, target: .attribute(name))
    }

    func jump(toObjectClass name: String, endpoint: String) {
        pending = Request(endpoint: endpoint, target: .objectClass(name))
    }

    func clear(_ request: Request) {
        if pending == request { pending = nil }
    }
}

struct SchemaView: View {
    let connection: SavedConnection

    private enum Tab: Hashable { case objectClasses, attributes }

    @State private var schema: LdapSchema?
    @State private var loadError: String?
    @State private var selectedTab: Tab = .objectClasses
    @State private var jumpAttributeName: String?
    @State private var jumpObjectClassName: String?
    @State private var coordinator = SchemaJumpCoordinator.shared
    /// A fresh read is under way, possibly behind a copy from earlier.
    @State private var isReading = false

    private var endpoint: String {
        "\(connection.host):\(UInt16(clamping: connection.port))"
    }

    var body: some View {
        Group {
            if let loadError {
                ContentUnavailableView {
                    Label("Couldn't Load Schema", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(loadError)
                } actions: {
                    Button("Try Again") {
                        Task { await load() }
                    }
                }
            } else if let schema {
                TabView(selection: $selectedTab) {
                    SchemaObjectClassesTab(objectClasses: schema.objectClasses,
                                          jumpToObjectClassName: $jumpObjectClassName)
                        .tabItem {
                            Label("Object Classes", systemImage: "square.stack.3d.up")
                        }
                        .tag(Tab.objectClasses)

                    SchemaAttributesTab(objectClasses: schema.objectClasses, attributeTypes: schema.attributeTypes,
                                        jumpToAttributeName: $jumpAttributeName)
                        .tabItem {
                            Label("Attributes", systemImage: "list.bullet")
                        }
                        .tag(Tab.attributes)
                }
            } else {
                ProgressView("Loading Schema…")
            }
        }
        .frame(minWidth: 760, minHeight: 520)
        .navigationTitle("Ldap Studio - \(connection.name) Schema")
        .task {
            await load()
        }
        .onChange(of: coordinator.pending) { _, _ in applyPendingJump() }
    }

    private func load() async {
        loadError = nil
        let target = connection.ldapTarget
        // Already read this session (usually by the browser): show it now,
        // then swap in a fresh read if the server's has changed since.
        if schema == nil, let cached = cachedSchema(target) {
            // After the window's first frame: building the lists into the
            // window's initial layout costs more than into one already up.
            try? await Task.sleep(for: .zero)
            schema = cached
        }
        isReading = true
        defer {
            isReading = false
            // Only once the fresh read is in: a jump to something just added
            // to the schema wouldn't be found in the copy shown before it.
            applyPendingJump()
        }
        do {
            let fresh = try await fetchSchema(target)
            if fresh != schema { schema = fresh }
        } catch {
            // A copy already showing is still the best there is.
            if schema == nil { loadError = "\(error)" }
        }
    }

    private func applyPendingJump() {
        guard schema != nil, !isReading,
              let request = coordinator.pending, request.endpoint == endpoint else { return }
        switch request.target {
        case .attribute(let name):
            selectedTab = .attributes
            jumpAttributeName = name
        case .objectClass(let name):
            selectedTab = .objectClasses
            jumpObjectClassName = name
        }
        coordinator.clear(request)
    }
}

/// A "Label / value" pair stacked vertically, matching how the object class
/// and attribute detail panels present each schema field.
struct SchemaField: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.body)
                .textSelection(.enabled)
        }
    }
}

#Preview {
    SchemaView(connection: SavedConnection(name: "Preview", host: "localhost", port: 389, useSSL: false, baseDN: "", bindDN: ""))
}
