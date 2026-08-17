import Foundation
import Testing
@testable import InkstoneCore

/// A file that is on disk but excluded from syncing must not look deleted.
///
/// The two sides of the policy were asked different questions. The vault scan
/// asks `allows(url, sizeBytes:)`, so a file over the size limit never enters the
/// local map; the planner asks `allows(url)` with no size, so the same file is
/// not filtered there either. The path in between reads "not in the local map"
/// as "the user deleted it" — and the remote copy is what pays.
@Suite("Sync size exclusion")
struct SyncSizeExclusionTests {

    private var policy: SyncFilePolicy {
        var policy = SyncFilePolicy()
        policy.syncsImages = true
        policy.maximumFileSizeMB = 1
        return policy
    }

    /// The dangerous case: it synced before, so remote matches base, and the only
    /// thing that changed is that the local scan stopped reporting it.
    @Test("An oversized attachment is not deleted from the remote")
    func oversizedIsNotDeletedRemotely() {
        let path = "Attachments/big.png"
        let actions = SyncPlanner.plan(
            entries: [SyncEntry(path: path, local: nil, remote: "abc", base: "abc")],
            policy: policy,
            excludedLocally: [path]
        )
        #expect(actions == [.skip(path: path, reason: .filtered)])
    }

    /// And it is not pulled down again either, which would be the other way to
    /// get this wrong: re-downloading on every run a file the vault has chosen
    /// not to carry.
    @Test("An oversized attachment is not downloaded again")
    func oversizedIsNotDownloaded() {
        let path = "Attachments/big.png"
        let actions = SyncPlanner.plan(
            entries: [SyncEntry(path: path, local: nil, remote: "abc", base: nil)],
            policy: policy,
            excludedLocally: [path]
        )
        #expect(actions == [.skip(path: path, reason: .filtered)])
    }

    /// The exclusion is about this vault's local copy, so it must not suppress
    /// work on files that were never excluded.
    @Test("Files within the limit are unaffected")
    func ordinaryFilesStillSync() {
        let actions = SyncPlanner.plan(
            entries: [SyncEntry(path: "Note.md", local: "aaa", remote: nil, base: nil)],
            policy: policy,
            excludedLocally: ["Attachments/big.png"]
        )
        #expect(actions == [.upload(path: "Note.md")])
    }

    /// Nothing excluded is the ordinary case and must behave exactly as before.
    @Test("An absent local file with no exclusion is still a deletion")
    func absenceStillMeansDeletionWhenNotExcluded() {
        let actions = SyncPlanner.plan(
            entries: [SyncEntry(path: "Gone.md", local: nil, remote: "abc", base: "abc")],
            policy: policy
        )
        #expect(actions == [.deleteRemote(path: "Gone.md")])
    }
}
