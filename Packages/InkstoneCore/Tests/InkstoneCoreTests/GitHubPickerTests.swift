import Foundation
import Testing
@testable import InkstoneCore

/// Listing the repositories and branches a token can reach, which is what turns
/// "type owner/repository and find out at sync time" into a choice.
extension GitHubClientTests {

  @Suite("GitHub picker", .serialized)
  struct PickerTests {

    private func makeClient(
        repository: String = "owner/notes",
        respond: @escaping @Sendable (URLRequest) -> (HTTPURLResponse, Data)
    ) -> GitHubClient {
        StubProtocol.handler = respond
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return GitHubClient(
            configuration: .init(repository: repository, branch: "main"),
            token: "test-token",
            session: URLSession(configuration: configuration),
            retry: .immediate
        )
    }

    private func ok(_ json: String) -> (HTTPURLResponse, Data) {
        (
            HTTPURLResponse(url: URL(string: "https://api.github.com")!,
                            statusCode: 200, httpVersion: nil, headerFields: [:])!,
            Data(json.utf8)
        )
    }

    @Test("Repositories are listed with their default branch")
    func listsRepositories() async throws {
        let client = makeClient { [ok] _ in
            ok("""
            [{"full_name":"owner/notes","default_branch":"main","permissions":{"push":true}},
             {"full_name":"owner/vault","default_branch":"trunk","permissions":{"push":false}}]
            """)
        }
        let repositories = try await client.listRepositories(pages: 1)
        #expect(repositories.map(\.fullName) == ["owner/notes", "owner/vault"])
        #expect(repositories[1].defaultBranch == "trunk")
    }

    /// A repository the token cannot write to is still offered — hiding it would
    /// leave someone hunting for one that is right there — but it is flagged,
    /// because sync would fail on the first upload.
    @Test("Read-only repositories are listed and flagged")
    func flagsReadOnly() async throws {
        let client = makeClient { [ok] _ in
            ok("""
            [{"full_name":"someone/theirs","default_branch":"main","permissions":{"push":false}}]
            """)
        }
        let repositories = try await client.listRepositories(pages: 1)
        #expect(repositories.first?.canPush == false)
    }

    /// GitHub omits `permissions` on some responses. Assuming "cannot push" would
    /// grey out every repository; assuming "can" fails later with a real message.
    @Test("A missing permissions block does not disable the repository")
    func missingPermissions() async throws {
        let client = makeClient { [ok] _ in
            ok(#"[{"full_name":"owner/notes","default_branch":"main"}]"#)
        }
        let repositories = try await client.listRepositories(pages: 1)
        #expect(repositories.first?.canPush == true)
    }

    /// Paging stops on a short page rather than asking for one more that is
    /// certain to be empty.
    @Test("Listing stops at a short page")
    func stopsAtShortPage() async throws {
        let counter = Counter()
        let client = makeClient { [ok] _ in
            _ = counter.next()
            return ok(#"[{"full_name":"a/b","default_branch":"main"}]"#)
        }
        _ = try await client.listRepositories(pages: 5)
        #expect(counter.count == 1)
    }

    @Test("Branches are listed by name")
    func listsBranches() async throws {
        let client = makeClient { [ok] _ in
            ok(#"[{"name":"main"},{"name":"drafts"}]"#)
        }
        #expect(try await client.listBranches() == ["main", "drafts"])
    }

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func next() -> Int { lock.lock(); defer { lock.unlock() }; value += 1; return value }
        var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    }
  }
}
