import Testing
import Foundation
@testable import InkstoneCore

/// Talks to the real GitHub API.
///
/// Skipped unless both environment variables are set, so ordinary test runs stay
/// offline and deterministic:
///
///     INKSTONE_GITHUB_TOKEN=<pat> \
///     INKSTONE_TEST_REPO=owner/repo \
///     swift test --filter "GitHub integration"
///
/// The read-only cases need a token with Contents: **read**. The round-trip case
/// additionally needs Contents: **write**, and is skipped without
/// INKSTONE_TEST_WRITE=1 so that pointing this at a repository can never write to
/// it by accident.
@Suite("GitHub integration", .serialized)
struct GitHubIntegrationTests {

    private static var token: String? {
        ProcessInfo.processInfo.environment["INKSTONE_GITHUB_TOKEN"]
    }
    private static var repository: String? {
        ProcessInfo.processInfo.environment["INKSTONE_TEST_REPO"]
    }
    private static var writeEnabled: Bool {
        ProcessInfo.processInfo.environment["INKSTONE_TEST_WRITE"] == "1"
    }
    private static var configured: Bool { token != nil && repository != nil }

    private func client(branch: String = "main") throws -> GitHubClient {
        let token = try #require(Self.token)
        let repository = try #require(Self.repository)
        return GitHubClient(configuration: .init(repository: repository, branch: branch), token: token)
    }

    @Test("Verifies the repository over the real API", .enabled(if: configured))
    func verify() async throws {
        let name = try await client().verify()
        #expect(name.lowercased() == (Self.repository ?? "").lowercased())
    }

    @Test("Lists the real file tree in one request", .enabled(if: configured))
    func listFiles() async throws {
        let files = try await client().listFiles()
        #expect(!files.isEmpty)
        // Every entry must carry a usable blob SHA, since that is the identity
        // the whole sync comparison rests on.
        #expect(files.allSatisfy { $0.sha.count == 40 })
        #expect(files.allSatisfy { !$0.path.hasSuffix("/") })
    }

    @Test("A downloaded file hashes to the SHA the API reported", .enabled(if: configured))
    func downloadedContentMatchesItsHash() async throws {
        // The single most important property of the design: the SHA GitHub
        // reports for a blob is the SHA we compute locally for the same bytes.
        // If this ever diverges, sync decides every file changed on every run.
        let client = try client()
        let files = try await client.listFiles()
        let target = try #require(files.filter { $0.size > 0 && $0.size < 200_000 }.first)

        let data = try await client.download(sha: target.sha, path: target.path)
        #expect(gitBlobSHA(data) == target.sha)
    }

    @Test("A bad token is reported as an authorisation failure", .enabled(if: configured))
    func badToken() async throws {
        let repository = try #require(Self.repository)
        let client = GitHubClient(
            configuration: .init(repository: repository, branch: "main"),
            token: "ghp_definitely_not_a_real_token"
        )
        await #expect(throws: GitHubError.self) { try await client.verify() }
    }

    @Test(
        "Full round trip: upload, read back, delete",
        .enabled(if: configured && writeEnabled)
    )
    func roundTrip() async throws {
        let client = try client(branch: ProcessInfo.processInfo.environment["INKSTONE_TEST_BRANCH"] ?? "main")
        let path = "inkstone-sync-probe/\(UUID().uuidString).md"
        let body = Data("# Probe\n\n中英 mixed content\n".utf8)

        let sha = try await client.upload(path: path, contents: body, sha: nil, message: "Inkstone sync probe")
        #expect(sha == gitBlobSHA(body))

        let listed = try await client.listFiles()
        #expect(listed.contains { $0.path == path })

        let fetched = try await client.download(sha: sha, path: path)
        #expect(fetched == body)

        try await client.delete(path: path, sha: sha, message: "Remove Inkstone sync probe")
        let after = try await client.listFiles()
        #expect(!after.contains { $0.path == path })
    }
}
