import Foundation
import Testing
@testable import InkstoneCore

/// A missing branch used to look exactly like an empty repository, and the two
/// lead opposite ways.
extension GitHubClientTests {

  @Suite("Sync branch safety", .serialized)
  struct BranchSafetyTests {

    private func makeClient(
        branch: String = "main",
        respond: @escaping @Sendable (URLRequest) -> (HTTPURLResponse, Data)
    ) -> GitHubClient {
        StubProtocol.handler = respond
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return GitHubClient(
            configuration: .init(repository: "owner/notes", branch: branch),
            token: "test-token",
            session: URLSession(configuration: configuration),
            retry: .immediate
        )
    }

    private func reply(_ status: Int, _ json: String) -> (HTTPURLResponse, Data) {
        (
            HTTPURLResponse(url: URL(string: "https://api.github.com")!,
                            statusCode: status, httpVersion: nil, headerFields: [:])!,
            Data(json.utf8)
        )
    }

    /// The regression, and the reason it mattered: reported as an empty remote,
    /// a mistyped branch tells the planner every synced file was deleted.
    @Test("A missing branch is an error, not an empty repository")
    func missingBranchIsNotEmpty() async throws {
        let client = makeClient { [reply] request in
            let path = request.url?.path ?? ""
            if path.contains("/branches") {
                return reply(200, #"[{"name":"master"}]"#)
            }
            return reply(404, #"{"message":"Not Found"}"#)
        }
        await #expect(throws: GitHubError.self) { _ = try await client.listFiles() }
    }

    /// The genuinely empty repository still works, because a first sync starts
    /// there. GitHub answers 409 for a repository with no commits.
    @Test("A repository with no commits still lists nothing")
    func emptyRepositoryIsStillEmpty() async throws {
        let client = makeClient { [reply] _ in
            reply(409, #"{"message":"Git Repository is empty."}"#)
        }
        #expect(try await client.listFiles().isEmpty)
    }

    /// Verify used to pass on a configuration that could not sync one file: the
    /// repository was checked and the branch was not.
    @Test("Verify fails when the branch does not exist")
    func verifyChecksTheBranch() async throws {
        let client = makeClient { [reply] request in
            let path = request.url?.path ?? ""
            if path.contains("/branches") { return reply(200, #"[{"name":"master"}]"#) }
            return reply(200, #"{"full_name":"owner/notes"}"#)
        }
        await #expect(throws: GitHubError.self) { _ = try await client.verify() }
    }

    @Test("Verify passes when the branch is there")
    func verifyAcceptsARealBranch() async throws {
        let client = makeClient { [reply] request in
            let path = request.url?.path ?? ""
            if path.contains("/branches") {
                return reply(200, #"[{"name":"main"},{"name":"master"}]"#)
            }
            return reply(200, #"{"full_name":"owner/notes"}"#)
        }
        #expect(try await client.verify() == "owner/notes")
    }

    /// A repository with no commits has no branches, and the branch's absence is
    /// not a mistake there.
    @Test("Verify accepts a repository with no commits")
    func verifyAcceptsAnEmptyRepository() async throws {
        let client = makeClient { [reply] request in
            let path = request.url?.path ?? ""
            if path.contains("/branches") { return reply(409, #"{"message":"empty"}"#) }
            return reply(200, #"{"full_name":"owner/notes"}"#)
        }
        #expect(try await client.verify() == "owner/notes")
    }

    /// The message has to name the branch and say what is actually there —
    /// "could not find <a file>. Check the repository name and branch" was the
    /// message 8,882 times, and it pointed at the file rather than the branch.
    @Test("The message names the branch and the alternatives")
    func messageIsUseful() {
        let error = GitHubError.branchNotFound(
            branch: "main", repository: "owner/notes", available: ["master"]
        )
        let text = error.errorDescription ?? ""
        #expect(text.contains("main"))
        #expect(text.contains("owner/notes"))
        #expect(text.contains("master"))
    }
  }
}

/// The general guard, independent of why the listing came back empty.
@Suite("Sync refuses to empty a vault")
struct SyncEmptyGuardTests {

    /// What the planner does with an empty listing, which is why the guard has to
    /// sit in front of it rather than inside it.
    @Test("An empty remote plans to delete a file that had synced")
    func plannerDeletesLocallyOnEmptyRemote() {
        let entry = SyncEntry(path: "Notes/Important.md", local: "aaa", remote: nil, base: "aaa")
        #expect(SyncPlanner.plan(entries: [entry]) == [.deleteLocal(path: "Notes/Important.md")])
    }

    @Test("The refusal says how many files it is protecting")
    func errorCountsWhatItProtects() {
        let text = SyncError.remoteUnexpectedlyEmpty(recorded: 8882).errorDescription ?? ""
        #expect(text.contains("8882"))
        #expect(text.lowercased().contains("stopped"))
    }
}
