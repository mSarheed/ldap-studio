//
//  InfoPanel.swift
//  ldap-studio
//

import AppKit
import SwiftUI

/// The Home window's sidebar: app identity, update check, and the
/// New/Import actions. The split view gives it its Liquid Glass background.
struct InfoPanel: View {
    var onNewConnection: () -> Void
    var onImport: () -> Void

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }

    var body: some View {
        VStack(spacing: 20) {
            Spacer()

            VStack(spacing: 2) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .frame(width: 84, height: 84)
                    .padding(.bottom, 8)
                Text("LDAP Studio")
                    .font(.title3.bold())
                Text("Version \(appVersion)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Button("Check for Updates…") {
                    UpdateChecker.shared.checkForUpdates()
                }
                .buttonStyle(.link)
                .font(.caption)
            }

            VStack(spacing: 8) {
                Button(action: onNewConnection) {
                    Label("New Connection…", systemImage: "plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)

                Button(action: onImport) {
                    Label("Import…", systemImage: "square.and.arrow.down")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
            }
            .controlSize(.large)
            .buttonBorderShape(.capsule)

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
        .frame(maxHeight: .infinity)
    }
}

#Preview {
    InfoPanel(onNewConnection: {}, onImport: {})
        .frame(width: 240, height: 500)
}
