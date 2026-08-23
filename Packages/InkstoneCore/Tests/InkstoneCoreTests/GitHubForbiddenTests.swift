import Foundation
import Testing
@testable import InkstoneCore

/// 403 is GitHub's answer to three different things, and only one of them is
/// about the token.
extension GitHubClientTests {

  @Suite("GitHub 403", .serialized)
  struct ForbiddenTests {

    private func makeClient(
        status: Int,
        headers: [String: String] = [:],
        body: String = "{}"
    ) -> GitHubClient {
        StubProtocol.handler = { _ in
            (
                HTTPURLResponse(url: URL(string: "https://api.github.com")!,
                                statusCode: status, httpVersion: nil, headerFields: headers)!,
                Data(body.utf8)
            )
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return GitHubClient(
            configuration: .init(repository: "owner/notes", branch: "main"),
            token: "test-token",
            session: URLSession(configuration: configuration),
            retry: .immediate
        )
    }

    private func message(from client: GitHubClient) async -> String {
        do {
            _ = try await client.listBranches()
            return "(no error)"
        } catch {
            return (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
    }

    @Test("401 is the token")
    func unauthorised() async {
        let text = await message(from: makeClient(status: 401))
        #expect(text.contains("rejected the token"))
    }

    @Test("A spent primary limit is a rate limit")
    func primaryLimit() async {
        let text = await message(from: makeClient(
            status: 403, headers: ["X-RateLimit-Remaining": "0", "X-RateLimit-Reset": "1000000"]
        ))
        #expect(text.lowercased().contains("rate"))
        #expect(!text.contains("rejected the token"))
    }

    /// The one a burst of uploads trips, and the one that used to be reported as
    /// a bad token — about a token that had just written thousands of files.
    @Test("A secondary limit with Retry-After is a rate limit, not a bad token")
    func secondaryLimitByHeader() async {
        let text = await message(from: makeClient(
            status: 403, headers: ["Retry-After": "60", "X-RateLimit-Remaining": "4321"]
        ))
        #expect(text.lowercased().contains("rate"))
        #expect(!text.contains("rejected the token"))
    }

    @Test("A secondary limit that only says so in the body is still a rate limit")
    func secondaryLimitByBody() async {
        let text = await message(from: makeClient(
            status: 403,
            headers: ["X-RateLimit-Remaining": "4321"],
            body: #"{"message":"You have exceeded a secondary rate limit."}"#
        ))
        #expect(text.lowercased().contains("rate"))
        #expect(!text.contains("rejected the token"))
    }

    /// And a real refusal stays a refusal, naming the file — with thousands of
    /// them, "forbidden" is not something anyone can act on.
    @Test("A genuine refusal names what was refused")
    func genuineRefusal() async {
        let text = await message(from: makeClient(
            status: 403,
            headers: ["X-RateLimit-Remaining": "4321"],
            body: #"{"message":"Resource not accessible by personal access token"}"#
        ))
        #expect(text.contains("owner/notes"))
        #expect(text.contains("Resource not accessible"))
        #expect(!text.contains("rejected the token"))
    }
  }
}
