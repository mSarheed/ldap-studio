//
//  KeychainService.swift
//  ldap-studio
//

import Foundation
import Security

enum KeychainService {
    private static let service = "app.ldap-studio.connection-password"
    private static let sshService = "app.ldap-studio.ssh-password"
    private static let mcpService = "app.ldap-studio.mcp-token"
    /// There's one MCP access token, not one per connection; the helpers
    /// below key everything by a UUID, so it gets a fixed one.
    private static let mcpTokenAccount = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    /// What's been read or written this session, by service and account —
    /// absent ones too, but not lookups that failed some other way (a locked
    /// keychain, access denied), which are tried again next time. Every LDAP
    /// operation builds its target with the connection's password, and a
    /// Keychain lookup is a round trip to securityd that took about a
    /// millisecond on the main thread each time; the Home list did one per
    /// row on every redraw. Writes below go through it, so it never
    /// disagrees with what the app saved.
    private static var cache: [String: String?] = [:]

    private static func cacheKey(_ service: String, _ id: UUID) -> String { "\(service)/\(id.uuidString)" }

    static func savePassword(_ password: String, for id: UUID) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString,
        ]

        // Remove any existing item for this connection before adding the fresh one.
        SecItemDelete(query as CFDictionary)

        var newItem = query
        newItem[kSecValueData as String] = Data(password.utf8)
        rememberWrite(password, status: SecItemAdd(newItem as CFDictionary, nil), service, id)
    }

    static func readPassword(for id: UUID) -> String? {
        if let cached = cache[cacheKey(service, id)] { return cached }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        let password = (status == errSecSuccess ? result as? Data : nil).flatMap { String(data: $0, encoding: .utf8) }
        remember(password, status: status, service, id)
        return password
    }

    static func deletePassword(for id: UUID) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString,
        ]
        rememberWrite(nil, status: SecItemDelete(query as CFDictionary), service, id)
        deleteSecret(service: sshService, id: id)
    }

    static func saveSSHPassword(_ password: String, for id: UUID) {
        saveSecret(password, service: sshService, id: id)
    }

    static func readSSHPassword(for id: UUID) -> String? {
        readSecret(service: sshService, id: id)
    }

    static func saveMCPToken(_ token: String) {
        saveSecret(token, service: mcpService, id: mcpTokenAccount)
    }

    static func readMCPToken() -> String? {
        readSecret(service: mcpService, id: mcpTokenAccount)
    }

    private static func saveSecret(_ value: String, service: String, id: UUID) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: id.uuidString]
        SecItemDelete(query as CFDictionary)
        var item = query
        item[kSecValueData as String] = Data(value.utf8)
        rememberWrite(value, status: SecItemAdd(item as CFDictionary, nil), service, id)
    }

    private static func readSecret(service: String, id: UUID) -> String? {
        if let cached = cache[cacheKey(service, id)] { return cached }
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: id.uuidString]
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        let value = (status == errSecSuccess ? result as? Data : nil).flatMap { String(data: $0, encoding: .utf8) }
        remember(value, status: status, service, id)
        return value
    }

    private static func remember(_ value: String?, status: OSStatus, _ service: String, _ id: UUID) {
        guard status == errSecSuccess || status == errSecItemNotFound else { return }
        cache[cacheKey(service, id)] = .some(value)
    }

    /// After a save (`value`) or delete (nil): remember the outcome only if
    /// the Keychain took it — deleting one that wasn't there counts — and
    /// otherwise forget what's cached, so the next read asks the Keychain
    /// what it actually holds.
    private static func rememberWrite(_ value: String?, status: OSStatus, _ service: String, _ id: UUID) {
        if status == errSecSuccess || (value == nil && status == errSecItemNotFound) {
            cache[cacheKey(service, id)] = .some(value)
        } else {
            cache.removeValue(forKey: cacheKey(service, id))
        }
    }

    private static func deleteSecret(service: String, id: UUID) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: id.uuidString]
        rememberWrite(nil, status: SecItemDelete(query as CFDictionary), service, id)
    }
}
