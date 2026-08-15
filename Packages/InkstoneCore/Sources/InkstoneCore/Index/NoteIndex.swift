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
    public var backlinks: [URL: [LinkEdge]] = [:]
    public var tagCounts: [String: Int] = [:]
    /// Link targets that don't resolve to a file, with how many times they appear.
    public var unresolved: [String: Int] = [:]

    public init() {}

    public var noteCount: Int { notes.count }

    public func metadata(for url: URL) -> NoteMetadata? { notes[url] }

    public func outgoing(from url: URL) -> [LinkEdge] {
        edges.filter { $0.source == url }
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

        // 1. Treat the target as a path if it contains a separator or extension.
        let withExtension = target.hasSuffix(".md") ? target : target + ".md"
        let asPath = vaultRoot.appending(path: withExtension)
        if notes[asPath] != nil { return asPath }
        let relative = source.deletingLastPathComponent().appending(path: withExtension)
        if notes[relative] != nil { return relative }

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

    public func build(vaultRoot: URL) async -> IndexSnapshot {
        let scanner = VaultScanner()
        let store = NoteStore(root: vaultRoot)
        let files = scanner.markdownFiles(in: vaultRoot)

        // Parse files concurrently; parsing is CPU-bound and embarrassingly parallel.
        var parsed: [NoteMetadata] = []
        parsed.reserveCapacity(files.count)

        await withTaskGroup(of: NoteMetadata?.self) { group in
            for url in files {
                group.addTask {
                    guard let text = try? store.read(url) else { return nil }
                    let dates = store.modificationDates(of: url)
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
                if let destination {
                    snapshot.backlinks[destination, default: []].append(edge)
                } else if !link.target.isEmpty {
                    snapshot.unresolved[link.target, default: 0] += 1
                }
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
                if let destination { snapshot.backlinks[destination, default: []].append(edge) }
            }
        }

        return snapshot
    }
}
