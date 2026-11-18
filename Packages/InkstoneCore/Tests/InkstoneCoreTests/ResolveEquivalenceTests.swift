import Testing
import Foundation
@testable import InkstoneCore

/// `resolve` looks paths up by string (fast) instead of building `URL`s (slow).
/// The two must never disagree: a link resolving differently would silently
/// change backlinks and the graph. Every awkward spelling a vault can contain is
/// tried from every folder and compared with the original algorithm (Foundation URLs,
/// matched by decoded path — see `resolveReference` for why not `URL ==`).
@Suite("Resolve equivalence")
struct ResolveEquivalenceTests {

    @Test func stringLookupMatchesURLLookupForAwkwardTargets() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "inkstone-resolve \(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let files = [
            "Plain.md", "With space.md", "a%20b.md", "中文 笔记.md", "dup.md",
            "Folder/dup.md", "Folder/Inner/deep.md", "Folder/Inner/With space.md",
            "Other/中文 笔记.md", "Other/#hash.md", "Other/q?mark.md",
        ]
        for f in files {
            let url = root.appending(path: f)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "# \(f)\n---\n".write(to: url, atomically: true, encoding: .utf8)
        }
        // The scanner reports the temporary directory through its /private
        // symlink; the app's vault root and its note URLs always share one
        // spelling, so the test resolves the root the same way.
        let vault = URL(filePath: root.resolvingSymlinksInPath().path(percentEncoded: false), directoryHint: .isDirectory)
        let snapshot = await IndexBuilder().build(vaultRoot: vault)
        #expect(!snapshot.pathIndex.isEmpty)

        let targets = [
            "Plain", "plain", "With space", "With space.md", "a%20b", "a b", "中文 笔记", "dup", "Dup",
            "Folder/dup", "Folder/Inner/deep", "Inner/deep", "deep", "./Plain", "../Plain", "../dup",
            "/Plain", "//Plain", "/Folder/dup", "Folder//dup", "Folder/./dup", "Other/#hash", "#hash",
            "q?mark", "Other/q?mark", "missing", "Folder/missing", "With space.md.md", "Folder/Inner/With space",
        ]
        var checked = 0
        for source in snapshot.notes.keys {
            for target in targets {
                let fast = snapshot.resolve(target, from: source, vaultRoot: vault)
                let slow = snapshot.resolveReference(target, from: source, vaultRoot: vault)
                #expect(fast == slow, "\(target) from \(source.lastPathComponent): \(String(describing: fast)) vs \(String(describing: slow))")
                checked += 1
            }
        }
        #expect(checked == files.count * targets.count)
    }

    @Test func joinMatchesFoundation() {
        let bases = ["/tmp/v", "/tmp/v/", "/tmp/my vault/"]
        let rels = ["a.md", "/a.md", "//a.md", "a/b.md", "./a.md", "../a.md", "a b.md", "a%20b.md", "中文.md", "a/./b.md"]
        for base in bases {
            for rel in rels {
                let expected = URL(filePath: base, directoryHint: .isDirectory).appending(path: rel).path(percentEncoded: false)
                #expect(IndexSnapshot.join(base, rel) == expected, "\(base) + \(rel)")
            }
        }
    }
}
