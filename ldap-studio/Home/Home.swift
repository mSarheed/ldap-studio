//
//  Home.swift
//  ldap-studio
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The launch window: app identity and the New/Import actions in a fixed
/// sidebar, saved connections in the detail column. New and Import live
/// here rather than in either column because both columns (and the File
/// menu) trigger them — the sidebar buttons, and the empty-state actions.
struct Home: View {
    @Environment(ConnectionStore.self) private var store

    @State private var isPresentingNewConnection = false
    @State private var importNotice: String?

    var body: some View {
        NavigationSplitView {
            InfoPanel(
                onNewConnection: { isPresentingNewConnection = true },
                onImport: importConnections
            )
            .frame(minWidth: 240)
            .navigationSplitViewColumnWidth(min: 240, ideal: 240, max: 240)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            ConnectionListPanel(
                onNewConnection: { isPresentingNewConnection = true },
                onImport: importConnections
            )
        }
        .frame(minWidth: 760, minHeight: 460)
        .sheet(isPresented: $isPresentingNewConnection) {
            NewConnectionSheet()
        }
        .focusedSceneValue(\.connectionCommands, ConnectionCommands(
            addConnection: { isPresentingNewConnection = true },
            importConnection: importConnections
        ))
        .alert(
            "Finish Importing",
            isPresented: Binding(
                get: { importNotice != nil },
                set: { if !$0 { importNotice = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(importNotice ?? "")
        }
    }

    private func importConnections() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json, UTType(filenameExtension: "lcf") ?? .xml]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            guard let data = try? Data(contentsOf: url) else { return }

            if url.pathExtension.lowercased() == "lcf" {
                importLCF(data)
            } else {
                importJSON(data)
            }
        }
    }

    private func importJSON(_ data: Data) {
        let decoder = JSONDecoder()
        let imported: [ExportableConnection]
        if let array = try? decoder.decode([ExportableConnection].self, from: data) {
            imported = array
        } else if let single = try? decoder.decode(ExportableConnection.self, from: data) {
            imported = [single]
        } else {
            return
        }

        var needingFiles: [String] = []
        for item in imported {
            // Certificate / key files aren't portable (see ExportableConnection).
            if item.authentication == .external || (item.useSSHTunnel && item.sshAuthentication == .privateKey) {
                needingFiles.append(item.name)
            }
            let connection = SavedConnection(
                name: item.name,
                host: item.host,
                port: item.port,
                useSSL: item.useSSL,
                useStartTLS: item.useStartTLS,
                baseDN: item.baseDN,
                bindDN: item.bindDN,
                trustedCertSHA256: item.trustedCertSHA256,
                trustedCACertificates: item.trustedCACertificates,
                checksCertificateHostName: item.checksCertificateHostName,
                bookmarks: item.bookmarks,
                savedFilters: item.savedFilters,
                isFavorite: item.isFavorite,
                isReadOnly: item.isReadOnly,
                chaseReferrals: item.chaseReferrals,
                timeoutSeconds: item.timeoutSeconds,
                authentication: item.authentication,
                saslAuthID: item.saslAuthID,
                saslRealm: item.saslRealm,
                useSSHTunnel: item.useSSHTunnel,
                sshHost: item.sshHost,
                sshPort: item.sshPort,
                sshUsername: item.sshUsername,
                sshAuthentication: item.sshAuthentication,
                sshHostKeySHA256: item.sshHostKeySHA256
            )
            KeychainService.savePassword(item.decodedPassword, for: connection.id)
            KeychainService.saveSSHPassword(item.decodedSSHPassword, for: connection.id)
            store.add(connection)
        }

        if !needingFiles.isEmpty {
            importNotice = "Choose the certificate or key file again (Edit Connection) for: "
                + needingFiles.joined(separator: ", ")
                + ". Those file references can't be carried between Macs."
        }
    }

    /// LDAP Admin (.lcf) files can group accounts into folders — we have no
    /// such concept, so every account gets flattened into one flat list
    /// regardless of how it was organized in the source file.
    private func importLCF(_ data: Data) {
        for account in LCFParser.parse(data) {
            let connection = SavedConnection(
                name: account.name,
                host: account.host,
                port: account.port,
                useSSL: account.useSSL,
                baseDN: account.baseDN,
                bindDN: account.bindDN
            )
            KeychainService.savePassword(account.password, for: connection.id)
            store.add(connection)
        }
    }
}

#Preview {
    Home()
        .environment(ConnectionStore())
}
