import Foundation

/// Files the user has pinned, in the order they pinned them.
///
/// Kept in the vault's own `.inkstone` folder rather than in app settings, and
/// stored as **vault-relative paths**, so the list travels with the vault: open
/// the same folder on another device and the bookmarks are there. A list keyed
/// by absolute path would be right on exactly one machine.
public struct Bookmarks: Codable, Equatable, Sendable {
    /// Vault-relative paths, newest last. Order is the user's, so it is a list
    /// and not a set — and duplicates are prevented on insert rather than by
    /// the type, because reordering is the point.
    public private(set) var paths: [String]

    public init(paths: [String] = []) {
        self.paths = paths
    }

    public var isEmpty: Bool { paths.isEmpty }

    public func contains(_ path: String) -> Bool { paths.contains(path) }

    public mutating func toggle(_ path: String) {
        if let index = paths.firstIndex(of: path) {
            paths.remove(at: index)
        } else {
            paths.append(path)
        }
    }

    public mutating func remove(_ path: String) {
        paths.removeAll { $0 == path }
    }

    /// Follows a file that moved or was renamed, keeping its position.
    public mutating func rename(_ path: String, to newPath: String) {
        guard let index = paths.firstIndex(of: path) else { return }
        paths[index] = newPath
    }

    // MARK: - Storage

    private static func url(in vaultRoot: URL) -> URL {
        vaultRoot.appending(path: ".inkstone", directoryHint: .isDirectory)
            .appending(path: "bookmarks.json")
    }

    public static func load(from vaultRoot: URL) -> Bookmarks {
        guard let data = try? Data(contentsOf: url(in: vaultRoot)),
              let decoded = try? JSONDecoder().decode(Bookmarks.self, from: data)
        else { return Bookmarks() }
        return decoded
    }

    public func save(to vaultRoot: URL) throws {
        let target = Self.url(in: vaultRoot)
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: target, options: .atomic)
    }
}
