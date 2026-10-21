//
//  KeychainService.swift
//  ldap-studio
//

import Foundation
import Security

enum KeychainService {
    private static let service = "app.ldap-studio.connection-password"
    private static let sshService = "app.ldap-studio.ssh-password"

    /// What's been read or written this session, by service and account —
    /// absent ones too. Every LDAP operation builds its target with the
    /// connection's password, and a Keychain lookup is a round trip to
    /// securityd that took about a millisecond on the main thread each
    /// time; the Home list did one per row on every redraw. Writes below go
    /// through it, so it never disagrees with what the app saved.
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
        SecItemAdd(newItem as CFDictionary, nil)
        cache[cacheKey(service, id)] = password
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
        cache[cacheKey(service, id)] = .some(password)
        return password
    }

    static func deletePassword(for id: UUID) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString,
        ]
        SecItemDelete(query as CFDictionary)
        cache[cacheKey(service, id)] = .some(nil)
        deleteSecret(service: sshService, id: id)
    }

    static func saveSSHPassword(_ password: String, for id: UUID) {
        saveSecret(password, service: sshService, id: id)
    }

    static func readSSHPassword(for id: UUID) -> String? {
        readSecret(service: sshService, id: id)
    }

    private static func saveSecret(_ value: String, service: String, id: UUID) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: id.uuidString]
        SecItemDelete(query as CFDictionary)
        var item = query
        item[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(item as CFDictionary, nil)
        cache[cacheKey(service, id)] = value
    }

    private static func readSecret(service: String, id: UUID) -> String? {
        if let cached = cache[cacheKey(service, id)] { return cached }
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: id.uuidString]
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let found = SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess
        let value = (found ? result as? Data : nil).flatMap { String(data: $0, encoding: .utf8) }
        cache[cacheKey(service, id)] = .some(value)
        return value
    }

    private static func deleteSecret(service: String, id: UUID) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: id.uuidString]
        SecItemDelete(query as CFDictionary)
        cache[cacheKey(service, id)] = .some(nil)
    }
}
