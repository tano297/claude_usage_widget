import Foundation
import Security

/// Refresh tokens for roster accounts. The widget never links this file. `roster.json` does not.
enum RosterTokenLoad {
    case token(String)
    case missing
    case unavailable
}

enum RosterSessionStore {
    static let service = "com.claudeusage.app.roster"

    /// Turns off Keychain dialogs for this whole process, once at launch. A call that would need
    /// one fails with errSecInteractionNotAllowed instead: a locked keychain, or an item that a
    /// differently signed build created. This store is the only in-process Keychain user; the
    /// credits read runs in a separate `/usr/bin/security` process and is not affected.
    static func disableKeychainDialogs() {
        SecKeychainSetUserInteractionAllowed(false)
    }

    /// Writes the refresh token, labeled with the email so Keychain Access shows whose it is.
    /// An item that a differently signed build made cannot be updated, so it is deleted and added
    /// again. A locked keychain refuses both, and nothing changes.
    @discardableResult
    static func save(id: UUID, email: String, refreshToken: String) -> Bool {
        let account = id.uuidString
        let data = Data(refreshToken.utf8)
        let label = "Claude Usage: \(email)"
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let update = [kSecValueData as String: data, kSecAttrLabel as String: label] as CFDictionary
        let status = SecItemUpdate(query as CFDictionary, update)
        if status == errSecSuccess { return true }
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrLabel as String] = label
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        if status != errSecItemNotFound {
            guard SecItemDelete(query as CFDictionary) == errSecSuccess else { return false }
        }
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    static func load(id: UUID) -> RosterTokenLoad {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return .missing }
        guard status == errSecSuccess,
              let data = item as? Data,
              let token = String(data: data, encoding: .utf8),
              !token.isEmpty else { return .unavailable }
        return .token(token)
    }

    static func delete(id: UUID) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString
        ]
        SecItemDelete(query as CFDictionary)
    }
}
