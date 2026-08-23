import Foundation
import Testing
@testable import InkstoneCore

/// The Contents API refuses large files, and refusing them is not a conflict.
extension GitHubClientTests {

  @Suite("GitHub upload size", .serialized)
  struct UploadSizeTests {

    private func makeClient(
        respond: @escaping @Sendable (URLRequest) -> (HTTPURLResponse, Data)
    ) -> GitHubClient {
        StubProtocol.handler = respond
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return GitHubClient(
            configuration: .init(repository: "owner/notes", branch: "main"),
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

    final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func raise() { lock.lock(); value = true; lock.unlock() }
        var wasRaised: Bool { lock.lock(); defer { lock.unlock() }; return value }
    }

    private func message(_ error: any Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? "\(error)"
    }

    /// The whole point of the local guard: a file GitHub will refuse should not
    /// be encoded and sent first. On a fifteen-minute schedule a 63 MB PDF meant
    /// 84 MB uploaded four times an hour to be told no every time.
    @Test("A file over the limit never reaches the network")
    func refusedBeforeSending() async {
        let sent = Flag()
        let client = makeClient { [reply] _ in
            sent.raise()
            return reply(201, #"{"content":{"sha":"a"}}"#)
        }
        let big = Data(count: GitHubClient.largestUploadableSize + 1)
        do {
            _ = try await client.upload(path: "Big.pdf", contents: big, sha: nil, message: "m")
            Issue.record("should have refused")
        } catch {
            #expect(message(error).contains("Big.pdf"))
            #expect(message(error).lowercased().contains("git"))
        }
        #expect(!sent.wasRaised, "it was sent anyway")
    }

    @Test("A file at the limit is still attempted")
    func limitIsInclusive() async throws {
        let client = makeClient { [reply] _ in reply(201, #"{"content":{"sha":"abc"}}"#) }
        let sha = try await client.upload(
            path: "Edge.pdf",
            contents: Data(count: GitHubClient.largestUploadableSize),
            sha: nil,
            message: "m"
        )
        #expect(sha == "abc")
    }

    /// The regression: 422 "too large" was reported as a mid-sync conflict, which
    /// tells the user to run sync again — and it would fail identically forever.
    @Test("A 422 saying the file is too large is not reported as a conflict")
    func tooLargeIsNotAConflict() async {
        let client = makeClient { [reply] _ in
            reply(422, #"{"message":"Sorry, the file is too large to be processed."}"#)
        }
        do {
            _ = try await client.upload(path: "Big.pdf", contents: Data("x".utf8), sha: nil, message: "m")
            Issue.record("should have thrown")
        } catch {
            let text = message(error)
            #expect(!text.contains("changed on GitHub"))
            #expect(!text.contains("Run sync again"))
            #expect(text.contains("Big.pdf"))
        }
    }

    /// And a real sha mismatch stays what it is, because running sync again is
    /// exactly the right advice there.
    @Test("A 409 is still a conflict")
    func shaMismatchIsStillAConflict() async {
        let client = makeClient { [reply] _ in
            reply(409, #"{"message":"is at abc but expected def"}"#)
        }
        do {
            _ = try await client.upload(path: "Note.md", contents: Data("x".utf8), sha: "old", message: "m")
            Issue.record("should have thrown")
        } catch {
            #expect(message(error).contains("changed on GitHub"))
        }
    }
  }
}
