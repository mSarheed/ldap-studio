//
//  MCPServerController.swift
//  ldap-studio
//
//  Owns the MCP server for the app: whether it's on (off until the user
//  turns it on in Settings), its port and access token, and starting and
//  stopping it to match. The token lives in the Keychain; agents present
//  it as a Bearer credential with every request.
//

import Foundation
import Security

@MainActor
@Observable
final class MCPServerController {
    static let shared = MCPServerController()

    enum Status: Equatable {
        case off
        case starting
        case running
        case failed(String)
    }

    static let defaultPort = 47389
    static let portRange = 1024...65535

    private enum Key {
        static let enabled = "mcp.enabled"
        static let port = "mcp.port"
        static let hiddenAttributes = "mcp.hiddenAttributes"
    }

    private(set) var status: Status = .off

    var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            UserDefaults.standard.set(isEnabled, forKey: Key.enabled)
            restart()
        }
    }

    /// The port the server listens on — changing it restarts the server.
    private(set) var port: Int

    /// Extra attributes, comma- or space-separated, kept from agents along
    /// with the always-hidden secrets.
    var extraHiddenAttributes: String {
        didSet { UserDefaults.standard.set(extraHiddenAttributes, forKey: Key.hiddenAttributes) }
    }

    /// Made the first time it's needed — the server starting, or Settings
    /// showing it — so nobody who never uses MCP gets a Keychain item.
    private(set) var token = ""

    var url: String { "http://127.0.0.1:\(port)\(MCPHTTPServer.path)" }

    private var server: MCPHTTPServer?
    /// Bumped on every restart, so a late report from a server that's
    /// since been replaced is ignored.
    private var generation = 0
    private var store: ConnectionStore?

    private init() {
        let defaults = UserDefaults.standard
        isEnabled = defaults.bool(forKey: Key.enabled)
        let savedPort = defaults.integer(forKey: Key.port)
        port = Self.portRange.contains(savedPort) ? savedPort : Self.defaultPort
        extraHiddenAttributes = defaults.string(forKey: Key.hiddenAttributes) ?? ""
    }

    func loadToken() {
        guard token.isEmpty else { return }
        if let saved = KeychainService.readMCPToken(), !saved.isEmpty {
            token = saved
        } else {
            token = Self.newToken()
            KeychainService.saveMCPToken(token)
        }
    }

    /// Where the tools find the saved connections. Called once at launch.
    func attach(_ store: ConnectionStore) {
        self.store = store
    }

    /// At launch: starts the server if the user left it on.
    func startIfEnabled() {
        if isEnabled { restart() }
    }

    /// At quit.
    func shutdown() {
        server?.stop()
        server = nil
    }

    func setPort(_ port: Int) {
        guard Self.portRange.contains(port), port != self.port else { return }
        self.port = port
        UserDefaults.standard.set(port, forKey: Key.port)
        restart()
    }

    /// Replaces the access token. Agents still using the old one are
    /// refused from the next request on.
    func regenerateToken() {
        token = Self.newToken()
        KeychainService.saveMCPToken(token)
        server?.setToken(token)
    }

    private var hiddenAttributeList: [String] {
        extraHiddenAttributes
            .split(whereSeparator: { $0 == "," || $0.isWhitespace })
            .map(String.init)
    }

    private func restart() {
        server?.stop()
        server = nil
        guard isEnabled else {
            status = .off
            return
        }
        status = .starting
        loadToken()
        generation += 1
        let current = generation
        let tools = MCPTools(connections: { [weak store] in store?.connections ?? [] },
                             extraHidden: { [weak self] in self?.hiddenAttributeList ?? [] })
        let endpoint = MCPEndpoint(tools: tools, version: Self.appVersion)
        let server = MCPHTTPServer(
            port: UInt16(port), token: token,
            handler: { body in await endpoint.handle(body) },
            onStateChange: { state in
                Task { @MainActor in MCPServerController.shared.serverChanged(state, generation: current) }
            }
        )
        self.server = server
        server.start()
    }

    private func serverChanged(_ state: MCPHTTPServer.State, generation: Int) {
        guard let server, generation == self.generation else { return }
        switch state {
        case .ready:
            status = .running
        case let .failed(message):
            status = .failed(message)
            server.stop()
            self.server = nil
        }
    }

    /// 32 random bytes, base64url — 256 bits, far past guessing.
    private static func newToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed")
        let encoded = Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "lds_" + encoded
    }

    private static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }
}
