import Foundation
import Testing
@testable import InkstoneCore

/// Every way the 2026-11-18 sync audit found for sync to lose or resurrect
/// notes, each reproduced against the in-memory GitHub of the two-device suite.
/// Each test failed before its fix.
extension GitHubClientTests {

  @Suite("Sync data-loss cases", .serialized)
  struct SyncDataLossTests {
    typealias Remote = TwoDeviceSyncTests.FakeRemote

    func vault(_ label: String) throws -> URL {
        // The canonical path (/private/var, not /var), as a real vault's
        // enumerator reports it — so relative paths are computed directly.
        let raw = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "inkstone-\(label)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
        let path = raw.path.hasPrefix("/var/") ? "/private" + raw.path : raw.path
        return URL(fileURLWithPath: path, isDirectory: true)
    }
    func write(_ text: String, _ name: String, in vault: URL) throws {
        let url = vault.appending(path: name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }
    func exists(_ name: String, in vault: URL) -> Bool {
        // Exact-case check: on a case-insensitive volume `fileExists` would say
        // yes for any spelling.
        let url = vault.appending(path: name)
        let listing = (try? FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)) ?? []
        return listing.contains(url.lastPathComponent)
    }
    func engine(_ vault: URL, _ remote: Remote) -> SyncEngine {
        SyncEngine(client: TwoDeviceSyncTests.client(remote), vaultRoot: vault, policy: SyncFilePolicy())
    }

    @Test("A file already identical on both sides gets a base, so deleting it later propagates")
    func identicalFilesRecordABase() async throws {
        let remote = Remote()
        remote.put("n.md", "same\n")
        let phone = try vault("phone"); defer { try? FileManager.default.removeItem(at: phone) }
        try write("same\n", "n.md", in: phone)
        _ = try await engine(phone, remote).run()
        try FileManager.default.removeItem(at: phone.appending(path: "n.md"))
        let second = try await engine(phone, remote).run()
        #expect(second.deletedRemotely == ["n.md"])
        #expect(!exists("n.md", in: phone))
    }

    @Test("A case-only rename on one device does not delete the note on the other")
    func caseOnlyRenameSurvives() async throws {
        let remote = Remote()
        let mac = try vault("mac"), phone = try vault("phone")
        defer { try? FileManager.default.removeItem(at: mac); try? FileManager.default.removeItem(at: phone) }
        try write("text\n", "note.md", in: mac)
        _ = try await engine(mac, remote).run()
        _ = try await engine(phone, remote).run()

        try FileManager.default.moveItem(at: mac.appending(path: "note.md"), to: mac.appending(path: "Note.md"))
        _ = try await engine(mac, remote).run()
        #expect(remote.paths == ["Note.md"])

        _ = try await engine(phone, remote).run()
        // Exactly the new spelling, and only it (the APFS test volume is
        // case-insensitive, the default on Macs and iPhones).
        #expect(exists("Note.md", in: phone), "the note vanished from the phone or kept its old name")
        #expect(!exists("note.md", in: phone))
        _ = try await engine(phone, remote).run()
        #expect(remote.contents("Note.md") == "text\n", "the note was deleted from GitHub")
    }

    @Test("Hidden paths on the remote are left alone, not downloaded and then deleted")
    func hiddenRemotePathsAreIgnored() async throws {
        let remote = Remote()
        remote.put(".github/pull_request_template.md", "template\n")
        remote.put("a.md", "a\n")
        let phone = try vault("phone"); defer { try? FileManager.default.removeItem(at: phone) }
        _ = try await engine(phone, remote).run()
        _ = try await engine(phone, remote).run()
        #expect(remote.contents(".github/pull_request_template.md") == "template\n")
        #expect(!FileManager.default.fileExists(atPath: phone.appending(path: ".github").path))
    }

    @Test("A file that cannot be read is not treated as deleted")
    func unreadableFileIsNotADeletion() async throws {
        let remote = Remote()
        let mac = try vault("mac"); defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: mac.appending(path: "locked.md").path)
            try? FileManager.default.removeItem(at: mac)
        }
        try write("secret\n", "locked.md", in: mac)
        _ = try await engine(mac, remote).run()
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: mac.appending(path: "locked.md").path)
        let report = try await engine(mac, remote).run()
        #expect(report.deletedRemotely.isEmpty)
        #expect(remote.contents("locked.md") == "secret\n")
    }

    @Test("A truncated tree listing stops the run before anything is deleted")
    func truncatedListingStops() async throws {
        let remote = Remote()
        let mac = try vault("mac"); defer { try? FileManager.default.removeItem(at: mac) }
        try write("a\n", "a.md", in: mac)
        _ = try await engine(mac, remote).run()
        remote.truncated = true
        await #expect {
            _ = try await engine(mac, remote).run()
        } throws: { error in
            if case GitHubError.listingTruncated = error { return true } else { return false }
        }
        #expect(exists("a.md", in: mac))
    }

    @Test("Remote paths that differ only in Unicode normalisation do not crash the run")
    func normalisationDuplicatesDoNotCrash() async throws {
        // Hand-written listing: the fake remote keys files by Swift `String`,
        // which already merges the two spellings, so it cannot hold both.
        let nfc = "caf\u{E9}.md", nfd = "cafe\u{301}.md"
        let blob = Data("x\n".utf8), sha = gitBlobSHA(blob)
        GitHubClientTests.StubProtocol.handler = { request in
            let path = request.url?.path ?? ""
            let body: Data
            if path.contains("git/trees") {
                body = Data(#"{"tree":[{"path":"\#(nfc)","type":"blob","sha":"\#(sha)","size":2},{"path":"\#(nfd)","type":"blob","sha":"\#(sha)","size":2}],"truncated":false}"#.utf8)
            } else if path.contains("git/blobs") {
                body = blob
            } else if path.contains("/branches") {
                body = Data(#"[{"name":"main"}]"#.utf8)
            } else {
                body = Data(#"{"full_name":"owner/notes"}"#.utf8)
            }
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: [:])!, body)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GitHubClientTests.StubProtocol.self]
        let client = GitHubClient(configuration: .init(repository: "owner/notes", branch: "main"),
                                  token: "t", session: URLSession(configuration: configuration), retry: .immediate)
        let phone = try vault("phone"); defer { try? FileManager.default.removeItem(at: phone) }
        let report = try await SyncEngine(client: client, vaultRoot: phone, policy: SyncFilePolicy()).run()
        #expect(report.downloaded.count == 1)
    }

    @Test("A local edit against a remote delete keeps the edit, once")
    func editVersusDeleteSettles() async throws {
        let remote = Remote()
        let mac = try vault("mac"), phone = try vault("phone")
        defer { try? FileManager.default.removeItem(at: mac); try? FileManager.default.removeItem(at: phone) }
        try write("v1\n", "n.md", in: mac)
        try write("other\n", "keep.md", in: mac)   // so the remote is not emptied
        _ = try await engine(mac, remote).run()
        _ = try await engine(phone, remote).run()
        try FileManager.default.removeItem(at: phone.appending(path: "n.md"))
        _ = try await engine(phone, remote).run()           // deletes on GitHub
        try write("v2 edited\n", "n.md", in: mac)
        _ = try await engine(mac, remote).run()
        #expect(remote.contents("n.md") == "v2 edited\n")
        let again = try await engine(mac, remote).run()
        #expect(again.conflicted.isEmpty)
    }

    @Test("Emptying the repository can be confirmed instead of wedging every device")
    func emptiedRemoteCanBeConfirmed() async throws {
        let remote = Remote()
        let mac = try vault("mac"); defer { try? FileManager.default.removeItem(at: mac) }
        try write("a\n", "a.md", in: mac)
        _ = try await engine(mac, remote).run()
        // Another device deleted the last file.
        let other = try vault("other"); defer { try? FileManager.default.removeItem(at: other) }
        _ = try await engine(other, remote).run()
        try FileManager.default.removeItem(at: other.appending(path: "a.md"))
        _ = try await engine(other, remote).run(confirmingLargeDeletion: true)
        #expect(remote.paths.isEmpty)
        await #expect {
            _ = try await engine(mac, remote).run()
        } throws: { error in
            if case SyncError.remoteUnexpectedlyEmpty = error { return true } else { return false }
        }
        let confirmed = try await engine(mac, remote).run(confirmingLargeDeletion: true)
        #expect(confirmed.deletedLocally == ["a.md"])
    }

    @Test("Bad credentials mid-run fail the run instead of reporting success")
    func unauthorisedMidRunFails() async throws {
        let remote = Remote()
        let mac = try vault("mac"); defer { try? FileManager.default.removeItem(at: mac) }
        try write("a\n", "a.md", in: mac)
        _ = try await engine(mac, remote).run()
        let synced = SyncState.load(from: mac).lastSyncedAt
        for i in 0..<5 { try write("\(i)\n", "new\(i).md", in: mac) }
        remote.failWritesWith = 401
        await #expect {
            _ = try await engine(mac, remote).run()
        } throws: { error in
            if case GitHubError.unauthorised = error { return true } else { return false }
        }
        #expect(SyncState.load(from: mac).lastSyncedAt == synced, "a failed run stamped itself as synced")
    }

    @Test("Typing during a sync is never overwritten by a download")
    func editDuringRunIsKept() async throws {
        let remote = Remote()
        let mac = try vault("mac"), phone = try vault("phone")
        defer { try? FileManager.default.removeItem(at: mac); try? FileManager.default.removeItem(at: phone) }
        try write("v1\n", "n.md", in: mac)
        _ = try await engine(mac, remote).run()
        _ = try await engine(phone, remote).run()
        try write("from mac\n", "n.md", in: mac)
        _ = try await engine(mac, remote).run()
        // The phone's autosave lands after its scan, just before the download.
        let note = phone.appending(path: "n.md")
        let report = try await engine(phone, remote).run(progress: { progress in
            if progress.message.contains("n.md") { try? Data("typed on phone\n".utf8).write(to: note) }
        })
        #expect(try String(contentsOf: note, encoding: .utf8) == "typed on phone\n")
        #expect(report.conflicted == ["n.md"])
    }

    @Test("A note iCloud evicted to a placeholder is not deleted from GitHub")
    func iCloudPlaceholderIsNotADeletion() async throws {
        let remote = Remote()
        let phone = try vault("phone"); defer { try? FileManager.default.removeItem(at: phone) }
        try write("keep\n", "n.md", in: phone)
        try write("other\n", "o.md", in: phone)
        _ = try await engine(phone, remote).run()
        // What iOS leaves when it evicts a file: the file goes, a hidden stub stays.
        try FileManager.default.removeItem(at: phone.appending(path: "n.md"))
        try write("stub", ".n.md.icloud", in: phone)
        let report = try await engine(phone, remote).run()
        #expect(report.deletedRemotely.isEmpty)
        #expect(remote.contents("n.md") == "keep\n")
    }

    @Test("A note edited during the run is not deleted for a remote deletion")
    func editDuringRunBlocksLocalDelete() async throws {
        let remote = Remote()
        let mac = try vault("mac"), phone = try vault("phone")
        defer { try? FileManager.default.removeItem(at: mac); try? FileManager.default.removeItem(at: phone) }
        try write("v1\n", "n.md", in: mac)
        try write("other\n", "keep.md", in: mac)
        _ = try await engine(mac, remote).run()
        _ = try await engine(phone, remote).run()
        try FileManager.default.removeItem(at: mac.appending(path: "n.md"))
        _ = try await engine(mac, remote).run()                 // deleted on GitHub
        let note = phone.appending(path: "n.md")
        let report = try await engine(phone, remote).run(progress: { progress in
            if progress.message.contains("n.md") { try? Data("typed\n".utf8).write(to: note) }
        })
        #expect(try String(contentsOf: note, encoding: .utf8) == "typed\n")
        #expect(report.deletedLocally.isEmpty)
    }

    @Test("Renamed by case on one device while edited on the other: the edit survives")
    func caseRenameVersusEditKeepsTheEdit() async throws {
        let remote = Remote()
        let mac = try vault("mac"), phone = try vault("phone")
        defer { try? FileManager.default.removeItem(at: mac); try? FileManager.default.removeItem(at: phone) }
        try write("v1\n", "note.md", in: mac)
        try write("other\n", "keep.md", in: mac)
        _ = try await engine(mac, remote).run()
        _ = try await engine(phone, remote).run()
        try FileManager.default.moveItem(at: mac.appending(path: "note.md"), to: mac.appending(path: "Note.md"))
        _ = try await engine(mac, remote).run()
        try write("edited on phone\n", "note.md", in: phone)
        _ = try await engine(phone, remote).run()
        // The phone's edit must still exist somewhere, on the phone and on GitHub.
        let phoneTexts = try FileManager.default.contentsOfDirectory(atPath: phone.path)
            .filter { $0.hasSuffix(".md") }
            .compactMap { try? String(contentsOf: phone.appending(path: $0), encoding: .utf8) }
        #expect(phoneTexts.contains("edited on phone\n"))
        #expect(remote.paths.compactMap { remote.contents($0) }.contains("edited on phone\n"))
    }

    @Test("A remote with only hidden files reads as empty, not as every note deleted")
    func hiddenOnlyRemoteIsEmpty() async throws {
        let remote = Remote()
        let mac = try vault("mac"); defer { try? FileManager.default.removeItem(at: mac) }
        try write("a\n", "a.md", in: mac)
        _ = try await engine(mac, remote).run()
        // Someone empties the notes but leaves the repository's own files.
        let paths = remote.paths
        let other = try vault("other"); defer { try? FileManager.default.removeItem(at: other) }
        _ = try await engine(other, remote).run()
        for path in paths { try FileManager.default.removeItem(at: other.appending(path: path)) }
        _ = try await engine(other, remote).run(confirmingLargeDeletion: true)
        remote.put(".github/workflows/ci.yml", "on: push\n")
        await #expect {
            _ = try await engine(mac, remote).run()
        } throws: { error in
            if case SyncError.remoteUnexpectedlyEmpty = error { return true } else { return false }
        }
        #expect(FileManager.default.fileExists(atPath: mac.appending(path: "a.md").path))
    }

    @Test("Conflict copy names use Western digits whatever the locale")
    func conflictStampIsPOSIX() {
        #expect(SyncEngine.conflictTimestamp(Date(timeIntervalSince1970: 0)).allSatisfy { $0.isASCII })
    }
  }
}
