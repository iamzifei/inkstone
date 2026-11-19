import Foundation
import ImageIO

// MARK: - Paths

/// A path with every symlink resolved (`/var` → `/private/var`), so a vault
/// root and the URLs an enumerator returns compare as text. `URL`'s own
/// `resolvingSymlinksInPath` keeps the `/var` form on purpose.
enum CanonicalPath {
    static func of(_ url: URL) -> String {
        let path = url.path(percentEncoded: false)
        guard let resolved = realpath(path, nil) else { return url.standardizedFileURL.path(percentEncoded: false) }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}

// MARK: - What is already filed

/// The files already in their places (inbox, review, archive, system and
/// hidden folders excluded), for duplicate checks and for the folders an
/// advisor may choose from.
final class VaultIndex {
    let root: URL
    let layout: KnowledgeBaseLayout
    private(set) var folders: [String] = []
    private var shaByPath: [String: String] = [:]
    private var images: [(path: String, hash: UInt64, pixels: CGFloat)] = []
    private var texts: [(path: String, hash: UInt64, date: Date, length: Int)] = []
    /// Fingerprinting reads files: beyond this many, the rest are skipped.
    static let cap = 5000

    init(root: URL, layout: KnowledgeBaseLayout) {
        self.root = root; self.layout = layout
    }

    var excludedTops: Set<String> { Set(layout.systemFolders + [layout.inbox]) }

    /// - Parameter sizesToHash: only files of these sizes can be exact copies
    ///   of what is in the inbox, so only those are hashed.
    func refresh(sizesToHash: Set<Int64>) {
        let fm = FileManager.default
        folders = []
        // Folders: top level and one below.
        let tops = ((try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
            .map(\.lastPathComponent).filter { !excludedTops.contains($0) }.sorted()
        for top in tops {
            folders.append(top)
            let kids = ((try? fm.contentsOfDirectory(at: root.appending(path: top), includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? [])
                .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
                .map { "\(top)/\($0.lastPathComponent)" }.sorted()
            folders += kids
        }
        // Files.
        var seen = 0
        for top in tops {
            guard let e = fm.enumerator(at: root.appending(path: top), includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .creationDateKey],
                                        options: [.skipsHiddenFiles]) else { continue }
            for case let url as URL in e {
                guard let v = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .creationDateKey]), v.isRegularFile == true else { continue }
                seen += 1
                if seen > Self.cap { return }
                let path = relative(url)
                if sizesToHash.contains(Int64(v.fileSize ?? -1)), let sha = Fingerprint.sha256(url) { shaByPath[path] = sha }
                switch FileKind.detect(url) {
                case .image:
                    if let h = Fingerprint.perceptualHash(url) { images.append((path, h, Self.pixels(url))) }
                case .markdown, .text:
                    let text = FactsExtractor.readText(url)
                    if let h = Fingerprint.simHash(text) { texts.append((path, h, v.creationDate ?? .distantPast, text.count)) }
                default: break
                }
            }
        }
    }

    func path(forSHA sha: String) -> String? {
        shaByPath.filter { $0.value == sha }.keys.sorted().first
    }

    func nearImage(_ hash: UInt64, within limit: Int) -> (path: String, pixels: CGFloat)? {
        images.map { ($0, Fingerprint.distance($0.hash, hash)) }.filter { $0.1 <= limit }
            .min { $0.1 < $1.1 }.map { ($0.0.path, $0.0.pixels) }
    }

    /// The most similar note (SimHash distance ≤ 12; ≤ 3 is the same
    /// document, 4–12 an overlapping topic).
    func nearText(_ hash: UInt64) -> (path: String, distance: Int, date: Date, length: Int)? {
        texts.map { ($0, Fingerprint.distance($0.hash, hash)) }.filter { $0.1 <= 12 }
            .min { $0.1 < $1.1 }.map { ($0.0.path, $0.1, $0.0.date, $0.0.length) }
    }

    static func pixels(_ url: URL) -> CGFloat {
        guard let s = CGImageSourceCreateWithURL(url as CFURL, nil),
              let p = CGImageSourceCopyPropertiesAtIndex(s, 0, nil) as? [CFString: Any],
              let w = p[kCGImagePropertyPixelWidth] as? Int, let h = p[kCGImagePropertyPixelHeight] as? Int else { return 0 }
        return CGFloat(w * h)
    }

    func relative(_ url: URL) -> String {
        let base = CanonicalPath.of(root)
        let prefix = base.hasSuffix("/") ? base : base + "/"
        let path = CanonicalPath.of(url)
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
    }
}

// MARK: - The log (policy rule 4)

/// The organizing log: a Markdown table the person can read, and the record
/// undo replays. Actions are written in English so the log parses the same in
/// every language.
struct OrganizeLog {
    enum Action: String { case move, mkdir, meta, undo }
    struct Entry { var batch: String; var action: Action; var from: String; var to: String }

    let root: URL
    let layout: KnowledgeBaseLayout

    static func newBatch(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyyMMdd-HHmmss"
        return "\(f.string(from: date))-\(UUID().uuidString.prefix(4).lowercased())"
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "|", with: "\\|")
            .replacingOccurrences(of: "\n", with: " ")
    }

    /// Cells of a table row, honouring `\|` and `\\`.
    static func cells(_ line: String) -> [String] {
        var out: [String] = [], cell = "", escaped = false
        for ch in line {
            if escaped { cell.append(ch); escaped = false }
            else if ch == "\\" { escaped = true }
            else if ch == "|" { out.append(cell.trimmingCharacters(in: .whitespaces)); cell = "" }
            else { cell.append(ch) }
        }
        out.append(cell.trimmingCharacters(in: .whitespaces))
        // A row "| a | b |" splits into ["", a, b, ""].
        if out.first == "" { out.removeFirst() }
        if out.last == "" { out.removeLast() }
        return out
    }

    func append(batch: String, action: Action, from: String, to: String, reason: String, now: Date) {
        let url = root.appending(path: layout.logFile)
        let time = ISO8601DateFormatter().string(from: now)
        let row = "| \(time) | \(batch) | \(action.rawValue) | \(Self.escape(from)) | \(Self.escape(to)) | \(Self.escape(reason)) |\n"
        Self.append(row, to: url)
    }

    func entries(batch: String) -> [Entry] {
        guard let text = try? String(contentsOf: root.appending(path: layout.logFile), encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { line in
            guard line.hasPrefix("|") else { return nil }
            let c = Self.cells(String(line))
            guard c.count >= 5, c[1] == batch, let action = Action(rawValue: c[2]) else { return nil }
            return Entry(batch: c[1], action: action, from: c[3], to: c[4])
        }
    }

    static func append(_ text: String, to url: URL) {
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path(percentEncoded: false)) {
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Data().write(to: url)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        // Make sure the row starts on a line of its own.
        if let size = try? handle.offset(), size > 0 {
            try? handle.seek(toOffset: size - 1)
            if let last = try? handle.read(upToCount: 1), last != Data("\n".utf8) { try? handle.write(contentsOf: Data("\n".utf8)) }
            _ = try? handle.seekToEnd()
        }
        try? handle.write(contentsOf: Data(text.utf8))
    }
}

// MARK: - Metadata (policy §3.4)

enum Metadata {
    struct Keys { var origin: String; var organized: String; var tags: String; var summary: String }
    static func keys(_ layout: KnowledgeBaseLayout) -> Keys {
        switch layout.language {
        case .simplifiedChinese: return Keys(origin: "来源", organized: "整理日期", tags: "标签", summary: "摘要")
        case .traditionalChinese: return Keys(origin: "來源", organized: "整理日期", tags: "標籤", summary: "摘要")
        case .english: return Keys(origin: "source", organized: "organized", tags: "tags", summary: "summary")
        }
    }

    /// A YAML double-quoted scalar (valid for any text).
    static func quoted(_ s: String) -> String {
        let escaped = s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ")
        return "\"\(escaped)\""
    }

    /// Adds the keys a note is missing — never changes an existing key or a
    /// byte of the text below the front matter. The original is copied to
    /// `.inkstone/undo/<batch>/` first; returns that copy's vault-relative
    /// path, or nil when nothing was added.
    static func addFrontmatter(_ url: URL, origin: String, date: Date, tags: [String], summary: String?,
                               layout: KnowledgeBaseLayout, batch: String, root: URL) throws -> String? {
        guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else { return nil }
        let k = keys(layout)
        let existing = FrontmatterParser.parse(text).frontmatter
        let present = Set(existing.properties.keys)
        let day = FileNaming.dateStamp(date)
        let isoDay = "\(day.prefix(4))-\(day.dropFirst(4).prefix(2))-\(day.suffix(2))"
        var lines: [String] = []
        if !present.contains(k.origin) { lines.append("\(k.origin): \(quoted(origin))") }
        if !present.contains(k.organized) { lines.append("\(k.organized): \(isoDay)") }
        if !tags.isEmpty, !present.contains(k.tags), !present.contains("tags") {
            lines.append("\(k.tags): [\(tags.map(quoted).joined(separator: ", "))]")
        }
        if let summary, !summary.isEmpty, !present.contains(k.summary) { lines.append("\(k.summary): \(quoted(summary))") }
        guard !lines.isEmpty else { return nil }

        let updated: String
        if let range = existing.sourceRange {
            // Insert just before the closing fence of the existing block.
            let block = text[range]
            guard let close = block.range(of: "\n---", options: .backwards) else { return nil }
            updated = String(text[..<close.lowerBound]) + "\n" + lines.joined(separator: "\n") + String(text[close.lowerBound...])
        } else if text.hasPrefix("---") {
            return nil          // a front matter block that did not parse: leave it alone
        } else {
            updated = "---\n" + lines.joined(separator: "\n") + "\n---\n" + text
        }

        let undoFolder = root.appending(path: ".inkstone/undo/\(batch)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: undoFolder, withIntermediateDirectories: true)
        let backup = undoFolder.appending(path: UUID().uuidString)
        try data.write(to: backup)
        try Data(updated.utf8).write(to: url, options: .atomic)
        return ".inkstone/undo/\(batch)/\(backup.lastPathComponent)"
    }

    static func csv(_ s: String) -> String {
        s.contains(where: { ",\"\n".contains($0) }) ? "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : s
    }

    /// One row in the file index for a file that cannot carry front matter.
    static func indexRow(root: URL, layout: KnowledgeBaseLayout, path: String, url: URL, tags: [String], summary: String?, now: Date) {
        let day = FileNaming.dateStamp(now)
        let row = [path, FileKind.detect(url).rawValue, day, tags.joined(separator: " "), summary ?? "", Fingerprint.sha256(url) ?? ""]
            .map(csv).joined(separator: ",") + "\n"
        OrganizeLog.append(row, to: root.appending(path: layout.indexFile))
    }

    static func removeIndexRow(root: URL, layout: KnowledgeBaseLayout, path: String) {
        let url = root.appending(path: layout.indexFile)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        let prefix = csv(path) + ","
        let kept = text.split(separator: "\n", omittingEmptySubsequences: false).filter { !$0.hasPrefix(prefix) }
        let updated = kept.joined(separator: "\n")
        if updated != text { try? Data(updated.utf8).write(to: url, options: .atomic) }
    }

    static func duplicateRow(root: URL, layout: KnowledgeBaseLayout, kept: String, moved: String, basis: String, now: Date) {
        let time = ISO8601DateFormatter().string(from: now)
        let row = "| \(time) | \(OrganizeLog.escape(kept)) | \(OrganizeLog.escape(moved)) | \(OrganizeLog.escape(basis)) |\n"
        OrganizeLog.append(row, to: root.appending(path: layout.duplicatesFile))
    }
}
