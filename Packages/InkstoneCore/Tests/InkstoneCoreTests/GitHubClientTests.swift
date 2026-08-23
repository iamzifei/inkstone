import Testing
import Foundation
@testable import InkstoneCore

/// Exercises the GitHub client against a stubbed URL protocol.
///
/// No network, no token, no repository: the point is to pin the request shape
/// and — more importantly — the error mapping, because a misread status code
/// turns "your token expired" into a sync that quietly does nothing.
// `.serialized` matters: the stub handler is static, and swift-testing runs
// tests in parallel by default, so concurrent cases were overwriting each
// other's stub and every request came back with whichever response won.
@Suite("GitHub client", .serialized)
struct GitHubClientTests {

    // MARK: - Stub plumbing

    final class StubProtocol: URLProtocol, @unchecked Sendable {
        nonisolated(unsafe) static var handler: (@Sendable (URLRequest) -> (HTTPURLResponse, Data))?
        nonisolated(unsafe) static var lastRequest: URLRequest?

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            Self.lastRequest = request
            guard let handler = Self.handler else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }
            let (response, data) = handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

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
            session: URLSession(configuration: configuration)
        )
    }

    private func response(_ status: Int, headers: [String: String] = [:]) -> HTTPURLResponse {
        HTTPURLResponse(
            url: URL(string: "https://api.github.com")!,
            statusCode: status,
            httpVersion: nil,
            headerFields: headers
        )!
    }

    // MARK: - Listing

    @Test("Listing asks for the whole tree in one recursive request")
    func listUsesRecursiveTree() async throws {
        let json = """
        {"tree":[
          {"path":"Home.md","type":"blob","sha":"aaa","size":10},
          {"path":"Ideas","type":"tree","sha":"bbb"},
          {"path":"Ideas/Product.md","type":"blob","sha":"ccc","size":20}
        ]}
        """
        let client = makeClient { _ in (self.response(200), Data(json.utf8)) }
        let files = try await client.listFiles()

        // Directories are not files; only blobs come back.
        #expect(files.map(\.path) == ["Home.md", "Ideas/Product.md"])
        #expect(files.first?.sha == "aaa")

        let url = StubProtocol.lastRequest?.url?.absoluteString ?? ""
        #expect(url.contains("git/trees/main"))
        #expect(url.contains("recursive=1"))
    }

    @Test("A repository with no commits lists no files rather than failing")
    func repositoryWithNoCommitsIsEmpty() async throws {
        // Distinct from the 404 case above. A repository created with no initial
        // commit answers 409 "Git Repository is empty" — which the error mapping
        // otherwise reads as a mid-sync conflict, so a first sync into a brand
        // new repository failed outright. Found against the real API.
        let client = makeClient { _ in
            (self.response(409), Data(#"{"message":"Git Repository is empty."}"#.utf8))
        }
        #expect(try await client.listFiles().isEmpty)
    }

    @Test("A 404 on the tree is a missing branch, not an empty repository")
    func missingBranchIsNotAnEmptyRepository() async throws {
        // This test asserted the opposite, and that assertion is what the bug was
        // made of: a 404 here means "no such branch", and reporting it as an
        // empty remote told the planner every synced file had been deleted
        // remotely — whose answer is to delete the local copy. Found against a
        // real repository whose only branch is `master` while the setting said
        // `main`: 8,882 files, every one of them a failed upload, and every one
        // of them a local deletion had the vault synced once before.
        //
        // The genuinely empty repository is the 409 above.
        let client = makeClient { request in
            if request.url?.path.contains("/branches") == true {
                return (self.response(200), Data(#"[{"name":"master"}]"#.utf8))
            }
            return (self.response(404), Data("{}".utf8))
        }
        await #expect(throws: GitHubError.self) { _ = try await client.listFiles() }
    }

    @Test("Requests bypass the URL cache")
    func requestsBypassCache() async throws {
        // GitHub sends `cache-control: private, max-age=60`. Honouring it means a
        // second sync within a minute sees a stale file list, misreads the file
        // it just uploaded as deleted on the remote, and deletes the local copy.
        // Found by running a real upload/list round trip.
        let client = makeClient { request in
            if request.url?.path.contains("/branches") == true {
                return (self.response(200), Data(#"[{"name":"main"}]"#.utf8))
            }
            return (self.response(200), Data(#"{"full_name":"owner/notes"}"#.utf8))
        }
        _ = try await client.verify()

        #expect(StubProtocol.lastRequest?.cachePolicy == .reloadIgnoringLocalAndRemoteCacheData)
    }

    @Test("Requests carry the token and API version")
    func headers() async throws {
        let client = makeClient { request in
            if request.url?.path.contains("/branches") == true {
                return (self.response(200), Data(#"[{"name":"main"}]"#.utf8))
            }
            return (self.response(200), Data(#"{"full_name":"owner/notes"}"#.utf8))
        }
        _ = try await client.verify()

        let request = StubProtocol.lastRequest
        #expect(request?.value(forHTTPHeaderField: "Authorization") == "Bearer test-token")
        #expect(request?.value(forHTTPHeaderField: "X-GitHub-Api-Version") == "2022-11-28")
    }

    // MARK: - Error mapping

    @Test("A bad repository name is rejected before any request")
    func badRepository() async {
        let client = makeClient(repository: "not-a-pair") { _ in (self.response(200), Data()) }
        await #expect(throws: GitHubError.self) { try await client.listFiles() }
    }

    @Test("401 reads as an authorisation problem")
    func unauthorised() async {
        let client = makeClient { _ in (self.response(401), Data()) }
        await #expect(throws: GitHubError.self) { try await client.verify() }
    }

    @Test("A spent rate limit is not reported as a bad token")
    func rateLimit() async throws {
        // GitHub returns 403 for both. Telling the user their token is broken
        // when they have simply run out of requests sends them to regenerate a
        // token that was fine.
        let client = makeClient { _ in
            (self.response(403, headers: [
                "X-RateLimit-Remaining": "0",
                "X-RateLimit-Reset": "1755300000",
            ]), Data())
        }
        do {
            _ = try await client.verify()
            Issue.record("expected a rate-limit error")
        } catch let error as GitHubError {
            guard case .rateLimited = error else {
                Issue.record("expected .rateLimited, got \(error)")
                return
            }
        }
    }

    @Test("Uploads send base64 content and the existing blob SHA")
    func uploadShape() async throws {
        let client = makeClient { _ in
            (self.response(200), Data(#"{"content":{"sha":"newsha"}}"#.utf8))
        }
        let sha = try await client.upload(
            path: "Ideas/Product Ideas.md",
            contents: Data("hello".utf8),
            sha: "oldsha",
            message: "Update"
        )
        #expect(sha == "newsha")

        let request = StubProtocol.lastRequest
        #expect(request?.httpMethod == "PUT")
        // A space in the path has to be encoded, but the separators must not be.
        #expect(request?.url?.absoluteString.contains("Ideas/Product%20Ideas.md") == true)

        let body = try #require(request?.httpBodyStream.map { stream -> Data in
            stream.open()
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                data.append(contentsOf: buffer[0..<read])
            }
            stream.close()
            return data
        } ?? request?.httpBody)
        let payload = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(payload["content"] as? String == Data("hello".utf8).base64EncodedString())
        #expect(payload["sha"] as? String == "oldsha")
        #expect(payload["branch"] as? String == "main")
    }

    @Test("Files over the API's 100 MB ceiling are refused locally")
    func tooLarge() async {
        // Better to say so than to spend minutes uploading and have GitHub
        // reject it at the end.
        let client = makeClient { _ in (self.response(200), Data()) }
        let big = Data(repeating: 0, count: 101 * 1_048_576)
        await #expect(throws: GitHubError.self) {
            try await client.upload(path: "big.mov", contents: big, sha: nil, message: "m")
        }
    }
}
