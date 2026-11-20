import CryptoKit
import Foundation

/// A folder of rendered images (Mermaid diagrams) on disk: file names derived
/// from everything that changes the picture, and a bound on how many are kept.
/// The app's renderer decides what to draw; this decides where it lives and
/// when it goes.
public struct RenderedImageCache: Sendable {
    public let folder: URL
    /// Most files kept; past it the least recently used go first.
    public let limit: Int

    public init(folder: URL, limit: Int = 300) {
        self.folder = folder
        self.limit = limit
    }

    /// The file for a picture. Every input is part of the name: `stamp` names
    /// the renderer (app build, library), so an update draws again rather than
    /// showing what an older one drew; `scale` is in the name so it can be read
    /// back at the size it was drawn.
    public func file(source: String, isDark: Bool, scale: CGFloat, stamp: String) -> URL {
        let digest = SHA256.hash(data: Data("\(stamp)|\(isDark)|\(scale)|\(source)".utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined()
        return folder.appending(path: "\(name)@\(Int(scale.rounded()))x.png")
    }

    /// Writes a picture, then trims the folder to `limit`.
    public func store(_ data: Data, at file: URL) {
        let fm = FileManager.default
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
        trim()
    }

    /// Reads a picture and marks it used (its modification date is the LRU clock).
    public func load(_ file: URL) -> Data? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        try? FileManager.default.setAttributes([.modificationDate: Date.now], ofItemAtPath: file.path)
        return data
    }

    /// Removes the least recently used pictures beyond `limit`.
    public func trim() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey]),
              files.count > limit else { return }
        let dated = files.map { url in
            (url, (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast)
        }
        for (url, _) in dated.sorted(by: { $0.1 < $1.1 }).prefix(files.count - limit) {
            try? fm.removeItem(at: url)
        }
    }
}
