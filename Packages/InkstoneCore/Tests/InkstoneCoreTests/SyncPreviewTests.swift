import Foundation
import Testing
@testable import InkstoneCore

/// "Preview next sync": the plan, computed exactly as a run computes it, with
/// nothing written — not to the vault, not to GitHub, not to sync.json.
extension GitHubClientTests {

  @Suite("Sync preview", .serialized)
  struct SyncPreviewTests {
    typealias Remote = TwoDeviceSyncTests.FakeRemote

    func vault(_ label: String) throws -> URL {
        let raw = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "inkstone-\(label)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
        let path = raw.path.hasPrefix("/var/") ? "/private" + raw.path : raw.path
        return URL(fileURLWithPath: path, isDirectory: true)
    }
    func engine(_ vault: URL, _ remote: Remote) -> SyncEngine {
        SyncEngine(client: TwoDeviceSyncTests.client(remote), vaultRoot: vault, policy: SyncFilePolicy())
    }
    func snapshot(_ dir: URL) -> [String: Data] {
        var out: [String: Data] = [:]
        let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)
        while let u = e?.nextObject() as? URL {
            if let d = try? Data(contentsOf: u) { out[u.path] = d }
        }
        return out
    }

    @Test("Preview lists what a run will do, and changes nothing")
    func previewMatchesTheRunAndWritesNothing() async throws {
        let remote = Remote()
        let mac = try vault("mac"), phone = try vault("phone")
        defer { try? FileManager.default.removeItem(at: mac); try? FileManager.default.removeItem(at: phone) }
        try Data("a\n".utf8).write(to: mac.appending(path: "a.md"))
        try Data("b\n".utf8).write(to: mac.appending(path: "b.md"))
        try Data("keep\n".utf8).write(to: mac.appending(path: "keep.md"))
        _ = try await engine(mac, remote).run()
        _ = try await engine(phone, remote).run()

        try Data("a2\n".utf8).write(to: mac.appending(path: "a.md"))          // upload
        try FileManager.default.removeItem(at: mac.appending(path: "b.md"))    // delete on GitHub
        remote.put("new.md", "from elsewhere\n")                                // download

        let diskBefore = snapshot(mac), remoteBefore = remote.paths.map { remote.contents($0) }
        let preview = try await engine(mac, remote).preview()
        #expect(preview.uploads == ["a.md"])
        #expect(preview.deletesRemote == ["b.md"])
        #expect(preview.downloads == ["new.md"])
        #expect(preview.deletesLocal.isEmpty && preview.conflicts.isEmpty)
        #expect(!preview.needsFirstSyncDirection && !preview.wouldStopForLargeDeletion)
        #expect(snapshot(mac) == diskBefore, "preview wrote to the vault")
        #expect(remote.paths.map { remote.contents($0) } == remoteBefore, "preview wrote to GitHub")

        let report = try await engine(mac, remote).run()
        #expect(report.uploaded == preview.uploads)
        #expect(report.deletedRemotely == preview.deletesRemote)
        #expect(report.downloaded == preview.downloads)
    }

    @Test("Preview flags a first sync that needs a direction and a run the deletion guard would stop")
    func previewFlagsQuestionsInsteadOfThrowing() async throws {
        let remote = Remote()
        let mac = try vault("mac"); defer { try? FileManager.default.removeItem(at: mac) }
        remote.put("n.md", "remote\n")
        try Data("local\n".utf8).write(to: mac.appending(path: "n.md"))
        let first = try await engine(mac, remote).preview()
        #expect(first.needsFirstSyncDirection)
        #expect(first.conflicts == ["n.md"])

        let big = try vault("big"); defer { try? FileManager.default.removeItem(at: big) }
        let remote2 = Remote()
        for i in 0..<20 { try Data("\(i)\n".utf8).write(to: big.appending(path: "n\(i).md")) }
        _ = try await engine(big, remote2).run()
        for i in 0..<15 { try FileManager.default.removeItem(at: big.appending(path: "n\(i).md")) }
        let bigBefore = snapshot(big)
        let mass = try await engine(big, remote2).preview()
        #expect(mass.wouldStopForLargeDeletion)
        #expect(mass.deletesRemote.count == 15)
        #expect(snapshot(big) == bigBefore, "preview wrote to the vault")
    }

    /// A remote that has gone empty while files were recorded is far more often
    /// a wrong branch or a token that lost access than a real deletion. The
    /// preview says so, rather than listing every note under "Delete here".
    @Test("An empty remote is reported as such, not as a list of local deletions")
    func previewReportsAnEmptyRemote() async throws {
        let remote = Remote()
        let mac = try vault("mac"); defer { try? FileManager.default.removeItem(at: mac) }
        try Data("a\n".utf8).write(to: mac.appending(path: "a.md"))
        _ = try await engine(mac, remote).run()
        for path in remote.paths { remote.put(path, "") }
        let emptied = Remote()
        let preview = try await engine(mac, emptied).preview()
        #expect(preview.remoteLooksEmpty)
        #expect(preview.deletesLocal.isEmpty)
    }
  }
}
