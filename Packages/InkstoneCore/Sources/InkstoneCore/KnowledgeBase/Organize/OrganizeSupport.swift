import Foundation
import ImageIO
import CryptoKit

// MARK: - Paths

/// A path with every symlink resolved (`/var` → `/private/var`), so a vault
/// root and the URLs an enumerator returns compare as text. `URL`'s own
/// `resolvingSymlinksInPath` keeps the `/var` form on purpose.
enum CanonicalPath {
    static func of(_ url: URL) -> String {
        let path = url.path(percentEncoded: false)
        guard let resolved = realpath(path, nil) else {
            var p = url.standardizedFileURL.path(percentEncoded: false)
            while p.count > 1, p.hasSuffix("/") { p.removeLast() }
            return p
        }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}

// MARK: - One round at a time

/// An exclusive lock on the vault's organizing (an `flock` on
/// `.inkstone/organize.lock`), so two rounds on this device — two windows, a
/// share arriving mid-round — never interleave their moves and log rows. It
/// does not reach other devices (a sync service has no locks); a file system
/// without `flock` (some network shares) is organized without one.
final class OrganizeLock {
    private var fd: Int32

    init(root: URL) throws {
        let folder = root.appending(path: ".inkstone", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        fd = open(folder.appending(path: "organize.lock").path(percentEncoded: false), O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else { throw OrganizeError.logUnwritable }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            let error = errno
            close(fd); fd = -1
            // Held by another round: busy. Not supported here: go on unlocked.
            if error == EWOULDBLOCK { throw OrganizeError.busy }
        }
    }

    func release() {
        guard fd >= 0 else { return }
        flock(fd, LOCK_UN); close(fd); fd = -1
    }

    deinit { release() }
}

// MARK: - What is already filed

/// The files already in their places (inbox, review, archive, system and
/// hidden folders excluded), for duplicate checks and for the folders an
/// advisor may choose from.
///
/// Fingerprints are cached in `.inkstone/fingerprints.json` by path, size and
/// modification date, so a vault of tens of thousands of files is read once,
/// not on every round. SHA-256 is computed only for files whose size matches
/// something in the inbox (only those can be exact copies).
final class VaultIndex {
    struct Entry: Codable {
        var size: Int64
        var modified: Double
        var created: Double
        var sha: String?
        /// 64-bit hashes as hex: JSON numbers lose bits above 2^53.
        var phash: String?
        var simhash: String?
        var pixels: Double?
        var length: Int?
        var fingerprinted: Bool
    }

    let root: URL
    let layout: KnowledgeBaseLayout
    private(set) var folders: [String] = []
    private var entries: [String: Entry] = [:]
    /// New fingerprints per round; the rest are taken next time (and then
    /// come from the cache).
    static let fingerprintBudget = 4000

    init(root: URL, layout: KnowledgeBaseLayout) {
        self.root = root; self.layout = layout
    }

    var cacheURL: URL { root.appending(path: ".inkstone/fingerprints-v2.json") }

    var excludedTops: Set<String> { Set((layout.systemFolders + [layout.inbox]).map(Organizer.fold)) }

    func refresh(sizesToHash: Set<Int64>) {
        let fm = FileManager.default
        let cached = (try? JSONDecoder().decode([String: Entry].self, from: Data(contentsOf: cacheURL))) ?? [:]
        folders = []
        let dirKeys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey]
        func subfolders(_ url: URL) -> [URL] {
            ((try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: dirKeys, options: [.skipsHiddenFiles])) ?? [])
                .filter { let v = try? $0.resourceValues(forKeys: Set(dirKeys)); return v?.isDirectory == true && v?.isPackage != true }
        }
        let tops = subfolders(root).map(\.lastPathComponent).filter { !excludedTops.contains(Organizer.fold($0)) }.sorted()
        for top in tops {
            folders.append(top)
            folders += subfolders(root.appending(path: top)).map { "\(top)/\($0.lastPathComponent)" }.sorted()
        }

        var fresh: [String: Entry] = [:]
        var budget = Self.fingerprintBudget
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey, .creationDateKey]
        for top in tops {
            let topURL = root.appending(path: top, directoryHint: .isDirectory)
            // Enumerated URLs come back with symlinks resolved; so is the base.
            let base = CanonicalPath.of(topURL)
            guard let e = fm.enumerator(at: URL(fileURLWithPath: base, isDirectory: true), includingPropertiesForKeys: keys,
                                        options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let url as URL in e {
                guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { continue }
                let full = url.path(percentEncoded: false)
                guard full.hasPrefix(base + "/") else { continue }
                let path = "\(top)/" + String(full.dropFirst(base.count + 1))
                let size = Int64(v.fileSize ?? 0)
                let modified = v.contentModificationDate?.timeIntervalSince1970 ?? 0
                var entry: Entry
                if let c = cached[path], c.size == size, c.modified == modified {
                    entry = c
                } else {
                    entry = Entry(size: size, modified: modified, created: v.creationDate?.timeIntervalSince1970 ?? 0,
                                  sha: nil, phash: nil, simhash: nil, pixels: nil, length: nil, fingerprinted: false)
                }
                if entry.sha == nil, sizesToHash.contains(size) { entry.sha = Fingerprint.sha256(url) }
                if !entry.fingerprinted, budget > 0 {
                    budget -= 1
                    entry.fingerprinted = true
                    switch FileKind.detect(url) {
                    case .image:
                        entry.phash = Fingerprint.perceptualHash(url).map { String($0, radix: 16) }
                        entry.pixels = Double(Self.pixels(url))
                    case .markdown, .text:
                        // The same window the inbox side hashes, so the two compare.
                        let text = String(FactsExtractor.readText(url).prefix(FactsExtractor.excerptLength))
                        entry.simhash = Fingerprint.simHash(text).map { String($0, radix: 16) }
                        entry.length = text.count
                    default: break
                    }
                }
                fresh[path] = entry
            }
        }
        entries = fresh
        if let data = try? JSONEncoder().encode(fresh) {
            try? fm.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: cacheURL, options: .atomic)
        }
    }

    func path(forSHA sha: String) -> String? {
        entries.filter { $0.value.sha == sha }.keys.sorted().first
    }

    func nearImage(_ hash: UInt64, within limit: Int) -> (path: String, pixels: CGFloat)? {
        entries.compactMap { path, e in e.phash.flatMap { UInt64($0, radix: 16) }.map { (path, Fingerprint.distance($0, hash), e.pixels ?? 0) } }
            .filter { $0.1 <= limit }.min { ($0.1, $0.0) < ($1.1, $1.0) }.map { ($0.0, CGFloat($0.2)) }
    }

    /// The most similar note (SimHash distance ≤ 12; ≤ 3 is the same
    /// document, 4–12 an overlapping topic).
    func nearText(_ hash: UInt64) -> (path: String, distance: Int)? {
        entries.compactMap { path, e in e.simhash.flatMap { UInt64($0, radix: 16) }.map { (path, Fingerprint.distance($0, hash)) } }
            .filter { $0.1 <= 12 }.min { ($0.1, $0.0) < ($1.1, $1.0) }
    }

    static func pixels(_ url: URL) -> CGFloat {
        guard let s = CGImageSourceCreateWithURL(url as CFURL, nil),
              let p = CGImageSourceCopyPropertiesAtIndex(s, 0, nil) as? [CFString: Any],
              let w = p[kCGImagePropertyPixelWidth] as? Int, let h = p[kCGImagePropertyPixelHeight] as? Int else { return 0 }
        return CGFloat(w * h)
    }
}

// MARK: - The log (policy rule 4)

/// The organizing log: a Markdown table the person can read, and the record
/// undo replays. Each step is written before it is taken. Actions are in
/// English so the log parses the same in every language.
struct OrganizeLog {
    enum Action: String { case begin, end, move, mkdir, rmdir, meta, metaRestored = "meta-restored", undo }
    struct Entry { var batch: String; var action: Action; var from: String; var to: String; var reason: String }

    let root: URL
    let layout: KnowledgeBaseLayout

    static func newBatch(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyyMMdd-HHmmss"
        return "\(f.string(from: date))-\(UUID().uuidString.prefix(6).lowercased())"
    }

    /// Any text as one table cell: backslash, pipe, line breaks escaped, so
    /// every name — however odd — reads back exactly.
    static func escape(_ s: String) -> String {
        var out = ""
        for ch in s {
            switch ch {
            case "\\": out += "\\\\"
            case "|": out += "\\|"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\r\n": out += "\\r\\n"
            case "\t": out += "\\t"
            default:
                // Any other line separator (U+2028, U+0085, VT, FF …) as its
                // code, so a row never breaks across lines.
                if ch.isNewline {
                    out += ch.unicodeScalars.map { "\\u{\(String($0.value, radix: 16))}" }.joined()
                } else {
                    out.append(ch)
                }
            }
        }
        return out
    }

    /// The cells of a row written as `| a | b |`: exactly the one space on
    /// each side of a cell is padding; anything else is the cell's own.
    static func cells(_ line: String) -> [String] {
        var raw: [String] = [], cell = "", escaped = false
        var pendingCode: String?
        for ch in line {
            if escaped {
                switch ch {
                case "n": cell.append("\n")
                case "r": cell.append("\r")
                case "t": cell.append("\t")
                case "u": pendingCode = ""
                default: cell.append(ch)
                }
                escaped = false
            } else if var code = pendingCode {
                // Inside \u{…}
                if ch == "{" { continue }
                if ch == "}" {
                    if let v = UInt32(code, radix: 16), let scalar = Unicode.Scalar(v) { cell.unicodeScalars.append(scalar) }
                    pendingCode = nil
                } else { code.append(ch); pendingCode = code }
            } else if ch == "\\" { escaped = true }
            else if ch == "|" { raw.append(cell); cell = "" }
            else { cell.append(ch) }
        }
        raw.append(cell)
        guard raw.count >= 2 else { return [] }
        return raw.dropFirst().dropLast().map { c in
            var c = Substring(c)
            if c.hasPrefix(" ") { c = c.dropFirst() }
            if c.hasSuffix(" ") { c = c.dropLast() }
            return String(c)
        }
    }

    func append(batch: String, action: Action, from: String, to: String, reason: String, now: Date) throws {
        let time = ISO8601DateFormatter().string(from: now)
        let row = "| \(time) | \(batch) | \(action.rawValue) | \(Self.escape(from)) | \(Self.escape(to)) | \(Self.escape(reason)) |\n"
        try Self.append(row, to: root.appending(path: layout.logFile))
    }

    func entries(batch: String) -> [Entry] {
        guard let text = try? String(contentsOf: root.appending(path: layout.logFile), encoding: .utf8) else { return [] }
        // Any line ending: a sync or an editor may have made them CRLF.
        return text.split(whereSeparator: \.isNewline).compactMap { line in
            guard line.hasPrefix("|") else { return nil }
            let c = Self.cells(String(line))
            guard c.count >= 6, c[1] == batch, let action = Action(rawValue: c[2]) else { return nil }
            return Entry(batch: c[1], action: action, from: c[3], to: c[4], reason: c[5])
        }
    }

    /// Appends a line, starting it on a line of its own. Throws when the file
    /// cannot be written — a round does not go ahead without its record.
    static func append(_ text: String, to url: URL) throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path(percentEncoded: false)) {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard fm.createFile(atPath: url.path(percentEncoded: false), contents: Data()) else { throw OrganizeError.logUnwritable }
        }
        let handle: FileHandle
        do { handle = try FileHandle(forUpdating: url) } catch { throw OrganizeError.logUnwritable }
        defer { try? handle.close() }
        var data = Data(text.utf8)
        let size = try handle.seekToEnd()
        if size > 0 {
            try handle.seek(toOffset: size - 1)
            if try handle.read(upToCount: 1) != Data("\n".utf8) { data.insert(contentsOf: Data("\n".utf8), at: 0) }
            try handle.seekToEnd()
        }
        try handle.write(contentsOf: data)
        try handle.synchronize()
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
            .replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
        return "\"\(escaped)\""
    }

    /// The note with the missing keys added, or nil to leave it alone: no
    /// key missing, a byte-order mark, or a front matter block that is there
    /// but does not parse (its keys cannot be known, so none are added).
    static func withFrontmatter(_ text: String, origin: String, date: Date, tags: [String], summary: String?,
                                layout: KnowledgeBaseLayout) -> String? {
        guard !text.hasPrefix("\u{FEFF}") else { return nil }
        let k = keys(layout)
        let existing = FrontmatterParser.parse(text).frontmatter
        if let range = existing.sourceRange, existing.properties.isEmpty {
            // Fences with something between them that did not parse as YAML.
            let inner = text[range].replacingOccurrences(of: "---", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !inner.isEmpty { return nil }
        }
        if existing.sourceRange == nil, text.hasPrefix("---") { return nil }   // an unclosed block
        let present = Set(existing.properties.keys)
        let day = FileNaming.dateStamp(date)
        let isoDay = "\(day.prefix(4))-\(day.dropFirst(4).prefix(2))-\(day.suffix(2))"
        var lines: [String] = []
        if !present.contains(k.origin) { lines.append("\(k.origin): \(quoted(origin))") }
        if !present.contains(k.organized) { lines.append("\(k.organized): \(isoDay)") }
        if !tags.isEmpty, !present.contains(k.tags), !present.contains("tags"), !present.contains("tag") {
            lines.append("\(k.tags): [\(tags.map(quoted).joined(separator: ", "))]")
        }
        if let summary, !summary.isEmpty, !present.contains(k.summary) { lines.append("\(k.summary): \(quoted(summary))") }
        guard !lines.isEmpty else { return nil }
        let newline = text.contains("\r\n") ? "\r\n" : "\n"
        if let range = existing.sourceRange {
            // Just before the closing fence of the existing block.
            guard let close = text[range].range(of: newline + "---", options: .backwards) else { return nil }
            return String(text[..<close.lowerBound]) + newline + lines.joined(separator: newline) + String(text[close.lowerBound...])
        }
        return "---" + newline + lines.joined(separator: newline) + newline + "---" + newline + text
    }

    /// Adds the keys a note is missing — never changes an existing key or a
    /// byte below the front matter. The original goes to
    /// `.inkstone/undo/<batch>/` and a `meta` row (with the hash of what is
    /// about to be written) to the log, both before the note is touched.
    static func addFrontmatter(_ url: URL, relativePath: String, origin: String, date: Date, tags: [String], summary: String?,
                               layout: KnowledgeBaseLayout, batch: String, root: URL, log: OrganizeLog) throws {
        guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8),
              let updated = withFrontmatter(text, origin: origin, date: date, tags: tags, summary: summary, layout: layout)
        else { return }
        let newData = Data(updated.utf8)
        let folder = ".inkstone/undo/\(batch)"
        let undoFolder = root.appending(path: folder, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: undoFolder, withIntermediateDirectories: true)
        let name = UUID().uuidString
        try data.write(to: undoFolder.appending(path: name))
        let newSHA = SHA256.hash(data: newData).map { String(format: "%02x", $0) }.joined()
        try log.append(batch: batch, action: .meta, from: "\(folder)/\(name)", to: relativePath, reason: newSHA, now: date)
        try overwriteInPlace(url, with: newData)
    }

    /// Replaces a file's contents atomically — written next to it, then
    /// swapped in with `replaceItemAt`, which keeps the original's creation
    /// date, Finder tags and other metadata. A crash at any point leaves
    /// either the old file or the new one, never a half-written one.
    static func overwriteInPlace(_ url: URL, with data: Data) throws {
        let fm = FileManager.default
        let temp = url.deletingLastPathComponent().appending(path: ".\(url.lastPathComponent)\(tempMarker)\(UUID().uuidString.prefix(8))")
        // On disk before the swap, so a power cut cannot swap in an empty file.
        guard fm.createFile(atPath: temp.path(percentEncoded: false), contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        do {
            let handle = try FileHandle(forWritingTo: temp)
            defer { try? handle.close() }
            try handle.write(contentsOf: data)
            try handle.synchronize()
        } catch {
            try? fm.removeItem(at: temp)
            throw error
        }
        do {
            _ = try fm.replaceItemAt(url, withItemAt: temp)
        } catch {
            try? fm.removeItem(at: temp)
            throw error
        }
    }

    /// Backups of rounds older than 30 days (they may hold private notes):
    /// undo of those rounds still moves files back, without re-writing
    /// their properties.
    /// In the name of a rewrite's temporary file: one left by a crash is
    /// removed by `purgeOldBackups` (it is a full copy of a note).
    static let tempMarker = ".inkstone-tmp-"

    static func purgeOldBackups(root: URL, now: Date) {
        let fm = FileManager.default
        // Temporary copies left behind by a crash mid-rewrite.
        if let e = fm.enumerator(at: root, includingPropertiesForKeys: nil, options: [.skipsPackageDescendants]) {
            for case let url as URL in e {
                let name = url.lastPathComponent
                if name == ".git" || name == "node_modules" { e.skipDescendants(); continue }
                if name.hasPrefix("."), name.contains(tempMarker) { try? fm.removeItem(at: url) }
            }
        }
        let folder = root.appending(path: ".inkstone/undo", directoryHint: .isDirectory)
        guard let batches = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        for b in batches {
            let date = (try? b.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? now
            if now.timeIntervalSince(date) > 30 * 86_400 { try? fm.removeItem(at: b) }
        }
    }

    static func csv(_ s: String) -> String {
        s.contains(where: { ",\"\n\r".contains($0) }) ? "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : s
    }

    /// One row in the file index for a file that cannot carry front matter.
    static func indexRow(root: URL, layout: KnowledgeBaseLayout, path: String, kind: FileKind, sha: String?,
                         tags: [String], summary: String?, now: Date) {
        let row = [path, kind.rawValue, FileNaming.dateStamp(now), tags.joined(separator: " "), summary ?? "", sha ?? ""]
            .map(csv).joined(separator: ",") + "\n"
        try? OrganizeLog.append(row, to: root.appending(path: layout.indexFile))
    }

    static func duplicateRow(root: URL, layout: KnowledgeBaseLayout, kept: String, moved: String, basis: String, now: Date) {
        let time = ISO8601DateFormatter().string(from: now)
        let row = "| \(time) | \(OrganizeLog.escape(kept)) | \(OrganizeLog.escape(moved)) | \(OrganizeLog.escape(basis)) |\n"
        try? OrganizeLog.append(row, to: root.appending(path: layout.duplicatesFile))
    }

    /// Undo: the index row and the duplicates row of a file moved back.
    static func removeRows(root: URL, layout: KnowledgeBaseLayout, path: String) {
        remove(from: root.appending(path: layout.indexFile)) { $0.hasPrefix(csv(path) + ",") }
        remove(from: root.appending(path: layout.duplicatesFile)) { line in
            line.hasPrefix("|") && OrganizeLog.cells(String(line)).dropFirst(2).first == path
        }
    }

    static func remove(from url: URL, where matches: (Substring) -> Bool) {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        let kept = text.split(separator: "\n", omittingEmptySubsequences: false).filter { !matches($0) }
        let updated = kept.joined(separator: "\n")
        if updated != text { try? overwriteInPlace(url, with: Data(updated.utf8)) }
    }
}
