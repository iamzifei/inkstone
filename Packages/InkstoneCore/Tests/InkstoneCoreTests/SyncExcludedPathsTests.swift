import Testing
import Foundation
@testable import InkstoneCore

/// `excludedPaths` is the per-device half of "what does this vault carry".
///
/// It exists because two devices sharing one vault can only collide on files
/// they both hold, and the cheapest way to stop a collision is for one side not
/// to hold the file at all. The dangerous failure is not "the exclusion did not
/// work" — it is "the exclusion worked and took the remote copy with it", so
/// that case is pinned down first.
@Suite("Sync path exclusions")
struct SyncExcludedPathsTests {

    private func policy(excluding patterns: [String]) -> SyncFilePolicy {
        var policy = SyncFilePolicy()
        policy.excludedPaths = patterns
        return policy
    }

    private func action(
        _ entry: SyncEntry, excluding patterns: [String], excludedLocally: Set<String> = []
    ) -> SyncAction {
        SyncPlanner.plan(
            entries: [entry], policy: policy(excluding: patterns),
            excludedLocally: excludedLocally
        )[0]
    }

    // MARK: - The reason the feature exists

    @Test("A remote-only file under an excluded folder is not downloaded")
    func remoteOnlyIsNotFetched() {
        // The local scan never sees this file, so the local-side guard cannot
        // help: without the planner-side check it lands on the device the
        // exclusion exists to keep it off.
        let entry = SyncEntry(path: "00-rules/policy.md", local: nil, remote: "a", base: nil)
        #expect(
            action(entry, excluding: ["00-rules/"])
                == .skip(path: "00-rules/policy.md", reason: .filtered)
        )
    }

    @Test("Excluding a folder never deletes the remote copy")
    func exclusionDoesNotDelete() {
        // The file is on the remote and absent locally because it is excluded.
        // Read as a deletion, this would wipe it for every other device — the
        // exact accident that the size-limit setting caused before it recorded
        // its skips.
        let entry = SyncEntry(path: "docs/deep.md", local: nil, remote: "a", base: "a")
        let result = action(
            entry, excluding: ["docs/"], excludedLocally: ["docs/deep.md"]
        )
        #expect(result == .skip(path: "docs/deep.md", reason: .filtered))
        #expect(result != .deleteRemote(path: "docs/deep.md"))
    }

    @Test("A conflict inside an excluded folder never arises")
    func conflictSuppressed() {
        // Both sides changed, which is a conflict for any carried file. Excluded,
        // it is simply not this device's business.
        let entry = SyncEntry(path: "00-rules/policy.md", local: "b", remote: "c", base: "a")
        #expect(
            action(entry, excluding: ["00-rules/"])
                == .skip(path: "00-rules/policy.md", reason: .filtered)
        )
    }

    // MARK: - Not over-reaching

    @Test("Files outside the excluded folder are untouched")
    func siblingsStillSync() {
        let entry = SyncEntry(path: "drafts/note.md", local: "a", remote: nil, base: nil)
        #expect(action(entry, excluding: ["00-rules/"]) == .upload(path: "drafts/note.md"))
    }

    @Test("A folder name matches only that folder, not a prefix of another")
    func noPrefixBleed() {
        let entry = SyncEntry(path: "00-rules-archive/old.md", local: "a", remote: nil, base: nil)
        #expect(
            action(entry, excluding: ["00-rules/"]) == .upload(path: "00-rules-archive/old.md")
        )
    }

    @Test("An empty exclusion list changes nothing")
    func emptyIsInert() {
        let entry = SyncEntry(path: "00-rules/policy.md", local: "a", remote: nil, base: nil)
        #expect(action(entry, excluding: []) == .upload(path: "00-rules/policy.md"))
    }

    @Test("Patterns beyond folders work, because the syntax is .gitignore's")
    func patternsNotJustFolders() {
        let glob = SyncEntry(path: "docs/draft.tmp.md", local: "a", remote: nil, base: nil)
        #expect(
            action(glob, excluding: ["*.tmp.md"])
                == .skip(path: "docs/draft.tmp.md", reason: .filtered)
        )

        let negated = SyncEntry(path: "00-rules/keep.md", local: "a", remote: nil, base: nil)
        #expect(
            action(negated, excluding: ["00-rules/", "!keep.md"])
                == .upload(path: "00-rules/keep.md")
        )
    }

    // MARK: - Stored settings must survive the new field

    @Test("A policy stored before this field existed still decodes")
    func decodesLegacyJSON() throws {
        // The synthesized initialiser would throw on the missing key, and a
        // policy that fails to decode is a policy reset to defaults — which for
        // a vault means silently changing what it carries.
        let legacy = """
        {"syncsImages":true,"syncsAudio":true,"syncsPDFs":true,
         "syncsVideos":false,"syncsOtherFiles":false,"maximumFileSizeMB":100}
        """
        let decoded = try JSONDecoder().decode(SyncFilePolicy.self, from: Data(legacy.utf8))
        #expect(decoded.maximumFileSizeMB == 100)
        #expect(decoded.excludedPaths.isEmpty)
    }

    @Test("A policy missing every key decodes to the defaults")
    func decodesEmptyJSON() throws {
        let decoded = try JSONDecoder().decode(SyncFilePolicy.self, from: Data("{}".utf8))
        #expect(decoded == SyncFilePolicy())
    }

    @Test("Exclusions survive a round trip")
    func roundTrips() throws {
        var original = SyncFilePolicy()
        original.excludedPaths = ["00-rules/", "docs/", "*.tmp.md"]
        let data = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode(SyncFilePolicy.self, from: data) == original)
    }
}
