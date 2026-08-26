import Foundation
import Security

/// Stores model API keys in the Keychain, one per assistant profile.
///
/// Same reasoning as `SyncCredentials`: `SettingsData` is a plain JSON blob in
/// UserDefaults, readable by anything that can read the preferences file, and a
/// model key is a billable credential.
///
/// **Unlike the GitHub token these are deliberately *not* synchronizable.** The
/// GitHub token is synced because the point of vault sync is that two devices
/// hold the same notes, and a credential that stops at one device makes the
/// second a fresh setup. None of that applies here: a model key is billed per
/// call, several providers issue per-device keys, and an assistant that silently
/// starts working on a restored machine is a bill nobody chose. Someone who
/// wants the same key on two Macs can paste it twice.
enum AssistantCredentials {
    private static let service = "com.orris.inkstone.assistant"

    private static func query(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            // Named explicitly. The Keychain treats synchronizability as part
            // of an item's identity, so a query that omits it matches only
            // local items — which is what we want, but by intent rather than
            // by accident.
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
        ]
    }

    /// Reads a profile's key, or `nil` if none was ever stored.
    static func key(for account: String) -> String? {
        var lookup = query(account: account)
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        guard SecItemCopyMatching(lookup as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let key = String(data: data, encoding: .utf8),
              !key.isEmpty else { return nil }
        return key
    }

    /// Stores a key, or removes it when passed `nil` or an empty string.
    @discardableResult
    static func setKey(_ key: String?, for account: String) -> Bool {
        let base = query(account: account)
        let trimmed = key?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard !trimmed.isEmpty else {
            let status = SecItemDelete(base as CFDictionary)
            // Deleting something already absent is the outcome asked for.
            return status == errSecSuccess || status == errSecItemNotFound
        }
        guard let data = trimmed.data(using: .utf8) else { return false }

        // Update first: SecItemAdd fails with errSecDuplicateItem on an
        // existing account, and adding-then-updating would leave the old key in
        // place on any error path.
        let updated = SecItemUpdate(base as CFDictionary,
                                    [kSecValueData as String: data] as CFDictionary)
        if updated == errSecSuccess { return true }
        guard updated == errSecItemNotFound else { return false }

        var insert = base
        insert[kSecValueData as String] = data
        // `AfterFirstUnlock` rather than `WhenUnlocked`, matching the GitHub
        // token: background work can then use it after a reboot the user has
        // not yet logged into.
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(insert as CFDictionary, nil) == errSecSuccess
    }

    /// Forgets a profile's key. Called when a profile is deleted, so that
    /// removing it from the list is not merely cosmetic.
    static func forget(account: String) {
        SecItemDelete(query(account: account) as CFDictionary)
    }
}
