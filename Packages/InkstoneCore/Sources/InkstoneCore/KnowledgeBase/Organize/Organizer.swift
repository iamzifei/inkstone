import Foundation

/// One planned move. `from`/`to` are vault-relative.
public struct OrganizeMove: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable, Codable {
        case file           // filed into its place
        case review         // unsure, or looks like something already filed
        case privateFile    // into the private folder
        case duplicate      // an exact copy: into to-delete
    }
    public var id: String { from }
    public var from: String
    public var to: String
    public var kind: Kind
    public var reason: String
    /// For duplicates: the copy that stays.
    public var kept: String?
    public var tags: [String] = []
    public var summary: String?
    /// The file's SHA-256 when planned: a file changed since is left alone.
    public var sha: String?
}

/// A file that looks like one already filed (a resized picture, a near
/// identical note) or overlaps it: reported for the person to decide, never
/// acted on (policy §4).
public struct MergeSuggestion: Sendable, Equatable {
    public var a: String
    public var b: String
}

/// The change plan of one round (policy rule 3).
public struct ChangePlan: Sendable {
    public var moves: [OrganizeMove]
    public var suggestions: [MergeSuggestion]
    /// More than 20 files, or any deduplication: the person confirms first.
    public var needsConfirmation: Bool {
        moves.count > 20 || moves.contains { $0.kind == .duplicate }
    }
    public var isEmpty: Bool { moves.isEmpty }
    public func count(_ kind: OrganizeMove.Kind) -> Int { moves.filter { $0.kind == kind }.count }
}

public struct OrganizeResult: Sendable {
    public struct Failure: Sendable, Equatable { public var from: String; public var reason: String }
    public var batch: String
    public var moved: Int
    /// Moves that were not made (the file changed, a folder could not be
    /// created …). Those files stay where they were.
    public var failures: [Failure]
    public var plan: ChangePlan
}

public struct UndoResult: Sendable {
    public var restored: Int
    /// What could not be put back, and why (a note edited since, a file moved
    /// on by hand) — left as it is rather than overwritten.
    public var skipped: [String]
}

public enum OrganizeError: Error, Equatable {
    case alreadyUndone
    case nothingToUndo
    case logUnwritable
    case busy
}

/// Files what lands in the inbox, by the knowledge base's rules.
///
/// Never deletes and never rewrites a file's text: it moves, renames, and adds
/// front matter keys that are missing (the original bytes are kept for undo).
/// Every step is written to the log before it is taken, and `undo(batch:)`
/// replays a round backwards — without overwriting anything changed since.
public struct Organizer: Sendable {
    public let root: URL
    public let layout: KnowledgeBaseLayout
    public let advisor: PlacementAdvisor?
    public let now: @Sendable () -> Date
    public let ocr: Bool
    /// Refresh the entry files' auto blocks after a round (a setting).
    public let maintainEntryFiles: Bool

    public init(root: URL, layout: KnowledgeBaseLayout, advisor: PlacementAdvisor?, ocr: Bool = false,
                maintainEntryFiles: Bool = true, now: @escaping @Sendable () -> Date = { .now }) {
        self.root = root; self.layout = layout; self.advisor = advisor; self.ocr = ocr
        self.maintainEntryFiles = maintainEntryFiles; self.now = now
    }

    // MARK: - Inbox

    /// What is waiting in the inbox, at any depth: files, and — kept whole —
    /// packages (`.rtfd`, `.textbundle` …) and folders that are a project of
    /// their own (they hold a `.git`). Hidden files excluded; stable order.
    public static func inboxFiles(root: URL, layout: KnowledgeBaseLayout) throws -> [URL] {
        let inbox = root.appending(path: layout.inbox, directoryHint: .isDirectory)
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isPackageKey]
        guard let e = FileManager.default.enumerator(at: inbox, includingPropertiesForKeys: keys,
                                                     options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var out: [URL] = []
        for case let url as URL in e {
            guard let v = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            if v.isRegularFile == true { out.append(url); continue }
            if v.isDirectory == true, v.isPackage == true || isProjectFolder(url) {
                out.append(url)
                e.skipDescendants()
            }
        }
        return out.sorted { $0.path(percentEncoded: false) < $1.path(percentEncoded: false) }
    }

    static func isProjectFolder(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.appending(path: ".git").path(percentEncoded: false))
    }

    var canonicalRoot: String { CanonicalPath.of(root) }

    /// The vault-relative path of something that exists, following symlinks;
    /// nil when it resolves outside the vault.
    func relative(_ url: URL) -> String? {
        let base = canonicalRoot
        let path = CanonicalPath.of(url)
        guard path.hasPrefix(base + "/") else { return nil }
        return String(path.dropFirst(base.count + 1))
    }

    /// A vault-relative path that stays in the vault: not absolute, no `..`,
    /// and — following the symlinks of the folders that already exist — still
    /// under the root.
    func resolveInside(_ relative: String) -> URL? {
        let parts = relative.split(separator: "/")
        guard !relative.hasPrefix("/"), !relative.hasPrefix("~"), !parts.isEmpty,
              !parts.contains(where: { $0 == ".." || $0 == "." }) else { return nil }
        let url = root.appending(path: relative)
        var ancestor = url.deletingLastPathComponent()
        let fm = FileManager.default
        while !fm.fileExists(atPath: ancestor.path(percentEncoded: false)) { ancestor = ancestor.deletingLastPathComponent() }
        let real = CanonicalPath.of(ancestor), base = canonicalRoot
        guard real == base || real.hasPrefix(base + "/") else { return nil }
        return url
    }

    // MARK: - Plan

    public func plan() async throws -> ChangePlan {
        let inbox = try Self.inboxFiles(root: root, layout: layout)
        guard !inbox.isEmpty else { return ChangePlan(moves: [], suggestions: []) }
        var facts: [FileFacts] = []
        for url in inbox {
            try Task.checkCancellation()
            facts.append(await FactsExtractor.facts(for: url, ocr: ocr))
        }

        let index = VaultIndex(root: root, layout: layout)
        index.refresh(sizesToHash: Set(facts.filter { !$0.isFolder }.map(\.size)))
        let rulesText = (try? String(contentsOf: root.appending(path: layout.rulesFile), encoding: .utf8)) ?? ""
        let rules = OrganizingRules(rulesFileText: rulesText)
        let context = AdvisorContext(layout: layout, folders: index.folders, rules: rulesText)

        var moves: [OrganizeMove] = []
        var suggestions: [MergeSuggestion] = []
        var taken = Set<String>()                       // destinations already planned (folded)
        var plannedBySHA: [String: String] = [:]        // copies within this inbox: sha → where the first goes

        func reserve(_ folder: String, _ name: String) -> String {
            let ext = (name as NSString).pathExtension
            let stem = (name as NSString).deletingPathExtension
            var candidate = "\(folder)/\(name)"
            var n = 2
            // Case- and normalization-insensitive, like the file system.
            while taken.contains(Self.fold(candidate))
                    || FileManager.default.fileExists(atPath: root.appending(path: candidate).path(percentEncoded: false)) {
                candidate = "\(folder)/" + (ext.isEmpty ? "\(stem)-\(n)" : "\(stem)-\(n).\(ext)")
                n += 1
            }
            taken.insert(Self.fold(candidate))
            return candidate
        }

        for f in facts {
            try Task.checkCancellation()
            guard let from = relative(f.url) else { continue }
            let original = f.url.lastPathComponent

            // A package or a project folder: kept whole, for the person.
            if f.isFolder {
                moves.append(OrganizeMove(from: from, to: reserve(layout.review, original), kind: .review,
                                          reason: "folder kept whole"))
                continue
            }

            // Exact copies — of something filed, or of an earlier inbox file.
            if let sha = f.sha256, let kept = index.path(forSHA: sha) ?? plannedBySHA[sha] {
                moves.append(OrganizeMove(from: from, to: reserve(layout.trash, original), kind: .duplicate,
                                          reason: "SHA-256", kept: kept, sha: sha))
                continue
            }

            var placed = place(f, rules: rules, index: index)
            if placed.kind == .review, let advisor, let advice = try? await advisor.advise(f, context: context),
               let checked = accept(advice) {
                placed = checked
            }

            // Looks like something already filed: the person decides.
            if placed.kind != .privateFile {
                if let ph = f.perceptualHash, let near = index.nearImage(ph, within: 5) {
                    placed = Placed(folder: layout.review, kind: .review, reason: "looks like \(near.path)")
                    suggestions.append(MergeSuggestion(a: from, b: near.path))
                } else if let sh = f.simHash, let near = index.nearText(sh) {
                    suggestions.append(MergeSuggestion(a: from, b: near.path))
                    if near.distance <= 3 {
                        placed = Placed(folder: layout.review, kind: .review, reason: "looks like a version of \(near.path)")
                    }
                }
            }

            let name = placed.kind == .review
                ? original
                : FileNaming.name(keywords: placed.keywords ?? cleanKeywords(f), ext: f.ext, date: f.contentDate)
            let to = reserve(placed.folder, name)
            let isPrivate = placed.kind == .privateFile
            moves.append(OrganizeMove(from: from, to: to, kind: placed.kind, reason: placed.reason, kept: nil,
                                      tags: isPrivate ? [] : placed.tags, summary: isPrivate ? nil : placed.summary,
                                      sha: f.sha256))
            if let sha = f.sha256 { plannedBySHA[sha] = to }
        }
        return ChangePlan(moves: moves, suggestions: suggestions)
    }

    /// Case- and Unicode-normalization-folded, as APFS compares names.
    static func fold(_ path: String) -> String {
        path.precomposedStringWithCanonicalMapping.lowercased()
    }

    struct Placed {
        var folder: String
        var kind: OrganizeMove.Kind
        var reason: String
        var keywords: String?
        var tags: [String] = []
        var summary: String?
    }

    /// Without an advisor: privacy (a hard rule, before anything), the
    /// person's rules, a project or area named in the file, media by type and
    /// month — else review.
    func place(_ f: FileFacts, rules: OrganizingRules, index: VaultIndex) -> Placed {
        if let word = PrivacyCheck.looksPrivate(f) {
            return Placed(folder: layout.privateFolder, kind: .privateFile, reason: "private: \(word)")
        }
        if let rule = rules.match(f), let folder = sanitize(rule.folder) {
            return Placed(folder: folder, kind: .file, reason: "rule: \(rule.keyword)")
        }
        let haystack = "\(f.name) \(f.title ?? "")".lowercased()
        if let folder = index.folders
            .filter({ $0.hasPrefix(layout.projects + "/") || $0.hasPrefix(layout.areas + "/") || $0.hasPrefix(layout.resources + "/") })
            .sorted(by: { ($0 as NSString).lastPathComponent.count > ($1 as NSString).lastPathComponent.count })
            .first(where: { let leaf = ($0 as NSString).lastPathComponent.lowercased(); return leaf.count >= 2 && haystack.contains(leaf) }) {
            return Placed(folder: folder, kind: .file, reason: "named: \((folder as NSString).lastPathComponent)")
        }
        let month = FileNaming.month(f.contentDate)
        switch f.kind {
        case .image: return Placed(folder: "\(layout.mediaImages)/\(month)", kind: .file, reason: "image")
        case .video: return Placed(folder: "\(layout.mediaVideo)/\(month)", kind: .file, reason: "video")
        case .audio: return Placed(folder: "\(layout.mediaAudio)/\(month)", kind: .file, reason: "audio")
        default: return Placed(folder: layout.review, kind: .review, reason: "unsure")
        }
    }

    func accept(_ advice: PlacementAdvice) -> Placed? {
        if advice.isPrivate {
            return Placed(folder: layout.privateFolder, kind: .privateFile, reason: "private: \(advice.reason)",
                          keywords: advice.title)
        }
        guard advice.confidence >= 0.7, let folder = sanitize(advice.folder) else { return nil }
        return Placed(folder: folder, kind: .file, reason: advice.reason, keywords: advice.title,
                      tags: advice.tags, summary: advice.summary)
    }

    /// A folder a file may be filed into: relative, inside the vault, at
    /// most three levels, not in the machinery (system, archive, review) or
    /// the inbox — compared as the file system does, ignoring case. Nil
    /// otherwise.
    func sanitize(_ folder: String) -> String? {
        let parts = folder.split(separator: "/").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !folder.hasPrefix("/"), !folder.hasPrefix("~"), !parts.isEmpty, parts.count <= 3,
              !parts.contains(where: { $0 == ".." || $0 == "." || $0.hasPrefix(".") || $0.contains("\0") || $0.contains("\n") })
        else { return nil }
        let joined = parts.joined(separator: "/")
        for forbidden in layout.systemFolders + [layout.inbox] where Self.isUnder(joined, forbidden) { return nil }
        return joined
    }

    static func isUnder(_ path: String, _ folder: String) -> Bool {
        let p = fold(path), f = fold(folder)
        return p == f || p.hasPrefix(f + "/")
    }

    func cleanKeywords(_ f: FileFacts) -> String {
        if let title = f.title, !title.isEmpty, [.markdown, .pdf, .html].contains(f.kind) { return title }
        return f.name
    }

    /// Where a move of this kind may land — checked again when executing: a
    /// plan is data, and may have been changed since it was made.
    func allowed(_ move: OrganizeMove) -> Bool {
        let folder = (move.to as NSString).deletingLastPathComponent
        guard !folder.isEmpty, !Self.isUnder(folder, layout.inbox) else { return false }
        switch move.kind {
        case .duplicate: return Self.isUnder(folder, layout.trash)
        case .review: return Self.isUnder(folder, layout.review)
        case .privateFile: return Self.isUnder(folder, layout.privateFolder)
        case .file: return sanitize(folder) != nil
        }
    }

    // MARK: - Execute

    /// Makes the moves of a plan. Throws only before anything is moved (the
    /// log cannot be written, another round is running); after that, a move
    /// that cannot be made is reported in `failures` and its file stays put.
    @discardableResult
    public func execute(_ plan: ChangePlan) throws -> OrganizeResult {
        let lock = try OrganizeLock(root: root)
        defer { lock.release() }
        let fm = FileManager.default
        let batch = OrganizeLog.newBatch(now())
        let log = OrganizeLog(root: root, layout: layout)
        try log.append(batch: batch, action: .begin, from: "", to: "", reason: "\(plan.moves.count)", now: now())
        Metadata.purgeOldBackups(root: root, now: now())

        var moved = 0
        var failures: [OrganizeResult.Failure] = []
        var actual: [String: String] = [:]          // planned destination → where it really went
        var emptied = Set<String>()                 // inbox folders a move may have left empty
        func fail(_ move: OrganizeMove, _ why: String) { failures.append(.init(from: move.from, reason: why)) }

        for move in plan.moves {
            guard Self.isUnder(move.from, layout.inbox), move.from.count > layout.inbox.count,
                  let fromURL = resolveInside(move.from),
                  fm.fileExists(atPath: fromURL.path(percentEncoded: false)) else { fail(move, "not in the inbox"); continue }
            guard allowed(move), var toURL = resolveInside(move.to) else { fail(move, "destination not allowed"); continue }
            if let sha = move.sha, Fingerprint.sha256(fromURL) != sha { fail(move, "changed since planned"); continue }
            var kept = move.kept
            if move.kind == .duplicate {
                kept = kept.map { actual[$0] ?? $0 }
                guard let k = kept, let keptURL = resolveInside(k), let sha = move.sha,
                      Fingerprint.sha256(keptURL) == sha else { fail(move, "the copy to keep is gone or changed"); continue }
            }
            if fm.fileExists(atPath: toURL.path(percentEncoded: false)) { toURL = uniqueURL(toURL) }

            do {
                for created in missingFolders(toURL.deletingLastPathComponent()) {
                    try log.append(batch: batch, action: .mkdir, from: "", to: lexicalRelative(created), reason: "", now: now())
                    try fm.createDirectory(at: created, withIntermediateDirectories: false)
                }
                // Following symlinks, the folder must still be in the vault.
                guard let parent = relative(toURL.deletingLastPathComponent()) else {
                    fail(move, "destination outside the vault"); continue
                }
                let toRelative = "\(parent)/\(toURL.lastPathComponent)"
                try log.append(batch: batch, action: .move, from: move.from, to: toRelative,
                               reason: "\(move.kind.rawValue): \(move.reason)", now: now())
                try fm.moveItem(at: fromURL, to: toURL)
                actual[move.to] = toRelative
                moved += 1
                emptied.insert((move.from as NSString).deletingLastPathComponent)

                switch move.kind {
                case .file, .privateFile:
                    let kind = FileKind.detect(toURL)
                    if kind == .markdown {
                        do {
                            try Metadata.addFrontmatter(toURL, relativePath: toRelative, origin: move.from, date: now(),
                                                        tags: move.tags, summary: move.summary, layout: layout,
                                                        batch: batch, root: root, log: log)
                        } catch {
                            fail(move, "moved, but its properties could not be added")
                        }
                    } else {
                        Metadata.indexRow(root: root, layout: layout, path: toRelative, kind: kind,
                                          sha: move.sha, tags: move.tags, summary: move.summary, now: now())
                    }
                case .duplicate:
                    Metadata.duplicateRow(root: root, layout: layout, kept: kept ?? "", moved: toRelative, basis: move.reason, now: now())
                case .review:
                    break
                }
            } catch {
                fail(move, error.localizedDescription)
            }
        }
        removeEmptiedFolders(emptied, log: log, batch: batch)
        try? log.append(batch: batch, action: .end, from: "", to: "", reason: "\(moved)", now: now())
        if maintainEntryFiles { _ = try? EntryFiles.refresh(in: root) }
        return OrganizeResult(batch: batch, moved: moved, failures: failures, plan: plan)
    }

    /// The path below the root, by text (for folders not made yet).
    func lexicalRelative(_ url: URL) -> String {
        var base = root.path(percentEncoded: false)
        if !base.hasSuffix("/") { base += "/" }
        let path = url.path(percentEncoded: false)
        return String(path.dropFirst(base.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    /// The folders that do not exist yet on the way to `folder`, outermost
    /// first (each is logged before it is made, so undo can remove it).
    func missingFolders(_ folder: URL) -> [URL] {
        let fm = FileManager.default
        var missing: [URL] = []
        var cursor = folder
        let rootPath = root.path(percentEncoded: false)
        while !fm.fileExists(atPath: cursor.path(percentEncoded: false)), cursor.path(percentEncoded: false).count > rootPath.count {
            missing.insert(cursor, at: 0)
            cursor = cursor.deletingLastPathComponent()
        }
        return missing
    }

    func uniqueURL(_ url: URL) -> URL {
        let ext = url.pathExtension, stem = url.deletingPathExtension().lastPathComponent
        var n = 2
        var candidate = url
        while FileManager.default.fileExists(atPath: candidate.path(percentEncoded: false)) {
            candidate = url.deletingLastPathComponent().appending(path: ext.isEmpty ? "\(stem)-\(n)" : "\(stem)-\(n).\(ext)")
            n += 1
        }
        return candidate
    }

    /// Inbox subfolders this round emptied (a dropped folder's), innermost
    /// first — logged, so undo makes them again. Folders the round did not
    /// touch are left alone.
    func removeEmptiedFolders(_ folders: Set<String>, log: OrganizeLog, batch: String) {
        let fm = FileManager.default
        var candidates = Set<String>()
        for f in folders {
            var cursor = f
            while Self.isUnder(cursor, layout.inbox), cursor.count > layout.inbox.count {
                candidates.insert(cursor)
                cursor = (cursor as NSString).deletingLastPathComponent
            }
        }
        for folder in candidates.sorted(by: { $0.count > $1.count }) {
            let url = root.appending(path: folder)
            guard let rest = try? fm.contentsOfDirectory(atPath: url.path(percentEncoded: false)),
                  rest.allSatisfy({ $0 == ".DS_Store" }) else { continue }
            guard (try? log.append(batch: batch, action: .rmdir, from: folder, to: "", reason: "", now: now())) != nil else { continue }
            try? fm.removeItem(at: url)
        }
    }

    // MARK: - Undo

    /// Puts every file of a round back where it was, with its original bytes.
    /// Anything changed since — a note edited after it was organized, a file
    /// moved on by hand — is left as it is and listed in `skipped`.
    @discardableResult
    public func undo(batch: String) throws -> UndoResult {
        let lock = try OrganizeLock(root: root)
        defer { lock.release() }
        let fm = FileManager.default
        let log = OrganizeLog(root: root, layout: layout)
        let entries = log.entries(batch: batch)
        guard !entries.isEmpty else { throw OrganizeError.nothingToUndo }
        guard !entries.contains(where: { $0.action == .undo }) else { throw OrganizeError.alreadyUndone }
        var restored = 0
        var skipped: [String] = []
        for entry in entries.reversed() {
            switch entry.action {
            case .meta:
                // `from` is the backup, `to` the note, `reason` the hash of
                // what was written: restored only if the note is still that.
                guard let backup = resolveInside(entry.from), let target = resolveInside(entry.to),
                      fm.fileExists(atPath: backup.path(percentEncoded: false)),
                      fm.fileExists(atPath: target.path(percentEncoded: false)) else { continue }
                guard Fingerprint.sha256(target) == entry.reason else { skipped.append("\(entry.to): edited since"); continue }
                do {
                    try Metadata.overwriteInPlace(target, with: try Data(contentsOf: backup))
                    try? fm.removeItem(at: backup)
                } catch { skipped.append(entry.to) }
            case .move:
                guard let current = resolveInside(entry.to), let original = resolveInside(entry.from) else {
                    skipped.append("\(entry.to): outside the vault"); continue
                }
                guard fm.fileExists(atPath: current.path(percentEncoded: false)) else {
                    // Never made (a failed move), or moved on since.
                    if !fm.fileExists(atPath: original.path(percentEncoded: false)) { skipped.append("\(entry.to): not there any more") }
                    continue
                }
                guard !fm.fileExists(atPath: original.path(percentEncoded: false)) else { skipped.append("\(entry.from): taken"); continue }
                do {
                    try fm.createDirectory(at: original.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try fm.moveItem(at: current, to: original)
                    restored += 1
                    Metadata.removeRows(root: root, layout: layout, path: entry.to)
                } catch { skipped.append(entry.to) }
            case .mkdir:
                guard let folder = resolveInside(entry.to) else { continue }
                if let rest = try? fm.contentsOfDirectory(atPath: folder.path(percentEncoded: false)), rest.allSatisfy({ $0 == ".DS_Store" }) {
                    try? fm.removeItem(at: folder)
                }
            case .rmdir:
                if let folder = resolveInside(entry.from) { try? fm.createDirectory(at: folder, withIntermediateDirectories: true) }
            case .begin, .end, .undo:
                break
            }
        }
        try log.append(batch: batch, action: .undo, from: "", to: "", reason: "\(restored)", now: now())
        if maintainEntryFiles { _ = try? EntryFiles.refresh(in: root) }
        return UndoResult(restored: restored, skipped: skipped)
    }
}
