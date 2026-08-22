import Foundation
import Testing
@testable import InkstoneCore

/// What must be true when a sync is cut off part way through.
///
/// This is the case a first sync on iOS hits every time: the whole vault has to
/// move, that takes minutes, and a background app-refresh window is around
/// thirty seconds. So the interrupted run is not an edge case to tolerate — it
/// is the normal path, and it has to leave the vault in a state the next run can
/// continue from rather than start over.
extension GitHubClientTests {

  @Suite("Sync interruption", .serialized)
  struct InterruptionTests {

    /// Mutable state shared with the URL-protocol stub, which runs on
    /// URLSession's threads rather than the test's.
    private final class Interrupter: @unchecked Sendable {
        var task: Task<SyncReport, Error>?
        var blobRequests = 0
    }

    private func remoteFiles() -> [(path: String, data: Data, sha: String)] {
        ["One.md", "Two.md", "Three.md"].map { name in
            let data = Data("remote \(name)\n".utf8)
            return (path: name, data: data, sha: gitBlobSHA(data))
        }
    }

    private func client(_ interrupter: Interrupter) -> GitHubClient {
        let files = remoteFiles()
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
                let entries = files.map {
                    #"{"path":"\#($0.path)","type":"blob","sha":"\#($0.sha)","size":\#($0.data.count)}"#
                }.joined(separator: ",")
                return reply(200, Data(#"{"tree":[\#(entries)]}"#.utf8))
            }
            if path.contains("git/blobs") {
                interrupter.blobRequests += 1
                // Cancel during the *second* download, not the first.
                //
                // Cancelling takes down the request that is in flight when it
                // happens — that is what URLSession's async API does — so
                // firing on the first one leaves nothing transferred and the
                // test cannot tell "kept what it moved" from "moved nothing".
                // Firing on the second leaves the shape a real expiry has: one
                // file safely down, one killed mid-flight, the rest untouched.
                if interrupter.blobRequests == 2 { interrupter.task?.cancel() }
                let sha = String(path.split(separator: "/").last ?? "")
                let match = files.first { $0.sha == sha } ?? files[0]
                return reply(200, match.data)
            }
            if path.contains("/branches") { return reply(200, Data(#"[{"name":"main"}]"#.utf8)) }
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

    @Test("An interrupted run keeps what it moved and does not claim it finished")
    func interruptedRunIsResumable() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "inkstone-interrupt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let interrupter = Interrupter()
        let engine = SyncEngine(
            client: client(interrupter), vaultRoot: root, policy: SyncFilePolicy()
        )

        // Assigned before any blob is fetched: the run makes two round trips —
        // verifying the repository and listing the tree — before it reaches the
        // first download, and both go through the stub.
        let task = Task { try await engine.run() }
        interrupter.task = task

        await #expect(throws: CancellationError.self) { try await task.value }

        let state = SyncState.load(from: root)

        // The point of the whole change. Were this not saved, the next run would
        // re-download everything this one already fetched.
        #expect(state.blobs.count == 1)
        #expect(FileManager.default.fileExists(atPath: root.appending(path: "One.md").path))

        // And the point of *not* stamping it: a vault that is a third synced must
        // not report itself as up to date.
        #expect(state.lastSyncedAt == nil)
    }

    @Test("The next run finishes what the interrupted one started")
    func resumeCompletes() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "inkstone-resume-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let interrupter = Interrupter()
        let engine = SyncEngine(
            client: client(interrupter), vaultRoot: root, policy: SyncFilePolicy()
        )

        let interrupted = Task { try await engine.run() }
        interrupter.task = interrupted
        _ = try? await interrupted.value

        // Second run, nothing cancelling it. It should move only what is left,
        // not all three again.
        let report = try await engine.run()
        #expect(report.downloaded.count == 2)
        #expect(SyncState.load(from: root).blobs.count == 3)
        #expect(SyncState.load(from: root).lastSyncedAt != nil)
    }
  }
}
