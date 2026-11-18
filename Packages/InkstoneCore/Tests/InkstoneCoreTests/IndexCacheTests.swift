import Testing
import Foundation
@testable import InkstoneCore

/// The on-disk index cache must never make the index differ from a full
/// rebuild: a stale cached note would show as wrong backlinks or search hits.
@Suite("Index cache")
struct IndexCacheTests {
    typealias Fingerprint = IncrementalIndexTests.Fingerprint

    func dir() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "inkstone-cache-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    @Test func aRoundTripReproducesTheSnapshot() async throws {
        let root = try IncrementalIndexTests.vault(); let cache = dir()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: cache) }
        let built = await IndexBuilder().build(vaultRoot: root)
        IndexCache.save(built, vaultRoot: root, appVersion: "1", in: cache)
        let loaded = try #require(IndexCache.load(vaultRoot: root, appVersion: "1", in: cache))
        #expect(Fingerprint(loaded) == Fingerprint(built))
    }

    @Test func notesChangedSinceTheCacheAreReparsed() async throws {
        let root = try IncrementalIndexTests.vault(); let cache = dir()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: cache) }
        try IncrementalIndexTests.ageAll(root)
        IndexCache.save(await IndexBuilder().build(vaultRoot: root), vaultRoot: root, appVersion: "1", in: cache)
        // Edited, added and deleted after the cache was written (next launch).
        try "# Edited after\n[[Note 9]]\n".write(to: root.appending(path: "A/Note 2.md"), atomically: true, encoding: .utf8)
        try "# New\n".write(to: root.appending(path: "B/New.md"), atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: root.appending(path: "A/Note 4.md"))
        let cached = try #require(IndexCache.load(vaultRoot: root, appVersion: "1", in: cache))
        let incremental = await IndexBuilder().build(vaultRoot: root, reusing: cached)
        let full = await IndexBuilder().build(vaultRoot: root)
        #expect(Fingerprint(incremental) == Fingerprint(full))
    }

    @Test func anotherAppVersionsCacheIsIgnored() async throws {
        let root = try IncrementalIndexTests.vault(); let cache = dir()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: cache) }
        IndexCache.save(await IndexBuilder().build(vaultRoot: root), vaultRoot: root, appVersion: "1", in: cache)
        #expect(IndexCache.load(vaultRoot: root, appVersion: "2", in: cache) == nil)
        #expect(IndexCache.load(vaultRoot: root.appending(path: "A"), appVersion: "1", in: cache) == nil)
    }
}
