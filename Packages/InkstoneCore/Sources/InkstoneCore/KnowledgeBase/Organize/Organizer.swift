import Foundation

/// One planned move. `from`/`to` are vault-relative.
public struct OrganizeMove: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable, Codable {
        case file           // filed into its place
        case review         // unsure: into the review folder
        case privateFile    // into the private folder
        case duplicate      // exact or near copy: into to-delete
        case oldVersion     // an older version of a note: into old versions
    }
    public var id: String { from }
    public var from: String
    public var to: String
    public var kind: Kind
    public var reason: String
    /// For duplicates and old versions: the copy that stays.
    public var kept: String?
    public var tags: [String] = []
    public var summary: String?
}

/// Topics that overlap but are not the same document (similarity 0.6–0.9):
/// reported for the person to decide, never acted on (policy §4).
public struct MergeSuggestion: Sendable, Equatable {
    public var a: String
    public var b: String
}

/// The change plan of one round (policy rule 3).
public struct ChangePlan: Sendable {
    public var moves: [OrganizeMove]
    public var suggestions: [MergeSuggestion]
    /// More than 20 files, or anything that deduplicates or moves files
    /// already in place: the person confirms first.
    public var needsConfirmation: Bool {
        moves.count > 20 || moves.contains { $0.kind == .duplicate || $0.kind == .oldVersion }
            || moves.contains { !$0.from.hasPrefix(inbox + "/") }
    }
    let inbox: String

    public var isEmpty: Bool { moves.isEmpty }
    public func count(_ kind: OrganizeMove.Kind) -> Int { moves.filter { $0.kind == kind }.count }
}

public struct OrganizeResult: Sendable {
    public var batch: String
    public var moved: Int
    public var plan: ChangePlan
}

/// Files what lands in the inbox, by the knowledge base's rules.
///
/// Never deletes and never rewrites a file's text: it moves, renames, and adds
/// front matter keys that are missing (the original bytes are kept for undo).
/// Every step is written to the log, and `undo(batch:)` replays a round
/// backwards.
public struct Organizer: Sendable {
    public let root: URL
    public let layout: KnowledgeBaseLayout
    public let advisor: PlacementAdvisor?
    public let now: @Sendable () -> Date
    public let ocr: Bool

    public init(root: URL, layout: KnowledgeBaseLayout, advisor: PlacementAdvisor?, ocr: Bool = false,
                now: @escaping @Sendable () -> Date = { .now }) {
        self.root = root; self.layout = layout; self.advisor = advisor; self.ocr = ocr; self.now = now
    }

    // MARK: - Inbox

    /// The files waiting in the inbox, at any depth (a dropped folder's files
    /// too), hidden files excluded, in a stable order.
    public static func inboxFiles(root: URL, layout: KnowledgeBaseLayout) throws -> [URL] {
        let inbox = root.appending(path: layout.inbox, directoryHint: .isDirectory)
        guard let e = FileManager.default.enumerator(at: inbox, includingPropertiesForKeys: [.isRegularFileKey],
                                                     options: [.skipsHiddenFiles]) else { return [] }
        var out: [URL] = []
        for case let url as URL in e where (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
            out.append(url)
        }
        return out.sorted { $0.path(percentEncoded: false) < $1.path(percentEncoded: false) }
    }

    func relative(_ url: URL) -> String {
        let base = CanonicalPath.of(root)
        let path = CanonicalPath.of(url)
        let prefix = base.hasSuffix("/") ? base : base + "/"
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
    }

    // MARK: - Plan

    public func plan() async throws -> ChangePlan {
        let inbox = try Self.inboxFiles(root: root, layout: layout)
        guard !inbox.isEmpty else { return ChangePlan(moves: [], suggestions: [], inbox: layout.inbox) }
        var facts: [FileFacts] = []
        for url in inbox { facts.append(await FactsExtractor.facts(for: url, ocr: ocr)) }

        let index = VaultIndex(root: root, layout: layout)
        index.refresh(sizesToHash: Set(facts.map(\.size)))
        let rules = OrganizingRules(rulesFileText: (try? String(contentsOf: root.appending(path: layout.rulesFile), encoding: .utf8)) ?? "")
        let context = AdvisorContext(layout: layout, folders: index.folders, rules:
            (try? String(contentsOf: root.appending(path: layout.rulesFile), encoding: .utf8)) ?? "")

        var moves: [OrganizeMove] = []
        var suggestions: [MergeSuggestion] = []
        var taken = Set<String>()                       // destinations already planned
        var plannedBySHA: [String: String] = [:]        // inbox duplicates: sha → where the first copy goes

        func reserve(_ folder: String, _ name: String) -> String {
            let ext = (name as NSString).pathExtension
            let stem = (name as NSString).deletingPathExtension
            var candidate = folder.isEmpty ? name : "\(folder)/\(name)"
            var n = 2
            while taken.contains(candidate.lowercased())
                    || FileManager.default.fileExists(atPath: root.appending(path: candidate).path(percentEncoded: false)) {
                let next = ext.isEmpty ? "\(stem)-\(n)" : "\(stem)-\(n).\(ext)"
                candidate = folder.isEmpty ? next : "\(folder)/\(next)"
                n += 1
            }
            taken.insert(candidate.lowercased())
            return candidate
        }

        for f in facts {
            let from = relative(f.url)
            let original = f.url.lastPathComponent

            // 1. Exact duplicates — of something already filed, or of an
            //    earlier file in this same inbox.
            if let sha = f.sha256 {
                if let existing = index.path(forSHA: sha) {
                    moves.append(OrganizeMove(from: from, to: reserve(layout.trash, original), kind: .duplicate,
                                              reason: "SHA-256", kept: existing))
                    continue
                }
                if let first = plannedBySHA[sha] {
                    moves.append(OrganizeMove(from: from, to: reserve(layout.trash, original), kind: .duplicate,
                                              reason: "SHA-256", kept: first))
                    continue
                }
            }

            // 2. The same picture saved differently: keep the larger.
            if let ph = f.perceptualHash, let near = index.nearImage(ph, within: 5) {
                let mine = (f.pixelSize?.width ?? 0) * (f.pixelSize?.height ?? 0)
                if mine <= near.pixels {
                    moves.append(OrganizeMove(from: from, to: reserve(layout.trash, original), kind: .duplicate,
                                              reason: "pHash", kept: near.path))
                    continue
                }
            }

            // 3. Placement.
            var placed = place(f, rules: rules, index: index)
            if placed.kind == .review, let advisor, let advice = try? await advisor.advise(f, context: context) {
                if let checked = accept(advice) { placed = checked }
            }

            // 4. A newer or older version of an existing note.
            if let sh = f.simHash, let near = index.nearText(sh) {
                if near.distance <= 3 {
                    if f.contentDate >= near.date && f.text.count >= near.length {
                        // This one is the main version now: it goes where the
                        // old one was; the old one to old versions.
                        let folder = (near.path as NSString).deletingLastPathComponent
                        placed = Placed(folder: folder, kind: .file, reason: "newer version of \(near.path)",
                                        keywords: placed.keywords, tags: placed.tags, summary: placed.summary)
                        moves.append(OrganizeMove(from: near.path, to: reserve(layout.oldVersions, (near.path as NSString).lastPathComponent),
                                                  kind: .oldVersion, reason: "SimHash", kept: nil))
                    } else {
                        moves.append(OrganizeMove(from: from, to: reserve(layout.oldVersions, original), kind: .oldVersion,
                                                  reason: "SimHash", kept: near.path))
                        continue
                    }
                } else if near.distance <= 12 {
                    suggestions.append(MergeSuggestion(a: from, b: near.path))
                }
            }

            let name = placed.kind == .review
                ? original
                : FileNaming.name(keywords: placed.keywords ?? cleanKeywords(f), ext: f.ext, date: f.contentDate)
            let to = reserve(placed.folder, name)
            moves.append(OrganizeMove(from: from, to: to, kind: placed.kind, reason: placed.reason,
                                      kept: nil, tags: placed.tags, summary: placed.summary))
            if let sha = f.sha256 { plannedBySHA[sha] = to }
        }
        // Moves of files already in place (old versions) go first, so the
        // new main version can take a free name.
        moves.sort { ($0.kind == .oldVersion && !$0.from.hasPrefix(layout.inbox)) && !($1.kind == .oldVersion && !$1.from.hasPrefix(layout.inbox)) }
        return ChangePlan(moves: moves, suggestions: suggestions, inbox: layout.inbox)
    }

    struct Placed {
        var folder: String
        var kind: OrganizeMove.Kind
        var reason: String
        var keywords: String?
        var tags: [String] = []
        var summary: String?
    }

    /// Without an advisor: the person's rules, privacy, a project or area
    /// named in the file, media by type and month — else review.
    func place(_ f: FileFacts, rules: OrganizingRules, index: VaultIndex) -> Placed {
        if let rule = rules.match(f), let folder = sanitize(rule.folder) {
            return Placed(folder: folder, kind: .file, reason: "rule: \(rule.keyword)")
        }
        if let word = PrivacyCheck.looksPrivate(f) {
            return Placed(folder: layout.privateFolder, kind: .privateFile, reason: "private: \(word)")
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
                          keywords: advice.title, tags: advice.tags, summary: advice.summary)
        }
        guard advice.confidence >= 0.7, let folder = sanitize(advice.folder) else { return nil }
        return Placed(folder: folder, kind: .file, reason: advice.reason, keywords: advice.title,
                      tags: advice.tags, summary: advice.summary)
    }

    /// A folder a file may be filed into: relative, inside the vault, at
    /// most three levels, not in the machinery (system, archive, review) or
    /// the inbox. Nil otherwise.
    func sanitize(_ folder: String) -> String? {
        let parts = folder.split(separator: "/").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !folder.hasPrefix("/"), !folder.hasPrefix("~"), !parts.isEmpty, parts.count <= 3,
              !parts.contains(where: { $0 == ".." || $0 == "." || $0.hasPrefix(".") }) else { return nil }
        let joined = parts.joined(separator: "/")
        for forbidden in layout.systemFolders + [layout.inbox] where joined == forbidden || joined.hasPrefix(forbidden + "/") {
            return nil
        }
        return joined
    }

    func cleanKeywords(_ f: FileFacts) -> String {
        if let title = f.title, !title.isEmpty, [.markdown, .pdf, .html].contains(f.kind) { return title }
        return f.name
    }

    // MARK: - Execute

    @discardableResult
    public func execute(_ plan: ChangePlan) throws -> OrganizeResult {
        let fm = FileManager.default
        let batch = OrganizeLog.newBatch(now())
        let log = OrganizeLog(root: root, layout: layout)
        var moved = 0
        for move in plan.moves {
            let from = root.appending(path: move.from)
            guard fm.fileExists(atPath: from.path(percentEncoded: false)) else { continue }
            var to = root.appending(path: move.to)
            // Never overwrite: something may have appeared since the plan.
            if fm.fileExists(atPath: to.path(percentEncoded: false)) {
                to = uniqueURL(to)
            }
            let folder = to.deletingLastPathComponent()
            for created in try makeFolders(folder) { log.append(batch: batch, action: .mkdir, from: "", to: relative(created), reason: "", now: now()) }
            try fm.moveItem(at: from, to: to)
            let toRelative = relative(to)
            log.append(batch: batch, action: .move, from: move.from, to: toRelative, reason: "\(move.kind.rawValue): \(move.reason)", now: now())
            moved += 1

            switch move.kind {
            case .file, .privateFile:
                if FileKind.detect(to) == .markdown {
                    if let backup = try Metadata.addFrontmatter(to, origin: move.from, date: now(), tags: move.tags,
                                                                summary: move.summary, layout: layout, batch: batch, root: root) {
                        log.append(batch: batch, action: .meta, from: backup, to: toRelative, reason: "frontmatter", now: now())
                    }
                } else {
                    Metadata.indexRow(root: root, layout: layout, path: toRelative, url: to, tags: move.tags, summary: move.summary, now: now())
                }
            case .duplicate, .oldVersion:
                Metadata.duplicateRow(root: root, layout: layout, kept: move.kept ?? "", moved: toRelative, basis: move.reason, now: now())
            case .review:
                break
            }
        }
        removeEmptyFolders(under: root.appending(path: layout.inbox, directoryHint: .isDirectory))
        _ = try? EntryFiles.refresh(in: root)
        return OrganizeResult(batch: batch, moved: moved, plan: plan)
    }

    /// Creates the folder and any missing parents; returns those created,
    /// outermost first, so undo can remove them again.
    func makeFolders(_ folder: URL) throws -> [URL] {
        let fm = FileManager.default
        var missing: [URL] = []
        var cursor = folder
        while !fm.fileExists(atPath: cursor.path(percentEncoded: false)), cursor.path(percentEncoded: false).count > root.path(percentEncoded: false).count {
            missing.insert(cursor, at: 0)
            cursor = cursor.deletingLastPathComponent()
        }
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
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

    func removeEmptyFolders(under folder: URL) {
        let fm = FileManager.default
        guard let kids = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey]) else { return }
        for kid in kids where (try? kid.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
            removeEmptyFolders(under: kid)
            let rest = (try? fm.contentsOfDirectory(atPath: kid.path(percentEncoded: false))) ?? ["x"]
            if rest.allSatisfy({ $0 == ".DS_Store" }) { try? fm.removeItem(at: kid) }
        }
    }

    // MARK: - Undo

    /// Puts every file of a round back where it was, with its original bytes,
    /// and removes the folders the round created (if empty).
    public func undo(batch: String) throws {
        let fm = FileManager.default
        let log = OrganizeLog(root: root, layout: layout)
        let entries = log.entries(batch: batch)
        for entry in entries.reversed() {
            switch entry.action {
            case .meta:
                let backup = root.appending(path: entry.from)
                let target = root.appending(path: entry.to)
                if fm.fileExists(atPath: backup.path(percentEncoded: false)), fm.fileExists(atPath: target.path(percentEncoded: false)) {
                    let data = try Data(contentsOf: backup)
                    try data.write(to: target, options: .atomic)
                    try? fm.removeItem(at: backup)
                }
            case .move:
                let current = root.appending(path: entry.to)
                let original = root.appending(path: entry.from)
                guard fm.fileExists(atPath: current.path(percentEncoded: false)),
                      !fm.fileExists(atPath: original.path(percentEncoded: false)) else { continue }
                try fm.createDirectory(at: original.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.moveItem(at: current, to: original)
                Metadata.removeIndexRow(root: root, layout: layout, path: entry.to)
            case .mkdir:
                let folder = root.appending(path: entry.to)
                if let rest = try? fm.contentsOfDirectory(atPath: folder.path(percentEncoded: false)), rest.allSatisfy({ $0 == ".DS_Store" }) {
                    try? fm.removeItem(at: folder)
                }
            case .undo:
                break
            }
        }
        log.append(batch: batch, action: .undo, from: "", to: "", reason: "\(entries.filter { $0.action == .move }.count)", now: now())
        _ = try? EntryFiles.refresh(in: root)
    }
}
