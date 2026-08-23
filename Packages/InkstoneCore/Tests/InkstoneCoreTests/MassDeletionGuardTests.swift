import Foundation
import Testing
@testable import InkstoneCore

/// A sync that would delete most of the vault stops and asks.
///
/// Both of the incidents this guard exists for had the same shape: a vault
/// pointed at a repository that was not its own, where nearly everything on one
/// side looked deleted on the other. The engine's answer to a deletion is to
/// propagate it, so that shape empties something.
///
/// The two halves matter equally. A guard that never fires is decoration; a
/// guard that fires on ordinary tidying trains people to click through it.
extension GitHubClientTests {

  @Suite("Mass deletion guard", .serialized)
  struct MassDeletionGuardTests {

    /// Builds a vault whose recorded state holds `recorded` files and whose disk
    /// holds `kept` of them, so `recorded - kept` read as local deletions.
    private func vault(recorded: Int, kept: Int) throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "inkstone-guard-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        var state = SyncState()
        for index in 0..<recorded {
            let name = "Note \(index).md"
            let data = Data("note \(index)\n".utf8)
            state.blobs[name] = gitBlobSHA(data)
            if index < kept { try data.write(to: root.appending(path: name)) }
        }
        state.lastSyncedAt = Date()
        state.repository = "owner/notes"
        state.branch = "main"
        try state.save(to: root)
        return root
    }

    /// A remote that still lists everything the state recorded — so whatever is
    /// missing on disk is a local deletion the run wants to push.
    private func client(recorded: Int) -> GitHubClient {
        StubProtocol.handler = { request in
            let path = request.url?.path ?? ""
            func reply(_ status: Int, _ body: Data) -> (HTTPURLResponse, Data) {
                (
                    HTTPURLResponse(url: request.url!, statusCode: status,
                                    httpVersion: nil, headerFields: [:])!,
                    body
                )
            }
            if path.contains("git/trees") {
                let entries = (0..<recorded).map { index -> String in
                    let data = Data("note \(index)\n".utf8)
                    return #"{"path":"Note \#(index).md","type":"blob","sha":"\#(gitBlobSHA(data))","size":\#(data.count)}"#
                }.joined(separator: ",")
                return reply(200, Data(#"{"tree":[\#(entries)]}"#.utf8))
            }
            if path.contains("/branches") { return reply(200, Data(#"[{"name":"main"}]"#.utf8)) }
            if request.httpMethod == "DELETE" || request.httpMethod == "PUT" {
                return reply(200, Data(#"{"content":{"sha":"0000000000000000000000000000000000000000"}}"#.utf8))
            }
            return reply(200, Data(#"{"full_name":"owner/notes"}"#.utf8))
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

    @Test("Losing most of a synced vault stops the run")
    func stopsOnMassDeletion() async throws {
        let root = try vault(recorded: 40, kept: 2)
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = SyncEngine(client: client(recorded: 40), vaultRoot: root, policy: SyncFilePolicy())

        await #expect(throws: SyncError.self) { try await engine.run() }

        // Nothing was written before it stopped — including the state, which is
        // what makes the next run see the same thing and ask again.
        #expect(SyncState.load(from: root).blobs.count == 40)
    }

    @Test("The message says how many, out of how many, and which side")
    func messageIsAnswerable() {
        let error = SyncError.tooManyDeletions(deleting: 38, of: 40, side: .remote)
        let text = error.errorDescription ?? ""
        #expect(text.contains("38"))
        #expect(text.contains("40"))
        #expect(text.contains("GitHub"))
    }

    @Test("Confirming lets the same run through")
    func confirmationProceeds() async throws {
        let root = try vault(recorded: 40, kept: 2)
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = SyncEngine(client: client(recorded: 40), vaultRoot: root, policy: SyncFilePolicy())

        let report = try await engine.run(confirmingLargeDeletion: true)
        #expect(report.deletedRemotely.count == 38)
    }

    /// The other half. Deleting a few notes out of many is ordinary use, and a
    /// guard that interrupts it would be worse than no guard: people learn to
    /// dismiss it, and then it does not work for the case it exists for.
    @Test("Ordinary tidying is not interrupted")
    func ordinaryDeletionsPassThrough() async throws {
        let root = try vault(recorded: 40, kept: 35)
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = SyncEngine(client: client(recorded: 40), vaultRoot: root, policy: SyncFilePolicy())

        let report = try await engine.run()
        #expect(report.deletedRemotely.count == 5)
    }

    /// A share is meaningless on a handful of files: two of three is 67%.
    @Test("A tiny vault is judged by count, not by share")
    func smallVaultsAreNotJudgedByShare() async throws {
        let root = try vault(recorded: 6, kept: 0)
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = SyncEngine(client: client(recorded: 6), vaultRoot: root, policy: SyncFilePolicy())

        let report = try await engine.run()
        #expect(report.deletedRemotely.count == 6)
    }

    /// A first sync has no recorded state, so there is nothing to measure a
    /// share against — and nothing it could be deleting.
    @Test("A vault that has never synced is not measured against nothing")
    func firstSyncIsUnaffected() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "inkstone-guard-first-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = SyncEngine(client: client(recorded: 40), vaultRoot: root, policy: SyncFilePolicy())

        let report = try await engine.run()
        #expect(report.downloaded.count == 40)
        #expect(report.deletedRemotely.isEmpty)
    }
  }
}
