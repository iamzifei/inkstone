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

        // Everything after the upload runs where a failure can still remove the
        // probe. GitHub returned a 503 mid-test once and the file stayed in the
        // repository — a test that writes to someone's repo has to clean up after
        // itself on the path where it goes wrong, which is the only path where it
        // matters. `defer` cannot be used: the cleanup is async.
        do {
            let listed = try await client.listFiles()
            #expect(listed.contains { $0.path == path })

            let fetched = try await client.download(sha: sha, path: path)
            #expect(fetched == body)

            try await client.delete(path: path, sha: sha, message: "Remove Inkstone sync probe")
            let after = try await client.listFiles()
            #expect(!after.contains { $0.path == path })
        } catch {
            try? await client.delete(path: path, sha: sha, message: "Remove Inkstone sync probe")
            throw error
        }
    }

    /// Pulls a whole repository into an empty vault against the live API.
    ///
    /// Nested inside `GitHub integration` so that `.serialized` covers both: as
    /// separate top-level suites they ran concurrently against the same repository,
    /// and the round-trip test's uploads and deletes showed up as unexpected changes
    /// here. That only surfaced once the URL cache was disabled — a stale listing
    /// had been hiding the interference.
    ///
    /// Separate from the round-trip test because downloading needs only Contents:
    /// **read**. That covers half of sync — listing, diffing, fetching, writing to
    /// disk and recording state — without any write access to the repository.
    ///
    ///     INKSTONE_GITHUB_TOKEN=<pat> INKSTONE_TEST_REPO=owner/repo \
    ///     INKSTONE_TEST_PULL=1 swift test --filter GitHubPullTests
    @Suite("GitHub pull", .serialized)
    struct GitHubPullTests {
    
        private static var enabled: Bool {
            ProcessInfo.processInfo.environment["INKSTONE_TEST_PULL"] == "1"
                && ProcessInfo.processInfo.environment["INKSTONE_GITHUB_TOKEN"] != nil
                && ProcessInfo.processInfo.environment["INKSTONE_TEST_REPO"] != nil
        }
    
        @Test("An empty vault pulls the repository down", .enabled(if: enabled))
        func pullIntoEmptyVault() async throws {
            let environment = ProcessInfo.processInfo.environment
            let client = GitHubClient(
                configuration: .init(repository: environment["INKSTONE_TEST_REPO"]!, branch: "main"),
                token: environment["INKSTONE_GITHUB_TOKEN"]!
            )
    
            let root = URL(fileURLWithPath: NSTemporaryDirectory())
                .appending(path: "inkstone-pull-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
    
            // Only notes, so a code repository does not drag its binaries down.
            var policy = SyncFilePolicy()
            for kind in AttachmentKind.allCases { policy.setSyncs(kind, false) }
    
            let engine = SyncEngine(client: client, vaultRoot: root, policy: policy)
            let report = try await engine.run()
    
            #expect(!report.downloaded.isEmpty, "an empty vault should receive files")
            #expect(report.uploaded.isEmpty, "nothing to upload from an empty vault")
            #expect(report.conflicted.isEmpty)
            #expect(report.failures.isEmpty, "failures: \(report.failures.map(\.message))")
    
            // Every downloaded file must actually be on disk, with the content whose
            // hash the remote reported — that equivalence is what sync rests on.
            let remote = Dictionary(uniqueKeysWithValues: try await client.listFiles().map { ($0.path, $0.sha) })
            for path in report.downloaded.prefix(20) {
                let url = root.appending(path: path)
                let data = try #require(try? Data(contentsOf: url), "missing on disk: \(path)")
                #expect(gitBlobSHA(data) == remote[path], "content mismatch for \(path)")
            }
    
            // And the run must have recorded a base state for the next comparison.
            let state = SyncState.load(from: root)
            #expect(state.blobs.count == report.downloaded.count)
            #expect(state.lastSyncedAt != nil)
        }
    
        @Test("A second run finds nothing to do", .enabled(if: enabled))
        func secondRunIsQuiet() async throws {
            // The point of recording state: syncing twice must not re-download
            // everything, or every sync would rewrite the whole vault.
            let environment = ProcessInfo.processInfo.environment
            let client = GitHubClient(
                configuration: .init(repository: environment["INKSTONE_TEST_REPO"]!, branch: "main"),
                token: environment["INKSTONE_GITHUB_TOKEN"]!
            )
            let root = URL(fileURLWithPath: NSTemporaryDirectory())
                .appending(path: "inkstone-pull2-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
    
            var policy = SyncFilePolicy()
            for kind in AttachmentKind.allCases { policy.setSyncs(kind, false) }
            let engine = SyncEngine(client: client, vaultRoot: root, policy: policy)
    
            let first = try await engine.run()
            #expect(!first.downloaded.isEmpty)
    
            let second = try await engine.run()
            #expect(
                second.changeCount == 0,
                "a settled vault must be quiet, got: \(second.changeSummary)"
            )
        }
    }
}
