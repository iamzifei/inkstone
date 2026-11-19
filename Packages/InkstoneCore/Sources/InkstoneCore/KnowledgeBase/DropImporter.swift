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
            let real = CanonicalPath.of(source)
            // Something already in the vault: nothing to bring in.
            if real == canonicalRoot || real.hasPrefix(canonicalRoot + "/") {
                return Result(source: source, destination: nil, originalKept: true, error: "already in the knowledge base")
            }
            // A folder the vault is inside (Documents, a whole drive): it
            // would be copied into itself.
            if canonicalRoot.hasPrefix(real + "/") {
                return Result(source: source, destination: nil, originalKept: true, error: "contains the knowledge base")
            }
            // An iCloud placeholder (a file not downloaded): the bytes are not
            // here, and moving it would remove the file from iCloud.
            if source.lastPathComponent.hasPrefix("."), source.pathExtension == "icloud" {
                return Result(source: source, destination: nil, originalKept: true, error: "not downloaded from iCloud yet")
            }
            if containsPlaceholders(source) {
                return Result(source: source, destination: nil, originalKept: true, error: "has files not downloaded from iCloud yet")
            }
            // Copied under a hidden temporary name first (the organizer
            // skips hidden files, and a crash's leftovers are swept), checked,
            // then given its name — so a half-copied file is never in the
            // inbox, and only our own temporary file is ever removed.
            let temp = inbox.appending(path: Metadata.temporaryName(for: source.lastPathComponent))
            do {
                try fm.copyItem(at: source, to: temp)
            } catch {
                try? fm.removeItem(at: temp)
                return Result(source: source, destination: nil, originalKept: true, error: error.localizedDescription)
            }
            guard identical(source, temp) else {
                try? fm.removeItem(at: temp)
                return Result(source: source, destination: nil, originalKept: true, error: "the copy did not match")
            }
            var target = unique(inbox.appending(path: source.lastPathComponent))
            var placed = false
            for _ in 0..<5 where !placed {
                // moveItem refuses to overwrite: a name taken meanwhile → the next one.
                if (try? fm.moveItem(at: temp, to: target)) != nil { placed = true } else { target = unique(target) }
            }
            guard placed else {
                try? fm.removeItem(at: temp)
                return Result(source: source, destination: nil, originalKept: true, error: "could not name the copy")
            }
            let rel = "\(layout.inbox)/\(target.lastPathComponent)"
            guard action == .move else { return Result(source: source, destination: rel, originalKept: true, error: nil) }
            do {
                try fm.removeItem(at: source)
                return Result(source: source, destination: rel, originalKept: false, error: nil)
            } catch {
                return Result(source: source, destination: rel, originalKept: true, error: error.localizedDescription)
            }
        }
    }

    /// Whether a dropped folder holds iCloud placeholders (files not
    /// downloaded): copying would bring stubs, and a move would remove the
    /// real files from iCloud.
    static func containsPlaceholders(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false), isDirectory: &isDir), isDir.boolValue,
              let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil) else { return false }
        for case let item as URL in e where item.lastPathComponent.hasPrefix(".") && item.pathExtension == "icloud" { return true }
        return false
    }

    /// Temporary copies left by a crash mid-drop (hidden, in the inbox,
    /// made over a day ago) — swept when a knowledge base opens.
    public static func sweepLeftovers(root: URL) {
        Metadata.purgeOldBackups(root: root, now: .now)
    }

    public static func unique(_ url: URL) -> URL {
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

    /// Same files, same contents, same symbolic links (to the same place)
    /// and the same folders, empty ones included — a file, or a folder
    /// compared entry by entry (hidden ones too: a moved folder keeps them).
    static func identical(_ a: URL, _ b: URL) -> Bool {
        let fm = FileManager.default
        func entries(_ root: URL) -> [String: String]? {
            let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]
            func describe(_ url: URL) -> String? {
                guard let v = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
                if v.isSymbolicLink == true {
                    return "link:" + ((try? fm.destinationOfSymbolicLink(atPath: url.path(percentEncoded: false))) ?? "?")
                }
                if v.isDirectory == true { return "dir" }
                if v.isRegularFile == true {
                    // A file that can't be read is never "the same".
                    guard let sha = Fingerprint.sha256(url) else { return nil }
                    return "file:\(v.fileSize ?? -1):" + sha
                }
                return "other"
            }
            guard let top = describe(root) else { return nil }
            var out: [String: String] = ["": top]
            guard top == "dir" else { return out }
            let base = CanonicalPath.of(root)
            guard let e = fm.enumerator(at: URL(fileURLWithPath: base, isDirectory: true), includingPropertiesForKeys: keys) else { return nil }
            for case let url as URL in e {
                guard let d = describe(url) else { return nil }
                out[String(url.path(percentEncoded: false).dropFirst(base.count))] = d
            }
            return out
        }
        guard let ea = entries(a), let eb = entries(b) else { return false }
        return ea == eb
    }
}
