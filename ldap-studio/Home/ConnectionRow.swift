//
//  ConnectionRow.swift
//  ldap-studio
//

import SwiftUI

struct ConnectionRow: View {
    let connection: SavedConnection
    var isHovering: Bool = false
    var onToggleFavorite: (() -> Void)?
    var onOpen: (() -> Void)?

    /// `.increased` while the row is selected in a focused list — the row
    /// is then drawn on the accent color, so fixed colors switch to white.
    @Environment(\.backgroundProminence) private var backgroundProminence

    private var isProminent: Bool { backgroundProminence == .increased }

    /// A bind DN with no password behind it will simply fail to bind —
    /// worth a quiet nudge. An empty bind DN (anonymous bind) is a normal,
    /// deliberate setup, not something to flag.
    private var isMissingPassword: Bool {
        !connection.bindDN.isEmpty && (KeychainService.readPassword(for: connection.id) ?? "").isEmpty
    }

    private var tlsTitle: String? {
        if connection.useSSL { return "LDAPS" }
        if connection.useStartTLS { return "StartTLS" }
        return nil
    }

    var body: some View {
        HStack(spacing: 8) {
            Button {
                onToggleFavorite?()
            } label: {
                Image(systemName: connection.isFavorite ? "star.fill" : "star")
                    .font(.callout)
                    .foregroundStyle(connection.isFavorite ? (isProminent ? Color.white : Color.yellow) : Color.secondary)
            }
            .buttonStyle(.plain)
            .frame(width: 16)
            .opacity(connection.isFavorite || isHovering ? 1 : 0)
            .help(connection.isFavorite ? "Remove from Favorites" : "Add to Favorites")

            Image(systemName: "server.rack")
                .font(.title2)
                .foregroundStyle(isProminent ? AnyShapeStyle(.white) : AnyShapeStyle(.tint))
                .frame(width: 30)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(connection.name)
                        .font(.headline)
                        .lineLimit(1)
                    if connection.isReadOnly {
                        readOnlyBadge
                    }
                }

                HStack(spacing: 10) {
                    Text(verbatim: "\(connection.host):\(connection.port)")
                        .monospacedDigit()
                        .lineLimit(1)
                        .truncationMode(.middle)
                    securityLabels
                    if isMissingPassword {
                        Label("No password saved", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(isProminent ? Color.white : Color.orange)
                            .help("No password saved for this connection's bind DN")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .labelStyle(CompactLabelStyle())
                .fixedSize(horizontal: false, vertical: true)
            }
            .layoutPriority(1)

            Spacer(minLength: 8)

            Text(connection.bindDN.isEmpty ? "Anonymous" : connection.bindDN)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 220, alignment: .trailing)

            if isHovering {
                Button("Open") { onOpen?() }
                    .buttonStyle(.glass)
                    .controlSize(.small)
            }
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 4)
    }

    private var readOnlyBadge: some View {
        Label("Read-only", systemImage: "lock.fill")
            .labelStyle(CompactLabelStyle())
            .font(.caption2.weight(.semibold))
            .foregroundStyle(isProminent ? Color.white : Color.orange)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(
                Capsule().fill(isProminent ? Color.white.opacity(0.2) : Color.orange.opacity(0.15))
            )
            .fixedSize()
            .help("Read-only — writes are blocked")
    }

    /// LDAPS / StartTLS, and the SSH tunnel when there is one. A plain
    /// connection with no tunnel sends everything — bind password included —
    /// in the clear, so it says so.
    @ViewBuilder
    private var securityLabels: some View {
        if let tlsTitle {
            Label(tlsTitle, systemImage: "lock.shield")
                .fixedSize()
        }
        if connection.useSSHTunnel {
            Label("SSH tunnel", systemImage: "point.3.connected.trianglepath.dotted")
                .fixedSize()
        }
        if tlsTitle == nil && !connection.useSSHTunnel {
            Text("Not encrypted")
                .fixedSize()
        }
    }
}

/// An icon-and-title label with tighter spacing than the default, for the
/// small caption-sized details under a connection's name.
private struct CompactLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.icon
            configuration.title
        }
    }
}

#Preview {
    ConnectionRow(connection: SavedConnection(name: "Corp Directory", host: "ldap.corp.example.com", port: 389, useSSL: false, baseDN: "dc=corp,dc=example,dc=com", bindDN: ""))
        .padding()
}
