import Testing
import Foundation
@testable import InkstoneCore

/// The sync scan reuses a file's SHA when its size, mtime and ctime are
/// unchanged. Reusing a stale SHA would make a real edit invisible to sync
/// (it would never upload), so every way a file can change is checked to miss.
@Suite("Sync hash cache")
struct SyncHashCacheTests {

    static func engine(_ root: URL) -> SyncEngine {
        SyncEngine(
            client: GitHubClient(configuration: .init(repository: "a/b", branch: "main"), token: "t"),
            vaultRoot: root,
            policy: SyncFilePolicy()
        )
    }

    static func vault() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "inkstone-hash-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root.appending(path: "A"), withIntermediateDirectories: true)
        for i in 0..<5 { try "note \(i)\n".write(to: root.appending(path: "A/n\(i).md"), atomically: true, encoding: .utf8) }
        return root
    }

    @Test func unchangedFilesReuseTheirStampAndMatchAFreshHash() throws {
        let root = try Self.vault()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = Self.engine(root)
        let first = engine.localFiles(cache: [:], trustBefore: .distantPast)
        // Pretend the scan happened long after the files were written.
        let second = engine.localFiles(cache: first.stamps, trustBefore: .distantFuture)
        #expect(second.files == first.files)
        #expect(second.files == engine.localFiles().files)
        #expect(second.stamps.count == 5)
    }

    @Test func anEditWithTheSameSizeAndRestoredMtimeIsStillSeen() throws {
        let root = try Self.vault()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = Self.engine(root)
        let file = root.appending(path: "A/n2.md")
        let first = engine.localFiles(cache: [:], trustBefore: .distantPast)
        let mtime = try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as! Date

        // Same byte count, and the modification date put back as it was —
        // what a copy tool preserving dates would leave. Only ctime differs.
        try "NOTE 2\n".write(to: file, atomically: false, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: file.path)

        let second = engine.localFiles(cache: first.stamps, trustBefore: .distantFuture)
        #expect(second.files["A/n2.md"] == gitBlobSHA(Data("NOTE 2\n".utf8)))
    }

    @Test func aFileTouchedAfterTheTrustLimitIsRehashed() throws {
        let root = try Self.vault()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = Self.engine(root)
        let first = engine.localFiles(cache: [:], trustBefore: .distantPast)
        // A forged stamp that matches the file's current dates but carries a
        // wrong SHA: trusted only if the dates are older than the limit.
        var forged = first.stamps
        forged["A/n1.md"]?.sha = "stale"
        let recent = engine.localFiles(cache: forged, trustBefore: .now.addingTimeInterval(-3600))
        #expect(recent.files["A/n1.md"] == gitBlobSHA(Data("note 1\n".utf8)))
        let trusted = engine.localFiles(cache: forged, trustBefore: .distantFuture)
        #expect(trusted.files["A/n1.md"] == "stale")   // proves the cache path is taken
    }

    @Test func oldSyncFilesWithoutStampsStillDecode() throws {
        let json = #"{"blobs":{"a.md":"abc"},"branch":"main"}"#
        let state = try JSONDecoder().decode(SyncState.self, from: Data(json.utf8))
        #expect(state.blobs == ["a.md": "abc"])
        #expect(state.hashes == nil)
    }
}
