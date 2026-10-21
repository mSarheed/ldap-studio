//
//  ldap_studioApp.swift
//  ldap-studio
//
//  Created by Gabriel Rosa on 07/08/26.
//

import AppKit
import SwiftUI

/// Fires the one-per-day update check once the app is actually up.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { await UpdateChecker.shared.checkOnLaunch() }
    }

    /// Lets in-flight timed-out connection attempts finish unwinding and
    /// closes the SSH tunnels kept warm for reuse (see shutdownCore).
    func applicationWillTerminate(_ notification: Notification) {
        shutdownCore()
    }
}

@main
struct ldap_studioApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    /// One store for the whole app — the Home window edits it, and the
    /// browser windows read it (and write back a trusted certificate when
    /// the user accepts one). Injected into every scene below.
    @State private var store = ConnectionStore()

    init() {
        // This is a multi-window utility app, not a document app — macOS
        // window tabbing (and the empty "New Tab") makes no sense here, so
        // turn it off entirely. Also drops "Show Tab Bar" from the View menu.
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    var body: some Scene {
        WindowGroup {
            Home()
                .environment(store)
                .task { store.load() }
        }
        .commands {
            AppMenuCommands()
        }

        WindowGroup(for: SavedConnection.self) { $connection in
            if let connection {
                LiveConnection(snapshot: connection) { BrowserView(connection: $0) }
                    .environment(store)
            }
        }

        WindowGroup(id: "schema", for: SavedConnection.self) { $connection in
            if let connection {
                LiveConnection(snapshot: connection) { SchemaView(connection: $0) }
                    .environment(store)
            }
        }

        WindowGroup(id: "ldif", for: SavedConnection.self) { $connection in
            if let connection {
                LiveConnection(snapshot: connection) { LDIFEditorView(connection: $0) }
                    .environment(store)
            }
        }

        WindowGroup(id: "editEntry", for: EditEntryRequest.self) { $request in
            if let request {
                LiveConnection(snapshot: request.connection) {
                    EditEntryView(connection: $0, dn: request.dn)
                }
                .environment(store)
            }
        }

        WindowGroup(id: "serverInfo", for: SavedConnection.self) { $connection in
            if let connection {
                LiveConnection(snapshot: connection) { ServerInfoView(connection: $0) }
                    .environment(store)
            }
        }

        Window("About Ldap Studio", id: "about") {
            AboutView()
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
    }
}

/// `WindowGroup(for:)` hands a window the connection as it was when the
/// window opened (or was restored). This swaps that snapshot for the
/// store's current copy, so edits made in the Home window afterwards — a
/// cleared certificate, Read-only, a new host — reach windows that are
/// already open instead of only ones opened after a relaunch.
private struct LiveConnection<Content: View>: View {
    @Environment(ConnectionStore.self) private var store
    let snapshot: SavedConnection
    let content: (SavedConnection) -> Content

    /// The last copy seen in the store. Once the connection is deleted, its
    /// open windows keep the settings they were last using — falling back to
    /// `snapshot` would roll them back to whatever they were opened with.
    @State private var lastStored: SavedConnection?

    var body: some View {
        let stored = store.connections.first { $0.id == snapshot.id }
        content(stored ?? lastStored ?? snapshot)
            .onChange(of: stored, initial: true) { _, stored in
                if let stored { lastStored = stored }
            }
    }
}
