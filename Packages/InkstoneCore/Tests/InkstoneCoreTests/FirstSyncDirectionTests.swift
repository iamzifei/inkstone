import Foundation
import Testing
@testable import InkstoneCore

/// A first sync has no common ancestor, so "both sides changed" is a conclusion
/// nothing supports. It asks instead.
extension GitHubClientTests {

  @Suite("First sync direction", .serialized)
  struct FirstSyncTests {

    private let remoteText = "the repository's version\n"
    private let localText = "this device's version\n"

    private func engine(at root: URL) -> SyncEngine {
        let blob = Data(remoteText.utf8)
        let sha = gitBlobSHA(blob)
        StubProtocol.handler = { request in
            func reply(_ status: Int, _ body: Data) -> (HTTPURLResponse, Data) {
                (
                    HTTPURLResponse(url: URL(string: "https://api.github.com")!,
                                    statusCode: status, httpVersion: nil, headerFields: [:])!,
                    body
                )
            }
            let path = request.url?.path ?? ""
            if path.contains("git/trees") {
                return reply(200, Data("""
                {"tree":[{"path":"Note.md","type":"blob","sha":"\(sha)","size":\(blob.count)}]}
                """.utf8))
            }
            if path.contains("git/blobs") { return reply(200, blob) }
            if path.contains("/branches") { return reply(200, Data(#"[{"name":"main"}]"#.utf8)) }
            if request.httpMethod == "PUT" {
                return reply(201, Data(#"{"content":{"sha":"1111111111111111111111111111111111111111"}}"#.utf8))
            }
            return reply(200, Data(#"{"full_name":"owner/notes"}"#.utf8))
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return SyncEngine(
            client: GitHubClient(
                configuration: .init(repository: "owner/notes", branch: "main"),
                token: "t",
                session: URLSession(configuration: configuration),
                retry: .immediate
            ),
            vaultRoot: root,
            policy: SyncFilePolicy()
        )
    }

    private func vault() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "inkstone-first-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(localText.utf8).write(to: root.appending(path: "Note.md"))
        return root
    }

    @Test("It refuses rather than guessing")
    func asksInsteadOfConflicting() async throws {
        let root = try vault()
        defer { try? FileManager.default.removeItem(at: root) }
        await #expect(throws: SyncError.self) { _ = try await engine(at: root).run() }
    }

    @Test("Keeping local uploads it and writes no conflict copy")
    func preferLocal() async throws {
        let root = try vault()
        defer { try? FileManager.default.removeItem(at: root) }
        let report = try await engine(at: root).run(firstSyncDirection: .preferLocal)
        #expect(report.uploaded == ["Note.md"])
        #expect(report.conflicted.isEmpty)
        #expect(try String(contentsOf: root.appending(path: "Note.md"), encoding: .utf8) == localText)
        let copies = try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { $0.contains("conflict") }
        #expect(copies.isEmpty)
    }

    @Test("Keeping the repository downloads it over the local file")
    func preferRemote() async throws {
        let root = try vault()
        defer { try? FileManager.default.removeItem(at: root) }
        let report = try await engine(at: root).run(firstSyncDirection: .preferRemote)
        #expect(report.downloaded == ["Note.md"])
        #expect(report.conflicted.isEmpty)
        #expect(try String(contentsOf: root.appending(path: "Note.md"), encoding: .utf8) == remoteText)
    }

    @Test("Keeping both is still available, and is the old behaviour")
    func keepBoth() async throws {
        let root = try vault()
        defer { try? FileManager.default.removeItem(at: root) }
        let report = try await engine(at: root).run(firstSyncDirection: .keepBoth)
        #expect(report.conflicted == ["Note.md"])
        let copies = try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { $0.contains("conflict") }
        #expect(copies.count == 1)
    }

    /// Only the first sync asks. Once there is a base, a difference on both
    /// sides is a real conflict and keeping both is the right answer.
    @Test("A later conflict does not ask again")
    func laterConflictsAreConflicts() async throws {
        let root = try vault()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await engine(at: root).run(firstSyncDirection: .preferLocal)

        // Both sides move on from that base.
        try Data("edited here\n".utf8).write(to: root.appending(path: "Note.md"))
        let report = try await engine(at: root).run()
        #expect(report.conflicted == ["Note.md"], "should conflict, not ask")
    }
  }
}
