import Foundation

/// All filesystem mutations for a vault, funnelled through one type.
///
/// Reads/writes are plain UTF-8 so the vault stays interoperable with Obsidian,
/// git, and any text editor. Writes are atomic to survive a crash or an iCloud
/// upload starting mid-save.
public struct NoteStore: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    // MARK: - Reading

    public func read(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        // Fall back to the platform's best guess for legacy files written by
        // other tools; a note that won't open is worse than one with odd glyphs.
        return String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
            ?? ""
    }

    // MARK: - Writing

    public func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(text.utf8).write(to: url, options: .atomic)
    }

    /// Creates a new note, appending " 1", " 2", … if the name is taken.
    @discardableResult
    public func createNote(named name: String, in directory: URL? = nil, content: String = "") throws -> URL {
        let folder = directory ?? root
        let url = uniqueURL(for: name.isEmpty ? "Untitled" : name, extension: "md", in: folder)
        try write(content, to: url)
        return url
    }

    @discardableResult
    public func createFolder(named name: String, in directory: URL? = nil) throws -> URL {
        let url = uniqueURL(for: name, extension: nil, in: directory ?? root)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Moves a file to the system trash on macOS, or to the vault's `.trash`
    /// folder on iOS where `trashItem` isn't available for arbitrary URLs.
    public func delete(_ url: URL) throws {
        #if os(macOS)
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        #else
        let trash = root.appending(path: ".trash", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        let destination = uniqueURL(
            for: url.deletingPathExtension().lastPathComponent,
            extension: url.pathExtension.isEmpty ? nil : url.pathExtension,
            in: trash
        )
        try FileManager.default.moveItem(at: url, to: destination)
        #endif
    }

    public func move(_ url: URL, to destinationDirectory: URL) throws -> URL {
        let destination = uniqueURL(
            for: url.deletingPathExtension().lastPathComponent,
            extension: url.pathExtension.isEmpty ? nil : url.pathExtension,
            in: destinationDirectory
        )
        try FileManager.default.moveItem(at: url, to: destination)
        return destination
    }

    /// Renames a note on disk. Callers are expected to follow up with
    /// `LinkRewriter` so `[[old name]]` references elsewhere keep pointing here.
    public func rename(_ url: URL, to newBasename: String) throws -> URL {
        let ext = url.pathExtension
        let destination = url
            .deletingLastPathComponent()
            .appending(path: ext.isEmpty ? newBasename : "\(newBasename).\(ext)")
        guard destination != url else { return url }
        guard !FileManager.default.fileExists(atPath: destination.path(percentEncoded: false)) else {
            throw CocoaError(.fileWriteFileExists)
        }
        try FileManager.default.moveItem(at: url, to: destination)
        return destination
    }

    // MARK: - Helpers

    /// Returns a URL in `directory` that doesn't collide with an existing file.
    public func uniqueURL(for basename: String, extension ext: String?, in directory: URL) -> URL {
        func candidate(_ suffix: Int) -> URL {
            let name = suffix == 0 ? basename : "\(basename) \(suffix)"
            let url = directory.appending(path: name)
            return ext.map { url.appendingPathExtension($0) } ?? url
        }
        var index = 0
        var url = candidate(index)
        while FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
            index += 1
            url = candidate(index)
        }
        return url
    }

    public func modificationDates(of url: URL) -> (created: Date, modified: Date) {
        let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
        return (values?.creationDate ?? .now, values?.contentModificationDate ?? .now)
    }
}
