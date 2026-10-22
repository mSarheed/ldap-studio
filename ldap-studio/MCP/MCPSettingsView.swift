//
//  MCPSettingsView.swift
//  ldap-studio
//
//  Settings → MCP Server: turning the server on and off, choosing which
//  directories agents may read, and copy-and-paste setup for the common
//  agents, with the access token filled in.
//

import AppKit
import SwiftUI

struct MCPSettingsView: View {
    @Environment(ConnectionStore.self) private var store
    @Bindable private var controller = MCPServerController.shared

    @AppStorage("mcp.settings.client") private var client: AgentClient = .claudeCode
    @State private var isRevealingToken = false
    @State private var isConfirmingNewToken = false
    @State private var portText = ""
    @State private var copied: String?

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $controller.isEnabled) {
                    Text("Let AI agents read your directories")
                    Text("Runs a read-only MCP server that agents such as Claude Code, Codex, Cursor and VS Code can connect to. Only apps on this Mac that have the access token below can reach it.")
                }
                LabeledContent("Status") { statusLabel }
            }

            Section {
                if store.connections.isEmpty {
                    Text("No saved connections yet.").foregroundStyle(.secondary)
                }
                ForEach(sortedConnections) { connection in
                    Toggle(isOn: sharing(connection)) {
                        Text(connection.name)
                        Text(connection.bindDN.isEmpty ? connection.host : "\(connection.host) · \(connection.bindDN)")
                    }
                }
            } header: {
                Text("Shared Directories")
            } footer: {
                Text("Agents see only the directories turned on here, and can't change anything in them: every tool is a search or a read. Passwords and other secrets (userPassword, LAPS passwords, BitLocker keys…) are never shown to them. Agents can read whatever each connection's bind account can, so for the strongest guarantee, share a connection that binds as an account the server only lets read.")
                    .settingsFootnote()
            }

            Section {
                Picker("Agent", selection: $client) {
                    ForEach(AgentClient.allCases) { Text($0.title).tag($0) }
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text(client.instructions)
                    Text(client.setup(url: controller.url, token: maskedToken))
                        .font(.callout.monospaced())
                        .textSelection(.disabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(.quaternary.opacity(0.6), in: .rect(cornerRadius: 8))
                    HStack {
                        copyButton("Copy Setup", key: "setup",
                                   client.setup(url: controller.url, token: controller.token))
                        Spacer()
                        if let note = client.note {
                            Text(note).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                LabeledContent("Server URL") {
                    HStack {
                        Text(controller.url).font(.callout.monospaced()).textSelection(.enabled)
                        copyButton("Copy", key: "url", controller.url)
                    }
                }
            } header: {
                Text("Connect an Agent")
            } footer: {
                Text("The copied setup includes your access token. Keep it out of files you share or commit. After generating a new token or changing the port, copy the setup again and replace the old one. Any agent not listed works too: point it at the server URL and send the header Authorization: Bearer <token>.")
                    .settingsFootnote()
            }

            Section {
                LabeledContent("Token") {
                    HStack {
                        Text(isRevealingToken ? controller.token : maskedToken)
                            .font(.callout.monospaced())
                            .textSelection(.enabled)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button {
                            isRevealingToken.toggle()
                        } label: {
                            Image(systemName: isRevealingToken ? "eye.slash" : "eye")
                        }
                        .buttonStyle(.borderless)
                        .help(isRevealingToken ? "Hide" : "Show")
                        copyButton("Copy", key: "token", controller.token)
                    }
                }
                Button("Generate New Token…") { isConfirmingNewToken = true }
            } header: {
                Text("Access Token")
            } footer: {
                Text("Every request must carry this token. Generate a new one if it may have leaked; agents using the old one stop connecting until you update them.")
                    .settingsFootnote()
            }

            Section("Advanced") {
                LabeledContent("Port") {
                    HStack {
                        TextField("Port", text: $portText)
                            .labelsHidden()
                            .multilineTextAlignment(.trailing)
                            .frame(width: 80)
                            .onSubmit(applyPort)
                        Button("Apply", action: applyPort)
                            .disabled(Int(portText) == controller.port || !isValidPort)
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    TextField("Also hide", text: $controller.extraHiddenAttributes,
                              prompt: Text("e.g. employeeNumber, homePhone"))
                    Text("Attributes, besides the built-in secrets, that agents never see and can't search on.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 640)
        .frame(minHeight: 560, idealHeight: 780)
        .onAppear {
            controller.loadToken()
            portText = String(controller.port)
        }
        .confirmationDialog("Generate a new access token?", isPresented: $isConfirmingNewToken) {
            Button("Generate New Token", role: .destructive) {
                controller.regenerateToken()
                isRevealingToken = false
            }
        } message: {
            Text("Agents set up with the current token will stop connecting until you give them the new one.")
        }
    }

    // MARK: Pieces

    @ViewBuilder
    private var statusLabel: some View {
        switch controller.status {
        case .off:
            Label("Off", systemImage: "circle").foregroundStyle(.secondary)
        case .starting:
            Label("Starting…", systemImage: "circle.dotted").foregroundStyle(.secondary)
        case .running:
            Label("Running on 127.0.0.1:\(String(controller.port))", systemImage: "circle.fill")
                .foregroundStyle(.green)
        case let .failed(message):
            Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
        }
    }

    private var sortedConnections: [SavedConnection] {
        store.connections.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func sharing(_ connection: SavedConnection) -> Binding<Bool> {
        Binding {
            store.latest(connection).allowsMCP
        } set: { isOn in
            var updated = store.latest(connection)
            updated.allowsMCP = isOn
            store.update(updated)
        }
    }

    private var maskedToken: String {
        String(controller.token.prefix(8)) + String(repeating: "•", count: 12)
    }

    private var isValidPort: Bool {
        Int(portText).map(MCPServerController.portRange.contains) ?? false
    }

    private func applyPort() {
        guard let port = Int(portText), isValidPort else {
            portText = String(controller.port)
            return
        }
        controller.setPort(port)
    }

    private func copyButton(_ title: String, key: String, _ text: String) -> some View {
        Button(copied == key ? "Copied" : title) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copied = key
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                if copied == key { copied = nil }
            }
        }
    }
}

private extension Text {
    func settingsFootnote() -> some View {
        font(.caption).foregroundStyle(.secondary)
    }
}

/// The agents with copy-and-paste setup. Anything else that speaks MCP
/// over HTTP works from the URL and header alone.
enum AgentClient: String, CaseIterable, Identifiable {
    case claudeCode, codex, cursor, vsCode, geminiCLI, stdioBridge

    var id: Self { self }

    var title: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .codex: "Codex"
        case .cursor: "Cursor"
        case .vsCode: "VS Code (GitHub Copilot)"
        case .geminiCLI: "Gemini CLI"
        case .stdioBridge: "Claude Desktop and other local-only apps"
        }
    }

    var instructions: String {
        switch self {
        case .claudeCode: "Run this in Terminal. It replaces any earlier LDAP Studio setup:"
        case .codex: "Add this to ~/.codex/config.toml:"
        case .cursor: "Add this to ~/.cursor/mcp.json (or Cursor Settings → MCP → Add):"
        case .vsCode: "Run “MCP: Open User Configuration” from the Command Palette and add:"
        case .geminiCLI: "Add this to ~/.gemini/settings.json:"
        case .stdioBridge: "For apps that can only start a local command, add this to their MCP config (claude_desktop_config.json for Claude Desktop). It bridges to the server with mcp-remote:"
        }
    }

    var note: String? {
        switch self {
        case .claudeCode: "Then run /mcp in Claude Code to check it's connected."
        case .stdioBridge: "Needs Node.js."
        default: nil
        }
    }

    func setup(url: String, token: String) -> String {
        switch self {
        case .claudeCode:
            return #"""
                claude mcp remove --scope user ldap-studio 2>/dev/null
                claude mcp add --transport http --scope user ldap-studio \#(url) --header "Authorization: Bearer \#(token)"
                """#
        case .codex:
            return """
                [mcp_servers.ldap-studio]
                url = "\(url)"
                http_headers = { Authorization = "Bearer \(token)" }
                """
        case .cursor:
            return """
                {
                  "mcpServers": {
                    "ldap-studio": {
                      "url": "\(url)",
                      "headers": { "Authorization": "Bearer \(token)" }
                    }
                  }
                }
                """
        case .vsCode:
            return """
                {
                  "servers": {
                    "ldap-studio": {
                      "type": "http",
                      "url": "\(url)",
                      "headers": { "Authorization": "Bearer \(token)" }
                    }
                  }
                }
                """
        case .geminiCLI:
            return """
                {
                  "mcpServers": {
                    "ldap-studio": {
                      "httpUrl": "\(url)",
                      "headers": { "Authorization": "Bearer \(token)" }
                    }
                  }
                }
                """
        case .stdioBridge:
            return """
                {
                  "mcpServers": {
                    "ldap-studio": {
                      "command": "npx",
                      "args": ["-y", "mcp-remote", "\(url)",
                               "--header", "Authorization:${LDAP_STUDIO_AUTH}"],
                      "env": { "LDAP_STUDIO_AUTH": "Bearer \(token)" }
                    }
                  }
                }
                """
        }
    }
}
