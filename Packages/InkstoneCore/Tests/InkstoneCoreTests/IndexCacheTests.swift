import Testing
import Foundation
@testable import InkstoneCore

/// 0.4.0 plan B4: the parsed index is kept on disk between launches, so
/// opening a vault re-parses only the notes that changed (measured: a
/// 9,852-note vault, 2.2 s full build → 0.33 s reusing the previous parse).
@Suite("Index cache")
struct IndexCacheTests {
    func vault() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "index-cache-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appending(path: "sub"), withIntermediateDirectories: true)
        try "---\ntags: [a, b]\naliases: [Alt]\nrating: 4.5\ndone: true\nwhen: 2026-11-18\nlist: [1, two]\n---\n# One\n\nSee [[Two#Head|t]] and ![[pic.png]] #tag ^blk\n"
            .write(to: root.appending(path: "One.md"), atomically: true, encoding: .utf8)
        try "# Two\n\n## Head\n\n[x](One.md) _drafts/x.md\n".write(to: root.appending(path: "sub/Two.md"), atomically: true, encoding: .utf8)
        return root
    }

    /// Notes compared without the front matter's source range, which only
    /// means something next to the text it was cut from and is not cached.
    func comparable(_ notes: [URL: NoteMetadata]) -> [URL: String] {
        notes.mapValues { n in
            "\(n.basename)|\(n.title)|\(n.frontmatter.properties.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" })|\(n.tags)|\(n.outgoingLinks)|\(n.markdownLinkTargets)|\(n.pathTargets)|\(n.headings)|\(n.blockIdentifiers)|\(n.modified)|\(n.created)|\(n.wordCount)"
        }
    }

    @Test func roundTripsEveryField() async throws {
        let root = try vault(); defer { try? FileManager.default.removeItem(at: root) }
        let built = await IndexBuilder().build(vaultRoot: root)
        let file = root.appending(path: "cache.plist")
        try IndexCache.save(built, to: file, parserVersion: "test-1")
        let loaded = try #require(await IndexCache.load(from: file, parserVersion: "test-1"))
        #expect(comparable(loaded.notes) == comparable(built.notes))
        #expect(loaded.buildStarted == built.buildStarted)
    }

    @Test func aDifferentParserVersionIsIgnored() async throws {
        let root = try vault(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "cache.plist")
        try IndexCache.save(await IndexBuilder().build(vaultRoot: root), to: file, parserVersion: "old")
        #expect(await IndexCache.load(from: file, parserVersion: "new") == nil)
        #expect(await IndexCache.load(from: root.appending(path: "missing.plist"), parserVersion: "old") == nil)
        try Data("garbage".utf8).write(to: file)
        #expect(await IndexCache.load(from: file, parserVersion: "old") == nil)
    }

    @Test func buildingFromTheCacheMatchesAFullBuild() async throws {
        let root = try vault(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "cache.plist")
        try IndexCache.save(await IndexBuilder().build(vaultRoot: root), to: file, parserVersion: "v")
        let cached = try #require(await IndexCache.load(from: file, parserVersion: "v"))
        let reused = await IndexBuilder().build(vaultRoot: root, reusing: cached)
        let full = await IndexBuilder().build(vaultRoot: root)
        #expect(comparable(reused.notes) == comparable(full.notes))
        #expect(reused.backlinks.mapValues(\.count) == full.backlinks.mapValues(\.count))
        #expect(reused.tagCounts == full.tagCounts)
    }
}
