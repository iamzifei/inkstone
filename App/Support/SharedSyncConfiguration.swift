import Foundation
import InkstoneCore

/// Carries the GitHub setup between the user's devices through iCloud's
/// key-value store.
///
/// The point of syncing a vault through GitHub is that two devices hold the same
/// notes. Configured per device, they held the same notes only if you typed the
/// same repository name twice — which is the same fact stated twice, and a second
/// chance to state it differently. This is five short values, which is exactly
/// what the key-value store is for; the notes themselves go through GitHub, and
/// the token through iCloud Keychain.
enum SharedSyncConfiguration {

    private static let key = "com.orris.inkstone.github-sync"

    /// What another device published, if anything.
    static func published() -> GitHubSyncConfiguration? {
        guard let data = NSUbiquitousKeyValueStore.default.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(GitHubSyncConfiguration.self, from: data)
    }

    static func publish(_ configuration: GitHubSyncConfiguration) {
        guard let data = try? JSONEncoder().encode(configuration) else { return }
        let store = NSUbiquitousKeyValueStore.default
        store.set(data, forKey: key)
        // Ask rather than wait: the store syncs on its own schedule, and the
        // interesting moment is usually a few seconds after someone changed a
        // setting and reached for their other device.
        store.synchronize()
    }

    /// Pulls whatever is in the store now. Worth doing at launch: the store is
    /// populated before the app asks, and nothing notifies about a value that
    /// was already there.
    static func refresh() {
        NSUbiquitousKeyValueStore.default.synchronize()
    }

    /// Calls back when another device changes the setup.
    ///
    /// - Returns: the observation token; releasing it stops the callback.
    static func observe(_ onChange: @escaping @MainActor (GitHubSyncConfiguration) -> Void) -> Any {
        NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: NSUbiquitousKeyValueStore.default,
            queue: .main
        ) { notification in
            let changed = notification.userInfo?[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String]
            guard changed?.contains(key) ?? true, let configuration = published() else { return }
            MainActor.assumeIsolated { onChange(configuration) }
        }
    }
}
