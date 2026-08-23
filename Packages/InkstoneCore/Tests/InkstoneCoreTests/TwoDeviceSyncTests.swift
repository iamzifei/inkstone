import Foundation
import Testing
@testable import InkstoneCore

/// Two devices, one repository — the arrangement everything in this week went
/// wrong in.
///
/// Every other sync test drives one vault against a fixed stub. That cannot see
/// the failures that matter, because those need a *second* vault reading back
/// what the first one wrote. So this fake remote actually stores what is
/// uploaded, and the two vaults are two directories.
extension GitHubClientTests {

  @Suite("Two devices, one repository", .serialized)
  struct TwoDeviceSyncTests {

    /// An in-memory GitHub: a path→bytes map, served through the same four
    /// endpoints `GitHubClient` calls. Faithful where it matters — the tree
    /// listing reports git blob SHAs, and a blob is fetched by SHA rather than
    /// by path, which is what the engine relies on.
    final class FakeRemote: @unchecked Sendable {
        private let lock = NSLock()
        private var files: [String: Data] = [:]

        var paths: [String] { lock.withLock { files.keys.sorted() } }

        /// The request body, whichever way URLSession chose to carry it.
        ///
        /// `httpBody` is **nil inside a URLProtocol**: URLSession converts it to
        /// a stream before the protocol sees the request. Reading only
        /// `httpBody` made every upload store zero bytes, so the listing showed
        /// the right filenames and every download produced an empty note —
        /// which is a far more confusing failure than an outright error.
        static func body(of request: URLRequest) -> Data {
            if let body = request.httpBody { return body }
            guard let stream = request.httpBodyStream else { return Data() }
            stream.open()
            defer { stream.close() }
            var data = Data()
            let size = 64 * 1024
            var buffer = [UInt8](repeating: 0, count: size)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: size)
                if read <= 0 { break }
                data.append(buffer, count: read)
            }
            return data
        }

        func handle(_ request: URLRequest) -> (HTTPURLResponse, Data) {
            let path = request.url?.path ?? ""
            func reply(_ status: Int, _ body: Data) -> (HTTPURLResponse, Data) {
                (
                    HTTPURLResponse(url: request.url!, statusCode: status,
                                    httpVersion: nil, headerFields: [:])!,
                    body
                )
            }

            if path.contains("git/trees") {
                let entries = lock.withLock {
                    files.map { key, value in
                        let escaped = key.replacingOccurrences(of: "\"", with: "\\\"")
                        return #"{"path":"\#(escaped)","type":"blob","sha":"\#(gitBlobSHA(value))","size":\#(value.count)}"#
                    }.joined(separator: ",")
                }
                return reply(200, Data(#"{"tree":[\#(entries)]}"#.utf8))
            }

            if path.contains("git/blobs") {
                let sha = String(path.split(separator: "/").last ?? "")
                let match = lock.withLock { files.values.first { gitBlobSHA($0) == sha } }
                guard let match else { return reply(404, Data(#"{"message":"Not Found"}"#.utf8)) }
                return reply(200, match)
            }

            if path.contains("/contents/") {
                // Everything after `/contents/` is the vault-relative path, and
                // it arrives percent-encoded.
                let raw = String(path[path.range(of: "/contents/")!.upperBound...])
                let filePath = raw.removingPercentEncoding ?? raw
                let body = (try? JSONSerialization.jsonObject(with: Self.body(of: request)))
                    as? [String: Any] ?? [:]

                if request.httpMethod == "DELETE" {
                    lock.withLock { _ = files.removeValue(forKey: filePath) }
                    return reply(200, Data(#"{"commit":{"sha":"deadbeef"}}"#.utf8))
                }

                let content = (body["content"] as? String).flatMap { Data(base64Encoded: $0) } ?? Data()
                lock.withLock { files[filePath] = content }
                return reply(201, Data(#"{"content":{"sha":"\#(gitBlobSHA(content))"}}"#.utf8))
            }

            if path.contains("/branches") { return reply(200, Data(#"[{"name":"main"}]"#.utf8)) }
            return reply(200, Data(#"{"full_name":"owner/notes"}"#.utf8))
        }
    }

    private func client(_ remote: FakeRemote) -> GitHubClient {
        StubProtocol.handler = { request in remote.handle(request) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return GitHubClient(
            configuration: .init(repository: "owner/notes", branch: "main"),
            token: "test-token",
            session: URLSession(configuration: configuration),
            retry: .immediate
        )
    }

    private func makeVault(_ label: String) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "inkstone-\(label)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ text: String, _ name: String, in vault: URL) throws {
        try Data(text.utf8).write(to: vault.appending(path: name))
    }

    private func read(_ name: String, in vault: URL) -> String? {
        try? String(contentsOf: vault.appending(path: name), encoding: .utf8)
    }

    private func engine(_ vault: URL, _ remote: FakeRemote) -> SyncEngine {
        SyncEngine(client: client(remote), vaultRoot: vault, policy: SyncFilePolicy())
    }

    // MARK: - The ordinary case

    @Test("Alternating between two devices never conflicts")
    func alternatingIsClean() async throws {
        let remote = FakeRemote()
        let mac = try makeVault("mac"), phone = try makeVault("phone")
        defer {
            try? FileManager.default.removeItem(at: mac)
            try? FileManager.default.removeItem(at: phone)
        }

        try write("first\n", "Note.md", in: mac)
        _ = try await engine(mac, remote).run()

        // The phone starts empty, as the guide insists it must.
        let firstPull = try await engine(phone, remote).run()
        #expect(firstPull.downloaded == ["Note.md"])
        #expect(read("Note.md", in: phone) == "first\n")

        // Phone edits, syncs. Then the Mac syncs and takes it.
        try write("second\n", "Note.md", in: phone)
        _ = try await engine(phone, remote).run()
        let back = try await engine(mac, remote).run()

        #expect(back.downloaded == ["Note.md"])
        #expect(read("Note.md", in: mac) == "second\n")
        #expect(back.conflicted.isEmpty)
    }

    @Test("Editing different notes on two devices never conflicts")
    func differentFilesNeverConflict() async throws {
        let remote = FakeRemote()
        let mac = try makeVault("mac"), phone = try makeVault("phone")
        defer {
            try? FileManager.default.removeItem(at: mac)
            try? FileManager.default.removeItem(at: phone)
        }

        try write("a\n", "A.md", in: mac)
        try write("b\n", "B.md", in: mac)
        _ = try await engine(mac, remote).run()
        _ = try await engine(phone, remote).run()

        // Both move, at the same time, on different notes.
        try write("a2\n", "A.md", in: mac)
        try write("b2\n", "B.md", in: phone)
        _ = try await engine(phone, remote).run()
        let macRun = try await engine(mac, remote).run()

        #expect(macRun.conflicted.isEmpty)
        #expect(read("A.md", in: mac) == "a2\n")
        #expect(read("B.md", in: mac) == "b2\n")
    }

    // MARK: - The one case that does conflict

    @Test("The same note edited on both devices keeps both copies")
    func sameFileConflictsAndKeepsBoth() async throws {
        let remote = FakeRemote()
        let mac = try makeVault("mac"), phone = try makeVault("phone")
        defer {
            try? FileManager.default.removeItem(at: mac)
            try? FileManager.default.removeItem(at: phone)
        }

        try write("base\n", "Note.md", in: mac)
        _ = try await engine(mac, remote).run()
        _ = try await engine(phone, remote).run()

        // Both edit the same note before either syncs.
        try write("from the phone\n", "Note.md", in: phone)
        try write("from the mac\n", "Note.md", in: mac)
        _ = try await engine(phone, remote).run()
        let macRun = try await engine(mac, remote).run()

        #expect(macRun.conflicted == ["Note.md"])

        // Nothing is overwritten. The local edit stands and the other side is
        // saved beside it.
        #expect(read("Note.md", in: mac) == "from the mac\n")
        let copies = try FileManager.default
            .contentsOfDirectory(atPath: mac.path)
            .filter { $0.contains("(conflict ") }
        #expect(copies.count == 1)
        let copy = try #require(copies.first)
        #expect(read(copy, in: mac) == "from the phone\n")

        // And it settles: the next run must not make a second copy.
        let again = try await engine(mac, remote).run()
        #expect(again.conflicted.isEmpty)
        let stillOne = try FileManager.default
            .contentsOfDirectory(atPath: mac.path)
            .filter { $0.contains("(conflict ") }
        #expect(stillOne.count == 1)
    }

    // MARK: - The two incidents, as regressions

    /// A rename is a delete plus an add. The device that has not seen it still
    /// holds the old name, and with no recorded base it reads as a local
    /// addition — so it uploads it and the old file comes back. This is the
    /// resurrection that was reported, and the fix is that the base *is*
    /// recorded, so the second device sees a remote deletion instead.
    @Test("A note renamed on one device does not come back from the other")
    func renameDoesNotResurrect() async throws {
        let remote = FakeRemote()
        let mac = try makeVault("mac"), phone = try makeVault("phone")
        defer {
            try? FileManager.default.removeItem(at: mac)
            try? FileManager.default.removeItem(at: phone)
        }

        try write("rules\n", "Old Name.md", in: mac)
        _ = try await engine(mac, remote).run()
        _ = try await engine(phone, remote).run()
        #expect(read("Old Name.md", in: phone) == "rules\n")

        // Renamed on the Mac.
        try FileManager.default.moveItem(
            at: mac.appending(path: "Old Name.md"),
            to: mac.appending(path: "New Name.md")
        )
        _ = try await engine(mac, remote).run()
        #expect(remote.paths == ["New Name.md"])

        // The phone catches up. It must delete its copy of the old name, not
        // upload it back.
        _ = try await engine(phone, remote).run()
        #expect(remote.paths == ["New Name.md"])
        #expect(read("Old Name.md", in: phone) == nil)
        #expect(read("New Name.md", in: phone) == "rules\n")

        // And the Mac must not see the old name return on its next run.
        _ = try await engine(mac, remote).run()
        #expect(read("Old Name.md", in: mac) == nil)
    }

    /// What deleted a directory of sample content out of a repository: a vault
    /// that did not contain those files, syncing to a repository that did. With
    /// no recorded state the planner reads every remote file as an addition and
    /// downloads it — the safe direction. The unsafe direction needs a *recorded*
    /// base saying this vault once had them, which only a vault that really did
    /// have them can produce.
    @Test("An unrelated empty vault downloads a repository rather than emptying it")
    func strangeVaultDoesNotDeleteTheRepository() async throws {
        let remote = FakeRemote()
        let mac = try makeVault("mac"), stranger = try makeVault("stranger")
        defer {
            try? FileManager.default.removeItem(at: mac)
            try? FileManager.default.removeItem(at: stranger)
        }

        try write("one\n", "One.md", in: mac)
        try write("two\n", "Two.md", in: mac)
        _ = try await engine(mac, remote).run()
        #expect(remote.paths == ["One.md", "Two.md"])

        let run = try await engine(stranger, remote).run()
        #expect(run.deletedRemotely.isEmpty)
        #expect(remote.paths == ["One.md", "Two.md"])
        #expect(run.downloaded.sorted() == ["One.md", "Two.md"])
    }

    /// `.gitignore` is hidden and extensionless, so it was invisible to the walk
    /// and to the policy. A second device therefore had the notes and none of
    /// the rules, and uploaded what the first one excluded.
    @Test("The second device inherits the first device's ignore rules")
    func ignoreRulesTravel() async throws {
        let remote = FakeRemote()
        let mac = try makeVault("mac"), phone = try makeVault("phone")
        defer {
            try? FileManager.default.removeItem(at: mac)
            try? FileManager.default.removeItem(at: phone)
        }

        try write("Recordings/\n", ".gitignore", in: mac)
        try write("note\n", "Note.md", in: mac)
        try FileManager.default.createDirectory(
            at: mac.appending(path: "Recordings"), withIntermediateDirectories: true)
        try write("secret\n", "Recordings/Take.md", in: mac)

        _ = try await engine(mac, remote).run()
        #expect(remote.paths.contains(".gitignore"))
        #expect(!remote.paths.contains("Recordings/Take.md"))

        _ = try await engine(phone, remote).run()
        #expect(read(".gitignore", in: phone) == "Recordings/\n")

        // The phone now has the rule, so a file it creates under that folder
        // stays on the phone instead of going up.
        try FileManager.default.createDirectory(
            at: phone.appending(path: "Recordings"), withIntermediateDirectories: true)
        try write("phone take\n", "Recordings/Phone.md", in: phone)
        _ = try await engine(phone, remote).run()
        #expect(!remote.paths.contains("Recordings/Phone.md"))
    }
  }
}
