import Foundation

/// One entry in the vault's file browser.
public struct FileNode: Identifiable, Hashable, Sendable {
    public let url: URL
    public let isDirectory: Bool
    public var children: [FileNode]?

    /// URLs are unique within a vault, so they make a stable identity that
    /// survives re-scans without churning SwiftUI's diffing.
    public var id: URL { url }

    public var name: String { url.lastPathComponent }

    /// Filename without the `.md` extension — how notes are referred to in links.
    public var basename: String { url.deletingPathExtension().lastPathComponent }

    public var isMarkdown: Bool { url.pathExtension.lowercased() == "md" }

    public init(url: URL, isDirectory: Bool, children: [FileNode]? = nil) {
        self.url = url
        self.isDirectory = isDirectory
        self.children = children
    }
}

/// Scans a vault folder into a `FileNode` tree.
///
/// Deliberately not an actor: it holds no state, so it can run on any thread and
/// the caller decides where. Scanning is I/O bound and should stay off the main
/// actor for large vaults.
public struct VaultScanner: Sendable {
    /// Directory names never shown in the file browser.
    public static let ignoredDirectories: Set<String> = [
        ".inkstone", ".obsidian", ".git", ".trash", ".DS_Store", "node_modules",
    ]

    /// File extensions Inkstone knows how to open. Everything else is hidden from
    /// the tree but still resolvable as an attachment target.
    public static let visibleExtensions: Set<String> = [
        "md", "markdown", "canvas",
        "png", "jpg", "jpeg", "gif", "webp", "heic", "svg",
        "pdf", "mp3", "m4a", "wav", "mp4", "mov",
    ]

    public init() {}

    public func scan(_ root: URL) -> FileNode {
        FileNode(url: root, isDirectory: true, children: scanChildren(of: root))
    }

    private func scanChildren(of directory: URL) -> [FileNode] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isHiddenKey]
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        var nodes: [FileNode] = []
        for entry in entries {
            let isDirectory = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDirectory {
                guard !Self.ignoredDirectories.contains(entry.lastPathComponent) else { continue }
                nodes.append(FileNode(url: entry, isDirectory: true, children: scanChildren(of: entry)))
            } else {
                guard Self.visibleExtensions.contains(entry.pathExtension.lowercased()) else { continue }
                nodes.append(FileNode(url: entry, isDirectory: false))
            }
        }

        // Folders first, then files, each alphabetically with natural number
        // ordering so "Note 2" sorts before "Note 10".
        return nodes.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    /// Flat list of every Markdown file in the vault, used to build the index.
    public func markdownFiles(in root: URL) -> [URL] {
        var results: [URL] = []
        let keys: [URLResourceKey] = [.isDirectoryKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        for case let url as URL in enumerator {
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDirectory {
                if Self.ignoredDirectories.contains(url.lastPathComponent) {
                    enumerator.skipDescendants()
                }
                continue
            }
            if url.pathExtension.lowercased() == "md" { results.append(url) }
        }
        return results
    }
}
