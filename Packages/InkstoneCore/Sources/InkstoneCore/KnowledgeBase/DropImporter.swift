import Foundation

/// Bringing dropped files and folders into a knowledge base's inbox — by
/// copying (the original stays where it was) or by moving.
///
/// A move is a copy followed by removing the original, and the original is
/// only removed once the copy is complete and identical (same size and
/// SHA-256 for every file). If anything goes wrong, the original stays and
/// a half-made copy is cleaned up: nothing a person drops can be lost.
public enum DropImporter {
    public enum Action: String, Sendable { case copy, move }

    public struct Result: Sendable, Equatable {
        public var source: URL
        /// Where it landed in the vault (relative), nil when it failed.
        public var destination: String?
        /// Moved, but the original could not be removed (read-only, in use):
        /// both copies exist.
        public var originalKept: Bool
        public var error: String?
    }

    public static func importItems(_ urls: [URL], into root: URL, layout: KnowledgeBaseLayout, action: Action) -> [Result] {
        let fm = FileManager.default
        let inbox = root.appending(path: layout.inbox, directoryHint: .isDirectory)
        try? fm.createDirectory(at: inbox, withIntermediateDirectories: true)
        let canonicalRoot = CanonicalPath.of(root)
        return urls.map { source in
            // Something already in the vault: nothing to bring in.
            let real = CanonicalPath.of(source)
            if real == canonicalRoot || real.hasPrefix(canonicalRoot + "/") {
                return Result(source: source, destination: nil, originalKept: true, error: "already in the knowledge base")
            }
            let target = unique(inbox.appending(path: source.lastPathComponent))
            do {
                try fm.copyItem(at: source, to: target)
                guard identical(source, target) else {
                    try? fm.removeItem(at: target)
                    return Result(source: source, destination: nil, originalKept: true, error: "the copy did not match")
                }
                let rel = "\(layout.inbox)/\(target.lastPathComponent)"
                guard action == .move else { return Result(source: source, destination: rel, originalKept: true, error: nil) }
                do {
                    try fm.removeItem(at: source)
                    return Result(source: source, destination: rel, originalKept: false, error: nil)
                } catch {
                    return Result(source: source, destination: rel, originalKept: true, error: error.localizedDescription)
                }
            } catch {
                try? fm.removeItem(at: target)
                return Result(source: source, destination: nil, originalKept: true, error: error.localizedDescription)
            }
        }
    }

    static func unique(_ url: URL) -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path(percentEncoded: false)) else { return url }
        let ext = url.pathExtension, stem = url.deletingPathExtension().lastPathComponent
        var n = 2
        while true {
            let candidate = url.deletingLastPathComponent().appending(path: ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)")
            if !fm.fileExists(atPath: candidate.path(percentEncoded: false)) { return candidate }
            n += 1
        }
    }

    /// Same files, same sizes, same contents — a file, or a folder compared
    /// file by file (hidden files included: a moved folder keeps them).
    static func identical(_ a: URL, _ b: URL) -> Bool {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: a.path(percentEncoded: false), isDirectory: &isDir) else { return false }
        if !isDir.boolValue { return Fingerprint.sha256(a) != nil && Fingerprint.sha256(a) == Fingerprint.sha256(b) }
        func files(_ root: URL) -> [String: Int64] {
            var out: [String: Int64] = [:]
            let base = CanonicalPath.of(root)
            guard let e = fm.enumerator(at: URL(fileURLWithPath: base, isDirectory: true), includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]) else { return out }
            for case let url as URL in e {
                guard let v = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), v.isRegularFile == true else { continue }
                out[String(url.path(percentEncoded: false).dropFirst(base.count))] = Int64(v.fileSize ?? -1)
            }
            return out
        }
        let fa = files(a), fb = files(b)
        guard fa == fb else { return false }
        for rel in fa.keys {
            let x = a.appending(path: rel), y = b.appending(path: rel)
            guard Fingerprint.sha256(x) == Fingerprint.sha256(y) else { return false }
        }
        return true
    }
}
