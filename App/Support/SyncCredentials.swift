import Foundation
import Security

/// Stores the GitHub personal access token in the Keychain.
///
/// Not in `SettingsData`: that is a plain JSON blob in UserDefaults, readable by
/// anything that can read the preferences file, and it is exactly the sort of
/// place tokens end up in backups and screen shares.
///
/// **The item is synchronizable**, so iCloud Keychain carries it to the user's
/// other devices. That reverses an earlier decision to mark it `ThisDeviceOnly`
/// specifically so a restore could not carry it, and the reason for reversing it
/// is what sync is for: the point of syncing a vault through GitHub is that two
/// devices hold the same notes, and a credential that stops at one device makes
/// the second device a fresh setup rather than the same vault. Chosen
/// deliberately, with the trade understood — the token now lives in Apple's
/// keychain sync and spreads with it.
///
/// Synchronizable items cannot be `ThisDeviceOnly`; the accessibility class
/// moves with it.
enum SyncCredentials {
    private static let service = "com.orris.inkstone.github"
    private static let account = "personal-access-token"

    /// Matches the synchronizable item, the local one, or either — the Keychain
    /// treats `kSecAttrSynchronizable` as part of an item's identity, so a query
    /// that does not mention it only ever sees local items, and a token saved
    /// before this change would look as though it had vanished.
    private static func query(_ scope: Scope) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        switch scope {
        case .synchronizable: query[kSecAttrSynchronizable as String] = kCFBooleanTrue
        case .local: query[kSecAttrSynchronizable as String] = kCFBooleanFalse
        case .any: query[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
        }
        return query
    }

    private enum Scope { case synchronizable, local, any }

    static func token() -> String? {
        #if DEBUG
        // Lets a debug build reach a real repository without typing a token into
        // a Simulator, which is how the repository and branch pickers get looked
        // at rather than assumed — they only appear once a token exists.
        //
        //     SIMCTL_CHILD_INKSTONE_GITHUB_TOKEN=$(gh auth token) xcrun simctl launch …
        //
        // Never in a release build: this reads a credential from the process
        // environment, which is the wrong place for one to live.
        if let injected = ProcessInfo.processInfo.environment["INKSTONE_GITHUB_TOKEN"],
           !injected.isEmpty {
            return injected
        }
        #endif

        var lookup = query(.any)
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        guard SecItemCopyMatching(lookup as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty
        else { return nil }
        return value
    }

    /// Moves a token saved before this change onto iCloud Keychain.
    ///
    /// Not an update: synchronizable is part of an item's identity, so the old
    /// item cannot become the new one. Written first and deleted after, so a
    /// failure leaves the token where it was rather than nowhere.
    @discardableResult
    static func migrateToICloudKeychain() -> Bool {
        var lookup = query(.local)
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        guard SecItemCopyMatching(lookup as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty
        else { return false }

        guard setToken(value) else { return false }
        SecItemDelete(query(.local) as CFDictionary)
        return true
    }

    @discardableResult
    static func setToken(_ token: String?) -> Bool {
        let base = query(.synchronizable)

        let trimmed = token?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else {
            // Both scopes: removing the token has to remove it, not leave a stale
            // local copy that `token()` would then keep finding.
            SecItemDelete(query(.any) as CFDictionary)
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
        // Not ThisDeviceOnly: that class cannot be synchronised, and syncing this
        // is the point.
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(insert as CFDictionary, nil) == errSecSuccess
    }

    static var hasToken: Bool { token() != nil }
}
