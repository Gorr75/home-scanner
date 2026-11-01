import Foundation
import RoomScanCore
import Security

enum KeychainStoreError: Error, Equatable {
    case status(OSStatus)
}

extension KeychainStoreError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .status(let status):
            return "The Keychain could not store the Home Assistant token (status \(status))."
        }
    }
}

/// Long-lived Home Assistant access token. The account name matches
/// `UnconfiguredHomeAssistantClient.tokenAccount`. The token is not written to `home.json`.
enum KeychainTokenStore {
    static let service = UnconfiguredHomeAssistantClient.keychainService
    static let account = UnconfiguredHomeAssistantClient.tokenAccount

    static func read() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        let token = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let token, !token.isEmpty else { return nil }
        return token
    }

    static func save(_ token: String) throws {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            try delete()
            return
        }
        let data = Data(trimmed.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let existing = SecItemCopyMatching(query as CFDictionary, nil)
        if existing == errSecSuccess {
            let updated = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            guard updated == errSecSuccess else { throw KeychainStoreError.status(updated) }
            return
        }
        var insert = query
        for (key, value) in attributes {
            insert[key] = value
        }
        let added = SecItemAdd(insert as CFDictionary, nil)
        guard added == errSecSuccess else { throw KeychainStoreError.status(added) }
    }

    static func delete() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainStoreError.status(status)
        }
    }
}
