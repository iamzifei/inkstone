import Foundation
import Testing
@testable import InkstoneCore

/// GitHub answers a 503 with "Please try resubmitting your request".
///
/// This client did not resubmit, so a single transient failure took a whole sync
/// down with it. Measured against a real repository before this existed: two runs
/// in five failed on a 503, while every operation involved was individually fine
/// when tried by hand seconds later.
/// Nested inside `GitHub client` so that its `.serialized` covers both. As
/// separate top-level suites they ran concurrently while sharing one static
/// `StubProtocol.handler`, and each suite answered the other's requests: a retry
/// test counted four attempts of three, and a client test got `.notFound` from a
/// handler it never installed. The same mistake, and the same fix, as the two
/// GitHub integration suites.
extension GitHubClientTests {

  @Suite("GitHub retry", .serialized)
  struct RetryTests {

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func next() -> Int {
            lock.lock(); defer { lock.unlock() }
            value += 1
            return value
        }
        var count: Int {
            lock.lock(); defer { lock.unlock() }
            return value
        }
    }

    private func makeClient(
        respond: @escaping @Sendable (URLRequest) -> (HTTPURLResponse, Data)
    ) -> GitHubClient {
        StubProtocol.handler = respond
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return GitHubClient(
            configuration: .init(repository: "iamzifei/notes", branch: "main"),
            token: "test-token",
            session: URLSession(configuration: configuration),
            retry: .immediate
        )
    }

    private func response(_ status: Int) -> HTTPURLResponse {
        HTTPURLResponse(
            url: URL(string: "https://api.github.com")!,
            statusCode: status, httpVersion: nil, headerFields: [:]
        )!
    }

    @Test("A 503 is retried and the request succeeds")
    func retriesTransientFailure() async throws {
        let counter = Counter()
        let client = makeClient { [response] _ in
            if counter.next() == 1 {
                return (response(503), Data(#"{"message":"No server is currently available"}"#.utf8))
            }
            return (response(200), Data(#"{"full_name":"iamzifei/notes"}"#.utf8))
        }
        let name = try await client.verify()
        #expect(name == "iamzifei/notes")
        #expect(counter.count == 2, "should have taken exactly one retry")
    }

    @Test("Retries are bounded, and the last failure is what surfaces")
    func givesUpEventually() async throws {
        let counter = Counter()
        let client = makeClient { [response] _ in
            _ = counter.next()
            return (response(503), Data(#"{"message":"No server is currently available"}"#.utf8))
        }
        await #expect(throws: GitHubError.self) { try await client.verify() }
        #expect(counter.count == 3, "three attempts, not an unbounded loop")
    }

    /// A 4xx is an answer. Repeating a request GitHub understood and refused just
    /// gets it refused again — and for 401 it would mean re-sending a rejected
    /// token, which is how accounts get rate-limited.
    @Test("A 401 is not retried")
    func doesNotRetryUnauthorised() async throws {
        let counter = Counter()
        let client = makeClient { [response] _ in
            _ = counter.next()
            return (response(401), Data(#"{"message":"Bad credentials"}"#.utf8))
        }
        await #expect(throws: GitHubError.self) { try await client.verify() }
        #expect(counter.count == 1)
    }

    @Test("A 404 is not retried")
    func doesNotRetryNotFound() async throws {
        let counter = Counter()
        let client = makeClient { [response] _ in
            _ = counter.next()
            return (response(404), Data(#"{"message":"Not Found"}"#.utf8))
        }
        await #expect(throws: GitHubError.self) { try await client.verify() }
        #expect(counter.count == 1)
    }

    /// 429 is the other "come back later", and is worth the same treatment as a
    /// 5xx — unlike the 403 GitHub uses for a spent rate limit, which carries a
    /// reset time and is reported to the user rather than hammered.
    @Test("A 429 is retried")
    func retriesTooManyRequests() async throws {
        let counter = Counter()
        let client = makeClient { [response] _ in
            if counter.next() < 3 {
                return (response(429), Data(#"{"message":"Too many requests"}"#.utf8))
            }
            return (response(200), Data(#"{"full_name":"iamzifei/notes"}"#.utf8))
        }
        _ = try await client.verify()
        #expect(counter.count == 3)
    }
}
}
