import Foundation
import Testing
@testable import InkstoneCore

/// The vault's own rules have to reach the vault's other copies.
///
/// `.gitignore` was invisible to sync twice over — hidden, so the directory walk
/// skipped it, and extensionless, so the policy filed it under "other", which is
/// off by default. A second device therefore held the same notes and none of the
/// rules about which of them to carry, and uploaded everything the first device
/// deliberately excluded.
extension GitHubClientTests {

  @Suite("Gitignore syncs", .serialized)
  struct GitIgnoreSyncTests {

    private func emptyRemoteClient() -> GitHubClient {
        StubProtocol.handler = { request in
            let path = request.url?.path ?? ""
            func reply(_ status: Int, _ body: Data) -> (HTTPURLResponse, Data) {
                (
                    HTTPURLResponse(url: URL(string: "https://api.github.com")!,
                                    statusCode: status, httpVersion: nil, headerFields: [:])!,
                    body
                )
            }
            if path.contains("git/trees") { return reply(200, Data(#"{"tree":[]}"#.utf8)) }
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

    @Test("The policy carries .gitignore even when every other file type is off")
    func policyAlwaysCarriesIt() {
        // The strictest policy anyone can set: no images, no audio, no PDFs, no
        // video, no other files. `.gitignore` still goes.
        var policy = SyncFilePolicy()
        policy.setSyncs(.image, false)
        policy.setSyncs(.audio, false)
        policy.setSyncs(.pdf, false)
        policy.setSyncs(.video, false)
        policy.setSyncs(.other, false)

        #expect(policy.allows(URL(fileURLWithPath: "/vault/.gitignore")))
        // And the reason it needed a special case: it is filed as "other".
        #expect(policy.allows(URL(fileURLWithPath: "/vault/notes.other")) == false)
    }

    @Test("A vault's .gitignore is uploaded, hidden though it is")
    func hiddenFileStillTravels() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "inkstone-ignore-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try Data("Recordings/\n**/_chunks/**/*.ogg\n".utf8)
            .write(to: root.appending(path: ".gitignore"))
        try Data("hello\n".utf8).write(to: root.appending(path: "Note.md"))

        let engine = SyncEngine(
            client: emptyRemoteClient(), vaultRoot: root, policy: SyncFilePolicy()
        )
        let report = try await engine.run()

        #expect(report.uploaded.contains(".gitignore"))
        #expect(report.uploaded.contains("Note.md"))
    }

    @Test("A vault that ignores its own .gitignore keeps it to itself")
    func selfIgnoredIsRespected() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "inkstone-ignore-self-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // Saying so in the file itself is the only way to say it, and it is a
        // deliberate statement rather than an oversight — so it wins.
        try Data(".gitignore\n".utf8).write(to: root.appending(path: ".gitignore"))
        try Data("hello\n".utf8).write(to: root.appending(path: "Note.md"))

        let engine = SyncEngine(
            client: emptyRemoteClient(), vaultRoot: root, policy: SyncFilePolicy()
        )
        let report = try await engine.run()

        #expect(!report.uploaded.contains(".gitignore"))
        #expect(report.uploaded.contains("Note.md"))
    }
  }
}
