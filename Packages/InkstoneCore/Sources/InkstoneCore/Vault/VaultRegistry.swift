import Foundation
import os

/// Persists the list of known vaults and manages security-scoped access to them.
///
/// Sandboxed apps lose filesystem access to user-chosen folders on relaunch. The
/// registry stores a security-scoped bookmark per vault and re-resolves it on
/// startup, so multi-vault switching works without re-prompting the user.
@MainActor
@Observable
public final class VaultRegistry {
    public private(set) var vaults: [Vault] = []

    /// URLs we currently hold a `startAccessingSecurityScopedResource` claim on.
    /// Balanced calls are required, so we track them explicitly rather than
    /// relying on scattered start/stop pairs.
    private var activeScopes: [UUID: URL] = [:]

    private let defaults: UserDefaults
    private let storageKey = "com.orris.inkstone.vaults"
    private let logger = Logger(subsystem: "com.orris.inkstone", category: "VaultRegistry")

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }

    // MARK: - Persistence

    private func load() {
        guard let data = defaults.data(forKey: storageKey) else { return }
        do {
            vaults = try JSONDecoder().decode([Vault].self, from: data)
        } catch {
            logger.error("Failed to decode stored vaults: \(error.localizedDescription)")
        }
    }

    private func save() {
        do {
            defaults.set(try JSONEncoder().encode(vaults), forKey: storageKey)
        } catch {
            logger.error("Failed to encode vaults: \(error.localizedDescription)")
        }
    }

    // MARK: - Registration

    /// Registers a folder the user picked as a vault, creating the bookmark that
    /// lets us reopen it later. Re-registering an existing path refreshes its
    /// bookmark instead of creating a duplicate entry.
    @discardableResult
    public func register(folder url: URL, name: String? = nil) throws -> Vault {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false), isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw VaultError.notADirectory(url)
        }

        // Bookmark creation fails in unsandboxed builds (there is no security
        // scope to capture). That's not fatal — without a sandbox the path alone
        // grants access — so degrade to a path-only vault rather than refusing to
        // open the folder at all.
        let bookmark = try? makeBookmark(for: url)
        if bookmark == nil {
            logger.notice("No security-scoped bookmark for \(url.lastPathComponent, privacy: .public); using path access")
        }

        if let index = vaults.firstIndex(where: { $0.path == url.path(percentEncoded: false) }) {
            vaults[index].bookmark = bookmark
            vaults[index].lastOpened = .now
            save()
            return vaults[index]
        }

        let vault = Vault(
            name: name ?? url.lastPathComponent,
            path: url.path(percentEncoded: false),
            bookmark: bookmark,
            isCloudBacked: url.path(percentEncoded: false).contains("/Mobile Documents/")
        )
        vaults.append(vault)
        save()
        return vault
    }

    /// Removes a vault from the app's list. The folder on disk is untouched —
    /// "forget", never "delete", because the files are the user's, not ours.
    public func forget(_ vault: Vault) {
        endAccess(to: vault)
        vaults.removeAll { $0.id == vault.id }
        save()
    }

    public func rename(_ vault: Vault, to name: String) {
        guard let index = vaults.firstIndex(where: { $0.id == vault.id }) else { return }
        vaults[index].name = name
        save()
    }

    // MARK: - Access

    /// Resolves the vault's bookmark and opens a security scope. Returns the
    /// (possibly relocated) URL the caller should use for all file operations.
    @discardableResult
    public func beginAccess(to vault: Vault) throws -> URL {
        if let existing = activeScopes[vault.id] { return existing }

        guard let bookmark = vault.bookmark else {
            // Vaults inside our own container (e.g. the default iCloud vault)
            // need no bookmark because the sandbox already grants access.
            return vault.url
        }

        var isStale = false
        let url: URL
        do {
            url = try URL(
                resolvingBookmarkData: bookmark,
                options: bookmarkResolutionOptions,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
        } catch {
            logger.error("Bookmark resolution failed for \(vault.name, privacy: .public)")
            throw VaultError.bookmarkResolutionFailed
        }

        guard url.startAccessingSecurityScopedResource() else {
            throw VaultError.accessDenied(url)
        }
        activeScopes[vault.id] = url

        // A stale bookmark still resolves, but should be refreshed so the next
        // launch doesn't have to walk the filesystem to find the folder.
        if isStale, let index = vaults.firstIndex(where: { $0.id == vault.id }) {
            vaults[index].bookmark = try? makeBookmark(for: url)
            vaults[index].path = url.path(percentEncoded: false)
        }

        if let index = vaults.firstIndex(where: { $0.id == vault.id }) {
            vaults[index].lastOpened = .now
        }
        save()
        return url
    }

    public func endAccess(to vault: Vault) {
        guard let url = activeScopes.removeValue(forKey: vault.id) else { return }
        url.stopAccessingSecurityScopedResource()
    }

    // MARK: - Platform bookmark flavours

    private func makeBookmark(for url: URL) throws -> Data {
        #if os(macOS)
        return try url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        #else
        // iOS has no `.withSecurityScope` creation option; a minimal bookmark
        // from a document-picker URL is already security-scoped.
        return try url.bookmarkData(
            options: .minimalBookmark,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        #endif
    }

    private var bookmarkResolutionOptions: URL.BookmarkResolutionOptions {
        #if os(macOS)
        [.withSecurityScope]
        #else
        []
        #endif
    }
}
