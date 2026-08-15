import Foundation

/// A vault is a plain folder on disk containing Markdown files and attachments.
///
/// This mirrors Obsidian's storage model deliberately: the files on disk are the
/// source of truth, there is no proprietary database, and a vault created by
/// Obsidian can be opened by Inkstone and vice versa. All Inkstone-specific state
/// lives in a hidden `.inkstone` folder inside the vault so it can be gitignored.
public struct Vault: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    /// Display name. Defaults to the folder name but is user-editable.
    public var name: String
    /// Last known location. May be stale after the user moves the folder; the
    /// security-scoped bookmark is the authoritative pointer.
    public var path: String
    /// Security-scoped bookmark, required to regain access after relaunch on
    /// both macOS (App Sandbox) and iOS (files outside the app container).
    public var bookmark: Data?
    /// Whether the folder lives in the app's iCloud Drive ubiquity container.
    public var isCloudBacked: Bool
    public var lastOpened: Date

    public var url: URL { URL(fileURLWithPath: path, isDirectory: true) }

    /// Hidden per-vault config directory (workspace layout, graph settings, cache).
    public var configDirectory: URL { url.appending(path: ".inkstone", directoryHint: .isDirectory) }

    public init(
        id: UUID = UUID(),
        name: String,
        path: String,
        bookmark: Data? = nil,
        isCloudBacked: Bool = false,
        lastOpened: Date = .now
    ) {
        self.id = id
        self.name = name
        self.path = path
        self.bookmark = bookmark
        self.isCloudBacked = isCloudBacked
        self.lastOpened = lastOpened
    }
}

/// Errors surfaced by the vault layer.
///
/// These carry stable, non-localized keys; the app layer maps them onto localized
/// strings so that `InkstoneCore` stays free of resource bundles.
public enum VaultError: Error, Sendable {
    case bookmarkResolutionFailed
    case accessDenied(URL)
    case notADirectory(URL)
}
