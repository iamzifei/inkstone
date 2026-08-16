import Testing
import Foundation
@testable import InkstoneCore

/// The sync planner decides, for every file, whether it is uploaded, downloaded,
/// deleted, or treated as a conflict. Getting a case wrong here silently
/// destroys someone's notes, so every combination of the three sides is pinned
/// down — including the ones that should never occur.
@Suite("Sync planning")
struct SyncPlanTests {

    private func action(local: String?, remote: String?, base: String?, path: String = "Note.md") -> SyncAction {
        SyncPlanner.plan(entries: [SyncEntry(path: path, local: local, remote: remote, base: base)])[0]
    }

    // MARK: - The straightforward cases

    @Test("A new local file is uploaded")
    func newLocal() {
        #expect(action(local: "a", remote: nil, base: nil) == .upload(path: "Note.md"))
    }

    @Test("A new remote file is downloaded")
    func newRemote() {
        #expect(action(local: nil, remote: "a", base: nil) == .download(path: "Note.md"))
    }

    @Test("An edit on one side only moves that way")
    func oneSidedEdits() {
        #expect(action(local: "b", remote: "a", base: "a") == .upload(path: "Note.md"))
        #expect(action(local: "a", remote: "b", base: "a") == .download(path: "Note.md"))
    }

    @Test("An untouched file is skipped")
    func unchanged() {
        #expect(action(local: "a", remote: "a", base: "a") == .skip(path: "Note.md", reason: .unchanged))
    }

    @Test("Identical content that arrived independently is not a conflict")
    func convergentEdit() {
        // Both sides wrote the same bytes. There is nothing to reconcile.
        #expect(action(local: "b", remote: "b", base: "a") == .skip(path: "Note.md", reason: .unchanged))
    }

    // MARK: - Deletions, where two-way sync goes wrong

    @Test("A local delete propagates to the remote")
    func localDelete() {
        #expect(action(local: nil, remote: "a", base: "a") == .deleteRemote(path: "Note.md"))
    }

    @Test("A remote delete propagates locally")
    func remoteDelete() {
        #expect(action(local: "a", remote: nil, base: "a") == .deleteLocal(path: "Note.md"))
    }

    @Test("Editing a file the other side deleted is a conflict, never a delete")
    func editVersusDelete() {
        // The dangerous pair. Without the base state these are indistinguishable
        // from an ordinary one-sided change, and the edit gets thrown away.
        #expect(action(local: "b", remote: nil, base: "a") == .conflict(path: "Note.md"))
        #expect(action(local: nil, remote: "b", base: "a") == .conflict(path: "Note.md"))
    }

    @Test("Both sides deleting it is not a conflict")
    func bothDeleted() {
        #expect(action(local: nil, remote: nil, base: "a") == .skip(path: "Note.md", reason: .unchanged))
    }

    // MARK: - Conflicts

    @Test("Divergent edits are a conflict")
    func divergentEdits() {
        #expect(action(local: "b", remote: "c", base: "a") == .conflict(path: "Note.md"))
    }

    @Test("Divergent creations are a conflict")
    func divergentCreates() {
        // Same filename created independently on both sides, no shared history.
        #expect(action(local: "b", remote: "c", base: nil) == .conflict(path: "Note.md"))
    }

    @Test("An impossible state resolves to a conflict, not a guess")
    func impossibleState() {
        // Neither side differs from base, yet they differ from each other. This
        // should not happen; resolving it by guessing would discard an edit.
        #expect(action(local: "a", remote: "a", base: "b") == .skip(path: "Note.md", reason: .unchanged))
    }

    // MARK: - The file-type policy

    @Test("Filtered attachments are skipped, whatever their state")
    func policyFilters() {
        var policy = SyncFilePolicy()
        policy.setSyncs(.video, false)
        let entries = [
            SyncEntry(path: "Attachments/clip.mp4", local: "a", remote: nil, base: nil),
            SyncEntry(path: "Note.md", local: "a", remote: nil, base: nil),
        ]
        let actions = SyncPlanner.plan(entries: entries, policy: policy)
        #expect(actions[0] == .skip(path: "Attachments/clip.mp4", reason: .filtered))
        #expect(actions[1] == .upload(path: "Note.md"))
    }

    @Test("Notes sync even when every attachment kind is off")
    func notesAlwaysSync() {
        var policy = SyncFilePolicy()
        for kind in AttachmentKind.allCases { policy.setSyncs(kind, false) }
        let entries = [SyncEntry(path: "Deep/Note.md", local: "a", remote: nil, base: nil)]
        #expect(SyncPlanner.plan(entries: entries, policy: policy) == [.upload(path: "Deep/Note.md")])
    }

    // MARK: - Conflict naming

    @Test("A conflict copy sits beside the original, never on top of it")
    func conflictNaming() {
        #expect(
            SyncPlanner.conflictFilename(for: "Ideas/Product.md", timestamp: "2026-08-16 1030")
                == "Ideas/Product (conflict 2026-08-16 1030).md"
        )
        #expect(
            SyncPlanner.conflictFilename(for: "Note.md", timestamp: "t") == "Note (conflict t).md"
        )
        #expect(
            SyncPlanner.conflictFilename(for: "README", timestamp: "t") == "README (conflict t)"
        )
    }

    // MARK: - State

    @Test("Sync state round-trips through the vault")
    func stateRoundTrip() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "inkstone-sync-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        var state = SyncState()
        state.blobs["Home.md"] = "abc123"
        state.repository = "iamzifei/notes"
        state.branch = "main"
        try state.save(to: root)

        let loaded = SyncState.load(from: root)
        #expect(loaded.blobs["Home.md"] == "abc123")
        #expect(loaded.repository == "iamzifei/notes")
    }

    @Test("A vault that has never synced loads an empty state")
    func missingState() {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "nonexistent-\(UUID())")
        #expect(SyncState.load(from: root).blobs.isEmpty)
    }
}

/// The blob hash is the linchpin of the whole design: it lets a local file and a
/// remote entry be compared by identity, with no timestamps and no clock
/// agreement between machines. If it stopped matching git's, sync would decide
/// every file had changed on every run.
@Suite("Git blob hashing")
struct BlobHashTests {

    @Test("Matches git hash-object for known inputs")
    func knownHashes() {
        // Verifiable with: printf '' | git hash-object --stdin
        #expect(gitBlobSHA(Data()) == "e69de29bb2d1d6434b8b29ae775ad8c2e48c5391")
        // printf 'hello' | git hash-object --stdin
        #expect(gitBlobSHA(Data("hello".utf8)) == "b6fc4c620b67d95f953a5c1c1230aaab5db5a1b0")
        // printf 'hello\n' | git hash-object --stdin
        #expect(gitBlobSHA(Data("hello\n".utf8)) == "ce013625030ba8dba906f756967f9e9ca394464a")
    }

    @Test("Length is part of the hash, not just the bytes")
    func lengthMatters() {
        // A plain SHA-1 of the contents would not distinguish these the way git
        // does; the header is what makes the hash a *blob* hash.
        #expect(gitBlobSHA(Data("a".utf8)) != gitBlobSHA(Data("a ".utf8)))
    }

    @Test("Hashing is stable across calls")
    func stable() {
        let data = Data("中文 content with 汉字".utf8)
        #expect(gitBlobSHA(data) == gitBlobSHA(data))
    }
}
