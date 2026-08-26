import Testing
import Foundation
@testable import InkstoneCore

/// The diff, which decides what a person is shown and what gets written.
///
/// The property that matters most is the last one here: accepting everything
/// must produce exactly what was proposed, and rejecting everything must leave
/// the file byte-identical. Everything else is presentation.
@Suite("Diff")
struct DiffTests {
    @Test("A replaced line is one hunk, not a delete and an insert")
    func pairsReplacements() {
        // Two hunks would make the reader pair them up mentally, and would let
        // half a replacement be accepted.
        let hunks = Diff.hunks(from: "a\nb\nc", to: "a\nB\nc")
        #expect(hunks.count == 1)
        #expect(hunks[0].removedLines == ["b"])
        #expect(hunks[0].added == ["B"])
    }

    @Test("Separate edits are separate hunks")
    func separatesDistantChanges() {
        let hunks = Diff.hunks(from: "a\nb\nc\nd\ne", to: "A\nb\nc\nd\nE")
        #expect(hunks.count == 2)
    }

    @Test("Identical text has no hunks")
    func detectsNoChange() {
        #expect(Diff.hunks(from: "same\ntext", to: "same\ntext").isEmpty)
    }

    @Test("A pure insertion removes nothing")
    func handlesInsertions() {
        let hunks = Diff.hunks(from: "a\nc", to: "a\nb\nc")
        #expect(hunks.count == 1)
        #expect(hunks[0].isInsertion)
        #expect(hunks[0].added == ["b"])
    }

    @Test("A pure deletion adds nothing")
    func handlesDeletions() {
        let hunks = Diff.hunks(from: "a\nb\nc", to: "a\nc")
        #expect(hunks.count == 1)
        #expect(hunks[0].isDeletion)
        #expect(hunks[0].removedLines == ["b"])
    }

    @Test("Creating a note is all insertion")
    func handlesCreation() {
        let hunks = Diff.hunks(from: "", to: "# New\n\nBody")
        #expect(hunks.count == 1)
        #expect(hunks[0].added == ["# New", "", "Body"])
    }

    @Test("A trailing blank line is not silently dropped")
    func keepsTrailingNewlines() {
        // `split` loses it, and a diff that quietly rewrites the end of every
        // file it touches is worse than one that shows a spurious change.
        #expect(Diff.lines("a\nb\n") == ["a", "b", ""])
        #expect(Diff.join(Diff.lines("a\nb\n")) == "a\nb\n")
    }

    // MARK: - The properties that matter

    @Test("Accepting everything reproduces the proposal exactly")
    func acceptingAllIsTheProposal() {
        let cases: [(String, String)] = [
            ("a\nb\nc", "a\nB\nc"),
            ("", "brand new"),
            ("delete\nme", ""),
            ("one", "one\ntwo\nthree"),
            ("# 标题\n\n正文", "# 新标题\n\n正文\n\n补充"),
            ("a\nb\nc\nd\ne\nf", "a\nX\nc\nY\ne\nZ"),
        ]
        for (before, after) in cases {
            let hunks = Diff.hunks(from: before, to: after)
            #expect(Diff.apply(hunks, to: before) == after,
                    "accepting all of \(before.debugDescription) → \(after.debugDescription) diverged")
        }
    }

    @Test("Rejecting everything leaves the file byte-identical")
    func rejectingAllIsTheOriginal() {
        // The one that must never be wrong. A reviewer who rejects a change and
        // finds the file altered anyway cannot trust the review at all.
        let cases: [(String, String)] = [
            ("a\nb\nc", "a\nB\nc"),
            ("delete\nme", ""),
            ("one", "one\ntwo"),
            ("# 标题\n\n正文", "完全不同的内容"),
        ]
        for (before, after) in cases {
            var hunks = Diff.hunks(from: before, to: after)
            for index in hunks.indices { hunks[index].isAccepted = false }
            #expect(Diff.apply(hunks, to: before) == before,
                    "rejecting all of \(before.debugDescription) changed the file")
        }
    }

    @Test("Accepting one hunk of two takes only that one")
    func appliesHunksIndependently() {
        let before = "a\nb\nc\nd\ne"
        let after = "A\nb\nc\nd\nE"
        var hunks = Diff.hunks(from: before, to: after)
        #expect(hunks.count == 2)

        hunks[1].isAccepted = false
        #expect(Diff.apply(hunks, to: before) == "A\nb\nc\nd\ne")

        hunks[0].isAccepted = false
        hunks[1].isAccepted = true
        #expect(Diff.apply(hunks, to: before) == "a\nb\nc\nd\nE")
    }
}

@Suite("Pending edits")
struct PendingEditTests {
    @Test("A pending edit is not a change to the file")
    func staysPending() {
        let edit = PendingEdit(path: "a.md", before: "old", after: "new", summary: "rewrite")
        #expect(edit.resolved == "new")
        edit.hunks.forEach { #expect($0.isAccepted) }

        var rejected = edit
        rejected.setAll(false)
        #expect(rejected.resolved == "old")
        #expect(!rejected.hasAcceptedChanges)
    }

    @Test("Several edits to one note fold into one review")
    func foldsRepeatedEdits() {
        // An agent restructuring a note edits it several times in a turn. Kept
        // separate, the reviewer sees a diff against a version that never
        // existed on disk.
        var queue = EditQueue()
        queue.add(PendingEdit(path: "a.md", before: "one", after: "two", summary: "first"))
        queue.add(PendingEdit(path: "a.md", before: "two", after: "three", summary: "second"))

        #expect(queue.count == 1)
        // The diff is against what is on disk, not against the intermediate.
        #expect(queue.edits[0].before == "one")
        #expect(queue.edits[0].after == "three")
        #expect(queue.edits[0].summary.contains("first"))
        #expect(queue.edits[0].summary.contains("second"))
    }

    @Test("A queued edit is what the assistant reads back")
    func readsBackItsOwnEdits() {
        // Otherwise the assistant sees its change did not happen and makes it
        // again, which is both a wasted round and a second edit to review.
        var queue = EditQueue()
        queue.add(PendingEdit(path: "a.md", before: "old", after: "new", summary: ""))
        #expect(queue.currentText(of: "a.md") == "new")
        #expect(queue.currentText(of: "other.md") == nil)
    }

    @Test("Edits to different notes stay separate")
    func keepsFilesApart() {
        var queue = EditQueue()
        queue.add(PendingEdit(path: "a.md", before: "x", after: "y", summary: ""))
        queue.add(PendingEdit(path: "b.md", before: "p", after: "q", summary: ""))
        #expect(queue.count == 2)
        #expect(queue.affectedPaths == ["a.md", "b.md"])
    }

    @Test("A creation reports itself as one")
    func marksCreations() {
        let edit = PendingEdit(path: "new.md", before: nil, after: "# New", summary: "")
        #expect(edit.isCreation)
        // Rejecting a creation leaves nothing, not an empty file.
        var rejected = edit
        rejected.setAll(false)
        #expect(!rejected.hasAcceptedChanges)
    }
}

/// The writing tools, which propose rather than write.
@Suite("Write tools")
struct WriteToolTests {
    private func vault(_ files: [String: String]) throws
        -> (URL, NoteToolbox, PendingEditStore) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "write-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var notes: [NoteMetadata] = []
        for (name, text) in files {
            let url = root.appending(path: name)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
            notes.append(NoteParser.parse(text: text, url: url))
        }
        let snapshot = IndexBuilder.assemble(notes, vaultRoot: root)
        let store = PendingEditStore()
        return (root, NoteToolbox(snapshot: snapshot, store: NoteStore(root: root),
                                  vaultRoot: root, edits: store), store)
    }

    @Test("A proposed edit does not touch the file")
    func writesNothingToDisk() async throws {
        // The whole premise. If this is ever false, the review step is theatre.
        let (root, tools, _) = try vault(["a.md": "original"])
        defer { try? FileManager.default.removeItem(at: root) }

        let outcome = await tools.run("edit_note", input: .object([
            "path": .string("a.md"),
            "old_text": .string("original"),
            "new_text": .string("changed"),
        ]))
        #expect(!outcome.isError)
        #expect(try String(contentsOf: root.appending(path: "a.md"), encoding: .utf8) == "original")
        // And it says so, so the model does not report the work as done.
        #expect(outcome.content.contains("not been saved"))
    }

    @Test("A creation does not touch the disk either")
    func createsNothingOnDisk() async throws {
        let (root, tools, edits) = try vault([:])
        defer { try? FileManager.default.removeItem(at: root) }

        _ = await tools.run("create_note", input: .object([
            "path": .string("new.md"), "content": .string("# New"),
        ]))
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "new.md").path))
        let queue = await edits.snapshot()
        #expect(queue.count == 1)
        #expect(queue.edits[0].isCreation)
    }

    @Test("A path without .md still becomes a note")
    func addsTheExtension() async throws {
        let (root, tools, edits) = try vault([:])
        defer { try? FileManager.default.removeItem(at: root) }
        _ = await tools.run("create_note", input: .object([
            "path": .string("notes/summary"), "content": .string("x"),
        ]))
        #expect(await edits.snapshot().edits[0].path == "notes/summary.md")
    }

    @Test("Creating over an existing note is refused")
    func refusesToClobber() async throws {
        // The model has a tool for changing a note. Honouring create_note on one
        // that exists would replace someone's writing with no diff to notice.
        let (root, tools, _) = try vault(["a.md": "precious"])
        defer { try? FileManager.default.removeItem(at: root) }

        let outcome = await tools.run("create_note", input: .object([
            "path": .string("a.md"), "content": .string("replacement"),
        ]))
        #expect(outcome.isError)
        #expect(outcome.content.contains("edit_note"))
    }

    @Test("Text that does not match exactly is refused")
    func requiresAnExactMatch() async throws {
        let (root, tools, edits) = try vault(["a.md": "the quick brown fox"])
        defer { try? FileManager.default.removeItem(at: root) }

        let outcome = await tools.run("edit_note", input: .object([
            "path": .string("a.md"),
            "old_text": .string("the quick red fox"),
            "new_text": .string("x"),
        ]))
        #expect(outcome.isError)
        #expect(await edits.snapshot().isEmpty)
    }

    @Test("Ambiguous text is refused rather than guessed at")
    func refusesAmbiguousMatches() async throws {
        // Applying a near-match anyway is how an edit lands in the wrong
        // paragraph of someone's own writing.
        let (root, tools, edits) = try vault(["a.md": "TODO\nsomething\nTODO"])
        defer { try? FileManager.default.removeItem(at: root) }

        let outcome = await tools.run("edit_note", input: .object([
            "path": .string("a.md"),
            "old_text": .string("TODO"),
            "new_text": .string("DONE"),
        ]))
        #expect(outcome.isError)
        #expect(outcome.content.contains("2 times"))
        #expect(await edits.snapshot().isEmpty)
    }

    @Test("Writing outside the vault is refused")
    func refusesEscapes() async throws {
        let (root, tools, edits) = try vault(["a.md": "x"])
        defer { try? FileManager.default.removeItem(at: root) }

        for path in ["/tmp/evil.md", "../escape.md", "~/.ssh/authorized_keys"] {
            let outcome = await tools.run("create_note", input: .object([
                "path": .string(path), "content": .string("x"),
            ]))
            #expect(outcome.isError, "\(path) was not refused")
        }
        #expect(await edits.snapshot().isEmpty)
    }

    @Test("The assistant reads back its own pending change")
    func readsBackPendingEdits() async throws {
        // Otherwise it sees the edit did not happen and makes it again.
        let (root, tools, _) = try vault(["a.md": "before"])
        defer { try? FileManager.default.removeItem(at: root) }

        _ = await tools.run("edit_note", input: .object([
            "path": .string("a.md"),
            "old_text": .string("before"), "new_text": .string("after"),
        ]))
        let read = await tools.run("read_note", input: .object(["path": .string("a.md")]))
        #expect(read.content.contains("after"))
        #expect(!read.content.contains("before"))
    }

    @Test("Two edits to one note review as one diff against disk")
    func foldsSequentialEdits() async throws {
        let (root, tools, edits) = try vault(["a.md": "one\ntwo\nthree"])
        defer { try? FileManager.default.removeItem(at: root) }

        _ = await tools.run("edit_note", input: .object([
            "path": .string("a.md"), "old_text": .string("one"), "new_text": .string("ONE"),
        ]))
        _ = await tools.run("edit_note", input: .object([
            "path": .string("a.md"), "old_text": .string("three"), "new_text": .string("THREE"),
        ]))

        let queue = await edits.snapshot()
        #expect(queue.count == 1)
        // Against what is on disk, so the review shows what would be saved
        // rather than a step in the middle.
        #expect(queue.edits[0].before == "one\ntwo\nthree")
        #expect(queue.edits[0].after == "ONE\ntwo\nTHREE")
        #expect(queue.edits[0].hunks.count == 2)
    }

    @Test("A read-only toolbox does not offer the writing tools")
    func hidesWriteToolsWhenReadOnly() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "ro-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let readOnly = NoteToolbox(snapshot: IndexSnapshot(),
                                   store: NoteStore(root: root), vaultRoot: root)
        #expect(!readOnly.canWrite)
        #expect(!NoteToolbox.definitions(canWrite: false).contains { $0.name == "edit_note" })
        #expect(NoteToolbox.definitions(canWrite: true).contains { $0.name == "edit_note" })
        // And calling one anyway is refused rather than crashing.
        #expect(await readOnly.run("edit_note", input: .object([:])).isError)
    }
}
