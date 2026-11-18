import Testing
import Foundation
@testable import InkstoneCore

/// An incremental index (`build(vaultRoot:reusing:)`) must be indistinguishable
/// from a full rebuild. A missed change would show up as stale backlinks or
/// search results, which reads to a user like lost data — so every kind of
/// change the app makes is replayed here and the two snapshots are compared
/// table by table.
@Suite("Incremental index")
struct IncrementalIndexTests {

    /// Everything a view reads from a snapshot, in a comparable form.
    struct Fingerprint: Equatable {
        var notes: [String: String]          // path → title|tags|links|words
        var edges: [String]
        var backlinks: [String: Int]
        var tags: [String: Int]
        var unresolved: [String: Int]
        var ordered: [String]

        init(_ s: IndexSnapshot) {
            notes = Dictionary(uniqueKeysWithValues: s.notes.map { url, n in
                (url.path, "\(n.title)|\(n.tags.sorted())|\(n.outgoingLinks.map(\.target))|\(n.wordCount)")
            })
            edges = s.edges.map { "\($0.source.path)→\($0.destination?.path ?? "?" + $0.unresolvedTarget)" }.sorted()
            backlinks = s.backlinks.mapValues(\.count).reduce(into: [:]) { $0[$1.key.path] = $1.value }
            tags = s.tagCounts
            unresolved = s.unresolved
            ordered = s.orderedNotes.map(\.path)
        }
    }

    static func vault() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "inkstone-incr-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root.appending(path: "A"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appending(path: "B"), withIntermediateDirectories: true)
        for i in 0..<30 {
            let folder = i % 2 == 0 ? "A" : "B"
            try "# Note \(i)\n#t\(i % 4) links [[Note \((i + 1) % 30)]] and [[Missing \(i % 3)]]\n"
                .write(to: root.appending(path: "\(folder)/Note \(i).md"), atomically: true, encoding: .utf8)
        }
        return root
    }

    /// Sets a file's modification date, so a test does not have to wait for the
    /// "recently touched files are always re-parsed" window to pass.
    static func age(_ url: URL, by seconds: TimeInterval) throws {
        try FileManager.default.setAttributes(
            [.modificationDate: Date.now.addingTimeInterval(-seconds)], ofItemAtPath: url.path)
    }

    static func ageAll(_ root: URL) throws {
        let files = VaultScanner().markdownFiles(in: root)
        for (i, f) in files.enumerated() { try age(f, by: 600 + Double(i)) }
    }

    func expectSame(_ root: URL, previous: IndexSnapshot) async -> IndexSnapshot {
        let incremental = await IndexBuilder().build(vaultRoot: root, reusing: previous)
        let full = await IndexBuilder().build(vaultRoot: root)
        #expect(Fingerprint(incremental) == Fingerprint(full))
        return incremental
    }

    @Test func editAddDeleteAndRenameAllMatchAFullRebuild() async throws {
        let root = try Self.vault()
        defer { try? FileManager.default.removeItem(at: root) }
        try Self.ageAll(root)
        var snapshot = await IndexBuilder().build(vaultRoot: root)

        // Edit: new title, new tag, a link that now resolves.
        let edited = root.appending(path: "A/Note 2.md")
        try "# Renamed title\n#fresh [[Note 7]] [[Brand New]]\n".write(to: edited, atomically: true, encoding: .utf8)
        try Self.age(edited, by: 300)   // older than the window, but newer than before
        snapshot = await expectSame(root, previous: snapshot)

        // Add: a note that resolves a previously unresolved target.
        let added = root.appending(path: "B/Brand New.md")
        try "# Brand New\n[[Note 2]]\n".write(to: added, atomically: true, encoding: .utf8)
        try Self.age(added, by: 200)
        snapshot = await expectSame(root, previous: snapshot)

        // Delete: links to it become unresolved again.
        try FileManager.default.removeItem(at: root.appending(path: "A/Note 4.md"))
        snapshot = await expectSame(root, previous: snapshot)

        // Rename (move across folders).
        try FileManager.default.moveItem(at: root.appending(path: "B/Note 5.md"),
                                         to: root.appending(path: "A/Note 5 moved.md"))
        snapshot = await expectSame(root, previous: snapshot)
    }

    /// The case a modification date alone cannot catch: a write within the same
    /// second as the previous parse, on a file system with coarse timestamps.
    /// Files touched in the last few seconds must never be reused.
    @Test func aJustWrittenFileIsAlwaysReparsedEvenWithAnUnchangedDate() async throws {
        let root = try Self.vault()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "A/Note 0.md")
        let pinned = Date.now
        try FileManager.default.setAttributes([.modificationDate: pinned], ofItemAtPath: file.path)
        let before = await IndexBuilder().build(vaultRoot: root)

        try "# Changed in the same second\n".write(to: file, atomically: false, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: pinned], ofItemAtPath: file.path)

        let after = await IndexBuilder().build(vaultRoot: root, reusing: before)
        // Look the note up by name: the scanner may report the temporary
        // directory through its /private symlink, so the URL keys differ.
        let note = after.notes.values.first { $0.basename == "Note 0" }
        #expect(note?.title == "Changed in the same second")
    }

    /// Randomised sequences of the same operations, compared after every step.
    @Test func randomEditSequencesStayIdentical() async throws {
        let root = try Self.vault()
        defer { try? FileManager.default.removeItem(at: root) }
        try Self.ageAll(root)
        var snapshot = await IndexBuilder().build(vaultRoot: root)
        var rng = SystemRandomNumberGenerator()
        var age: TimeInterval = 500
        for step in 0..<25 {
            let files = VaultScanner().markdownFiles(in: root)
            let pick = files[Int.random(in: 0..<files.count, using: &rng)]
            switch Int.random(in: 0..<4, using: &rng) {
            case 0, 1:
                try "# Step \(step)\n#s\(step % 5) [[Note \(step % 30)]] [[X \(step % 4)]]\n"
                    .write(to: pick, atomically: true, encoding: .utf8)
                try Self.age(pick, by: age)
            case 2:
                let new = root.appending(path: "\(step % 2 == 0 ? "A" : "B")/Fresh \(step).md")
                try "# Fresh \(step)\n[[\(pick.deletingPathExtension().lastPathComponent)]]\n"
                    .write(to: new, atomically: true, encoding: .utf8)
                try Self.age(new, by: age)
            default:
                if files.count > 5 { try FileManager.default.removeItem(at: pick) }
            }
            age -= 10
            snapshot = await expectSame(root, previous: snapshot)
        }
    }
}
