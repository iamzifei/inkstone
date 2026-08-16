import Foundation
import Security

/// Stores the GitHub personal access token in the Keychain.
///
/// Not in `SettingsData`: that is a plain JSON blob in UserDefaults, readable by
/// anything that can read the preferences file, and it is exactly the sort of
/// place tokens end up in backups and screen shares. The Keychain item is marked
/// `ThisDeviceOnly` so it is not carried to another machine by a restore.
enum SyncCredentials {
    private static let service = "com.orris.inkstone.github"
    private static let account = "personal-access-token"

    static func token() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty
        else { return nil }
        return value
    }

    @discardableResult
    static func setToken(_ token: String?) -> Bool {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]

        let trimmed = token?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else {
            SecItemDelete(base as CFDictionary)
            return true
        }

        let data = Data(trimmed.utf8)
        // Update in place if it already exists; SecItemAdd fails with a duplicate
        // otherwise, which would silently leave the old token in use.
        let updated = SecItemUpdate(
            base as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updated == errSecSuccess { return true }

        var insert = base
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(insert as CFDictionary, nil) == errSecSuccess
    }

    static var hasToken: Bool { token() != nil }
}
