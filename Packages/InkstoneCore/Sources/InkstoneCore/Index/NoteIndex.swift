import Foundation
import os

/// A resolved connection between two notes.
public struct LinkEdge: Hashable, Sendable {
    public let source: URL
    /// Nil when the link points at a note that doesn't exist yet — Obsidian's
    /// "unresolved link", which the graph still draws as a ghost node.
    public let destination: URL?
    public let unresolvedTarget: String
    public let isEmbed: Bool
    public let fragment: String?

    public init(source: URL, destination: URL?, unresolvedTarget: String, isEmbed: Bool, fragment: String?) {
        self.source = source
        self.destination = destination
        self.unresolvedTarget = unresolvedTarget
        self.isEmbed = isEmbed
        self.fragment = fragment
    }
}

/// In-memory index of every note in a vault: metadata, link graph, and tags.
///
/// Rebuilt off the main actor and then handed over wholesale, which keeps the UI
/// responsive on large vaults while avoiding fine-grained locking.
public struct IndexSnapshot: Sendable {
    public var notes: [URL: NoteMetadata] = [:]
    /// Lowercased link name (basename or alias) → notes answering to it.
    public var namesToNotes: [String: [URL]] = [:]
    public var edges: [LinkEdge] = []
    /// Outgoing links keyed by the note they leave, in document order.
    ///
    /// `backlinks` has always been a dictionary; `outgoing` used to filter the
    /// whole `edges` array on every call, which is O(E) — and the inspector calls
    /// it once for every note opened. Built once in `assemble` instead.
    public var outgoingLinks: [URL: [LinkEdge]] = [:]
    public var backlinks: [URL: [LinkEdge]] = [:]
    public var tagCounts: [String: Int] = [:]
    /// Link targets that don't resolve to a file, with how many times they appear.
    public var unresolved: [String: Int] = [:]
    /// Every note, in a stable order, sorted once when the snapshot is built.
    ///
    /// `notes` is a dictionary and Swift seeds its iteration order per process,
    /// so anything that walks the vault and wants reproducible output has to
    /// sort — and sorting by `url.path` builds a String per comparison. Doing
    /// that inside search cost more than the search did: it is most of why a
    /// batched parallel read first came out *slower* than reading one file at a
    /// time.
    public var orderedNotes: [URL] = []
    /// Every note keyed by its decoded path string, built once in `assemble`.
    ///
    /// `resolve` used to build two `URL`s per link and look each up in `notes`,
    /// which hashes the URL's whole string every time; on a 10,000-note vault
    /// that was ~180 ms of a ~290 ms assembly. Joining path strings and looking
    /// them up here gives the same answers (`ResolveEquivalenceTests`) for a
    /// fraction of the cost. Empty or out of step with `notes` (a snapshot
    /// built by hand, or edited after assembly) → `resolve` falls back to the
    /// URL-based lookup.
    var pathIndex: [String: URL] = [:]

    public init() {}

    public var noteCount: Int { notes.count }

    public func metadata(for url: URL) -> NoteMetadata? { notes[url] }

    public func outgoing(from url: URL) -> [LinkEdge] {
        outgoingLinks[url] ?? []
    }

    public func incoming(to url: URL) -> [LinkEdge] {
        backlinks[url] ?? []
    }

    public func notes(taggedWith tag: String) -> [NoteMetadata] {
        notes.values.filter { $0.tags.contains(tag) }.sorted { $0.title < $1.title }
    }

    /// Resolves a wikilink target the way Obsidian does:
    /// 1. exact path match relative to the vault root,
    /// 2. unique basename or alias match anywhere,
    /// 3. among several candidates, the one nearest the linking note.
    public func resolve(_ target: String, from source: URL, vaultRoot: URL) -> URL? {
        guard !target.isEmpty else { return source }
        let withExtension = target.hasSuffix(".md") ? target : target + ".md"

        // 1. Treat the target as a path if it contains a separator or extension.
        if !pathIndex.isEmpty, pathIndex.count == notes.count {
            if let hit = pathIndex[Self.join(vaultRoot.path(percentEncoded: false), withExtension)] { return hit }
            // A leading slash means "from the vault root" (step above). The URL
            // version never matched such a target against the note's folder —
            // `appending(path:)` on a folder URL keeps the `//` — so neither do we.
            if !withExtension.hasPrefix("/") {
                let sourcePath = source.path(percentEncoded: false)
                let folder = sourcePath.lastIndex(of: "/").map { String(sourcePath[...$0]) } ?? sourcePath
                if let hit = pathIndex[Self.join(folder, withExtension)] { return hit }
            }
        } else {
            let asPath = vaultRoot.appending(path: withExtension)
            if notes[asPath] != nil { return asPath }
            let relative = source.deletingLastPathComponent().appending(path: withExtension)
            if notes[relative] != nil { return relative }
        }
        return resolveByName(target, from: source)
    }

    /// The path `URL.appending(path:)` would produce, as a string: `base`, one
    /// separator, then `relative` with exactly one leading slash removed —
    /// checked against Foundation for spaces, `%`, `..`, `./`, `//`, CJK.
    static func join(_ base: String, _ relative: String) -> String {
        let head = base.hasSuffix("/") ? base : base + "/"
        return head + (relative.hasPrefix("/") ? String(relative.dropFirst()) : relative)
    }

    /// The reference for `ResolveEquivalenceTests`: the original algorithm,
    /// building `URL`s with Foundation, but matching a candidate to a note by
    /// its decoded path rather than by `URL ==`. (`URL ==` compares spellings,
    /// so the same file built two ways — a space percent-encoded or not — could
    /// fail to match and fall through to name matching: on a vault path with a
    /// space, `/Folder/dup` resolved to a *different* `dup.md`. Matching by path
    /// is what the rule "exact path relative to the vault root" means.)
    func resolveReference(_ target: String, from source: URL, vaultRoot: URL) -> URL? {
        guard !target.isEmpty else { return source }
        let withExtension = target.hasSuffix(".md") ? target : target + ".md"
        let byPath = Dictionary(notes.keys.map { ($0.path(percentEncoded: false), $0) }, uniquingKeysWith: { a, _ in a })
        if let hit = byPath[vaultRoot.appending(path: withExtension).path(percentEncoded: false)] { return hit }
        if let hit = byPath[source.deletingLastPathComponent().appending(path: withExtension).path(percentEncoded: false)] { return hit }
        return resolveByName(target, from: source)
    }

    private func resolveByName(_ target: String, from source: URL) -> URL? {

        // 2/3. Fall back to name matching.
        let key = (target as NSString).lastPathComponent.lowercased()
        guard let candidates = namesToNotes[key], !candidates.isEmpty else { return nil }
        if candidates.count == 1 { return candidates[0] }

        let sourceFolder = source.deletingLastPathComponent()
        return candidates.min { lhs, rhs in
            distance(from: sourceFolder, to: lhs) < distance(from: sourceFolder, to: rhs)
        }
    }

    /// Number of path components separating a folder from a file — a cheap
    /// proximity heuristic for disambiguating same-named notes.
    private func distance(from folder: URL, to file: URL) -> Int {
        let a = folder.pathComponents
        let b = file.deletingLastPathComponent().pathComponents
        var shared = 0
        while shared < min(a.count, b.count), a[shared] == b[shared] { shared += 1 }
        return (a.count - shared) + (b.count - shared)
    }
}

/// Builds `IndexSnapshot`s. Runs off the main actor.
public actor IndexBuilder {
    private let logger = Logger(subsystem: "com.orris.inkstone", category: "IndexBuilder")

    public init() {}

    /// Builds a snapshot of the whole vault.
    ///
    /// With `previous`, the build is incremental: a note whose modification date
    /// still matches the one recorded in `previous` is reused as-is instead of
    /// being read and parsed again, so a save re-parses one file rather than all
    /// of them (on a 10,000-note vault that is the difference between ~420 ms and
    /// a few tens of ms). Link resolution and every derived table are still
    /// rebuilt from the complete set in `assemble`, so an incremental snapshot is
    /// identical to a full one — `IncrementalIndexTests` checks exactly that.
    public func build(vaultRoot: URL, reusing previous: IndexSnapshot? = nil) async -> IndexSnapshot {
        let scanner = VaultScanner()
        let store = NoteStore(root: vaultRoot)
        let files = scanner.markdownFiles(in: vaultRoot)
        let reusable = previous?.notes ?? [:]
        // Timestamps on HFS+ (1 s) and exFAT (2 s) are coarse: two writes in the
        // same second can leave the same modification date. Anything touched in
        // the last few seconds is therefore always re-parsed, whatever its date.
        let settledBefore = Date.now.addingTimeInterval(-3)

        // Parse files concurrently; parsing is CPU-bound and embarrassingly parallel.
        var parsed: [NoteMetadata] = []
        parsed.reserveCapacity(files.count)

        await withTaskGroup(of: NoteMetadata?.self) { group in
            for url in files {
                let old = reusable[url]
                group.addTask {
                    let dates = store.modificationDates(of: url)
                    // Unchanged on disk since the previous snapshot: keep it.
                    if let old, old.modified == dates.modified, dates.modified < settledBefore { return old }
                    guard let text = try? store.read(url) else { return nil }
                    return NoteParser.parse(
                        text: text,
                        url: url,
                        modified: dates.modified,
                        created: dates.created
                    )
                }
            }
            for await metadata in group {
                if let metadata { parsed.append(metadata) }
            }
        }

        return Self.assemble(parsed, vaultRoot: vaultRoot)
    }

    /// Pure assembly step, separated so it can be unit-tested without touching disk.
    public static func assemble(_ notes: [NoteMetadata], vaultRoot: URL) -> IndexSnapshot {
        var snapshot = IndexSnapshot()

        for note in notes {
            snapshot.notes[note.url] = note
            for name in note.linkNames {
                snapshot.namesToNotes[name.lowercased(), default: []].append(note.url)
            }
            for tag in note.tags {
                snapshot.tagCounts[tag, default: 0] += 1
            }
        }

        snapshot.pathIndex = Dictionary(
            snapshot.notes.keys.map { ($0.path(percentEncoded: false), $0) },
            uniquingKeysWith: { first, _ in first })

        // Second pass: resolution needs the complete name table from pass one.
        for note in notes {
            for link in note.outgoingLinks {
                let destination = link.target.isEmpty
                    ? note.url
                    : snapshot.resolve(link.target, from: note.url, vaultRoot: vaultRoot)
                let edge = LinkEdge(
                    source: note.url,
                    destination: destination,
                    unresolvedTarget: link.target,
                    isEmbed: false,
                    fragment: link.fragment
                )
                snapshot.edges.append(edge)
                snapshot.outgoingLinks[note.url, default: []].append(edge)
                if let destination {
                    snapshot.backlinks[destination, default: []].append(edge)
                } else if !link.target.isEmpty {
                    snapshot.unresolved[link.target, default: 0] += 1
                }
            }

            // Paths written as prose. Same edge as any other link, so the
            // graph, the backlinks pane and the inspector all see them without
            // knowing where they came from.
            // De-duplicated by destination. The same file is routinely written
            // both ways in one note — once as `/Users/…/vault/a/b.md` and once
            // as `a/b.md` — and each spelling would otherwise be its own edge,
            // drawing two lines on top of each other in the graph and counting
            // twice in the backlinks.
            var linkedByPath: Set<URL> = []
            for written in note.pathTargets {
                guard let target = VaultPathDetector.vaultRelative(written, vaultRoot: vaultRoot),
                      let destination = snapshot.resolve(target, from: note.url,
                                                         vaultRoot: vaultRoot)
                else { continue }
                guard linkedByPath.insert(destination).inserted else { continue }
                // Unresolved paths are dropped rather than recorded. A wikilink
                // that resolves to nothing is a note waiting to be written; a
                // path that resolves to nothing is usually just prose that
                // happened to look like a path, and counting it would fill the
                // unresolved list with noise.
                guard destination != note.url else { continue }
                let edge = LinkEdge(
                    source: note.url,
                    destination: destination,
                    unresolvedTarget: target,
                    isEmbed: false,
                    fragment: nil
                )
                snapshot.edges.append(edge)
                snapshot.outgoingLinks[note.url, default: []].append(edge)
                snapshot.backlinks[destination, default: []].append(edge)
            }

            for target in note.markdownLinkTargets {
                guard target.hasSuffix(".md") else { continue }
                let destination = snapshot.resolve(target, from: note.url, vaultRoot: vaultRoot)
                let edge = LinkEdge(
                    source: note.url,
                    destination: destination,
                    unresolvedTarget: target,
                    isEmbed: false,
                    fragment: nil
                )
                snapshot.edges.append(edge)
                snapshot.outgoingLinks[note.url, default: []].append(edge)
                if let destination { snapshot.backlinks[destination, default: []].append(edge) }
            }
        }

        // Once, here, rather than at every call site that wants a stable order.
        snapshot.orderedNotes = snapshot.notes.keys
            .map { (path: $0.path(percentEncoded: false), url: $0) }
            .sorted { $0.path < $1.path }
            .map(\.url)

        return snapshot
    }
}
