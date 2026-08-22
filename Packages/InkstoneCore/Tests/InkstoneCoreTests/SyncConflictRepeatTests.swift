import Foundation
import Testing
@testable import InkstoneCore

/// A conflict must be resolved once, not re-made on every run.
extension GitHubClientTests {

  @Suite("Sync conflict settles", .serialized)
  struct ConflictRepeatTests {

    private func client(remoteContent: String) -> GitHubClient {
        let blob = Data(remoteContent.utf8)
        let sha = gitBlobSHA(blob)
        StubProtocol.handler = { request in
            let path = request.url?.path ?? ""
            func reply(_ status: Int, _ body: Data) -> (HTTPURLResponse, Data) {
                (
                    HTTPURLResponse(url: URL(string: "https://api.github.com")!,
                                    statusCode: status, httpVersion: nil, headerFields: [:])!,
                    body
                )
            }
            if path.contains("git/trees") {
                return reply(200, Data("""
                {"tree":[{"path":"Note.md","type":"blob","sha":"\(sha)","size":\(blob.count)}]}
                """.utf8))
            }
            if path.contains("git/blobs") { return reply(200, blob) }
            if path.contains("/branches") { return reply(200, Data(#"[{"name":"main"}]"#.utf8)) }
            if request.httpMethod == "PUT" {
                return reply(201, Data(#"{"content":{"sha":"0000000000000000000000000000000000000000"}}"#.utf8))
            }
            return reply(200, Data(#"{"full_name":"iamzifei/notes"}"#.utf8))
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return GitHubClient(
            configuration: .init(repository: "iamzifei/notes", branch: "main"),
            token: "test-token",
            session: URLSession(configuration: configuration),
            retry: .immediate
        )
    }

    /// Both sides hold a different `Note.md` and neither has synced before, so
    /// the first run cannot know which is newer and keeps both. The second run
    /// must not reach the same conclusion again: nothing changed in between, and
    /// a vault on a fifteen-minute schedule would otherwise gain a copy of every
    /// conflicted note four times an hour, forever.
    @Test("A conflict is not re-made on the next run")
    func conflictSettles() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "inkstone-conflict-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("local version\n".utf8).write(to: root.appending(path: "Note.md"))

        let engine = SyncEngine(
            client: client(remoteContent: "remote version\n"),
            vaultRoot: root,
            policy: SyncFilePolicy()
        )

        // Explicitly keeping both: a first sync now asks which side wins, and
        // this test is about what happens *after* that answer, not about the
        // question.
        let first = try await engine.run(firstSyncDirection: .keepBoth)
        #expect(first.conflicted == ["Note.md"])

        let second = try await engine.run()
        #expect(second.conflicted.isEmpty, "the same conflict was reported twice")

        let copies = try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { $0.contains("conflict") }
        #expect(copies.count == 1, "one copy per conflict, got \(copies.count): \(copies)")
    }
  }
}
