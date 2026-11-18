import Testing
import Foundation
@testable import InkstoneCore

/// What a save costs on a large vault: the work the app does between "the note
/// was written" and "the sidebar and backlinks are current again".
///
/// Opt-in (`INKSTONE_PERF=1`) because building a 10,000-note vault on disk takes
/// a few seconds. Numbers depend on the build configuration, so they are printed,
/// not asserted; run with `swift test -c release` for shipped figures and record
/// them in `docs/plans/2026-11-18-perf-ux-duo.md`.
@Suite("Vault scale performance", .enabled(if: ProcessInfo.processInfo.environment["INKSTONE_PERF"] != nil))
struct VaultScalePerformanceTests {

    /// A vault shaped like a real one: folders of notes with headings, tags,
    /// wikilinks to other notes (some unresolved) and a little body text.
    static func makeVault(notes: Int) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "inkstone-scale-\(UUID().uuidString)", directoryHint: .isDirectory)
        let folders = 40
        for f in 0..<folders {
            try FileManager.default.createDirectory(at: root.appending(path: "Area \(f)"), withIntermediateDirectories: true)
        }
        for i in 0..<notes {
            let folder = "Area \(i % folders)"
            let links = (1...4).map { "[[Note \((i * 7 + $0 * 131) % (notes + 200))]]" }.joined(separator: " ")
            let body = """
            ---
            tags: [project/\(i % 17), status/\(i % 3 == 0 ? "open" : "done")]
            ---
            # Note \(i)

            Some text about item \(i), linking to \(links).

            ## Details
            - point one #tag\(i % 23)
            - point two with **bold** and `code`
            - [ ] a task for \(i)

            More prose so the file is not trivially small. \(String(repeating: "Lorem ipsum dolor sit amet. ", count: 8))
            """
            try body.write(to: root.appending(path: "\(folder)/Note \(i).md"), atomically: false, encoding: .utf8)
        }
        return root
    }

    static func ms(_ start: UInt64) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }

    @Test func saveRoundTripOnTenThousandNotes() async throws {
        let root = try Self.makeVault(notes: 10_000)
        defer { try? FileManager.default.removeItem(at: root) }

        // Cold: what opening the vault costs.
        var t = DispatchTime.now().uptimeNanoseconds
        _ = VaultScanner().scan(root)
        let scan = Self.ms(t)

        t = DispatchTime.now().uptimeNanoseconds
        let snapshot = await IndexBuilder().build(vaultRoot: root)
        let fullIndex = Self.ms(t)
        #expect(snapshot.noteCount == 10_000)

        // One note saved, then what the app does in response.
        let edited = root.appending(path: "Area 3/Note 3.md")
        try (try String(contentsOf: edited, encoding: .utf8) + "\nA new line linking [[Note 42]].")
            .write(to: edited, atomically: true, encoding: .utf8)

        t = DispatchTime.now().uptimeNanoseconds
        _ = VaultScanner().scan(root)
        _ = await IndexBuilder().build(vaultRoot: root)
        let fullRoundTrip = Self.ms(t)

        // The same save, handled incrementally: reuse every note whose date is
        // unchanged. (All files were just written, so age them past the
        // "recently touched" window first — as they would be in a real vault.)
        for f in VaultScanner().markdownFiles(in: root) where f != edited {
            try FileManager.default.setAttributes([.modificationDate: Date.now.addingTimeInterval(-3600)], ofItemAtPath: f.path)
        }
        let warm = await IndexBuilder().build(vaultRoot: root)
        try (try String(contentsOf: edited, encoding: .utf8) + "\nAnother line [[Note 43]].")
            .write(to: edited, atomically: true, encoding: .utf8)
        t = DispatchTime.now().uptimeNanoseconds
        let incremental = await IndexBuilder().build(vaultRoot: root, reusing: warm)
        let incrementalIndex = Self.ms(t)
        #expect(incremental.noteCount == 10_000)

        // Where the incremental time goes.
        t = DispatchTime.now().uptimeNanoseconds
        let files = VaultScanner().markdownFiles(in: root)
        let enumerate = Self.ms(t)
        t = DispatchTime.now().uptimeNanoseconds
        let store = NoteStore(root: root)
        for f in files { _ = store.modificationDates(of: f) }
        let stats = Self.ms(t)
        t = DispatchTime.now().uptimeNanoseconds
        _ = IndexBuilder.assemble(Array(incremental.notes.values), vaultRoot: root)
        let assemble = Self.ms(t)
        // Resolution alone, and URL-keyed dictionary work alone.
        t = DispatchTime.now().uptimeNanoseconds
        var resolved = 0
        for note in incremental.notes.values {
            for link in note.outgoingLinks where !link.target.isEmpty {
                if incremental.resolve(link.target, from: note.url, vaultRoot: root) != nil { resolved += 1 }
            }
        }
        let resolveOnly = Self.ms(t)
        t = DispatchTime.now().uptimeNanoseconds
        var bucket: [URL: [Int]] = [:]
        for note in incremental.notes.values { for _ in note.outgoingLinks { bucket[note.url, default: []].append(1) } }
        let urlDict = Self.ms(t)
        print(String(format: "SCALE resolveOnly=%.1fms (resolved %d) urlKeyedAppends=%.1fms", resolveOnly, resolved, urlDict))
        print(String(format: "SCALE breakdown enumerate=%.1fms stat=%.1fms assemble=%.1fms", enumerate, stats, assemble))

        // Sync's local scan: every file read and hashed, versus stamps reused.
        let engine = SyncEngine(
            client: GitHubClient(configuration: .init(repository: "a/b", branch: "main"), token: "t"),
            vaultRoot: root, policy: SyncFilePolicy())
        t = DispatchTime.now().uptimeNanoseconds
        let cold = engine.localFiles(cache: [:], trustBefore: .distantPast)
        let syncCold = Self.ms(t)
        t = DispatchTime.now().uptimeNanoseconds
        let warmScan = engine.localFiles(cache: cold.stamps, trustBefore: .distantFuture)
        let syncWarm = Self.ms(t)
        #expect(warmScan.files == cold.files)
        print(String(format: "SCALE syncScan cold(hash all)=%.1fms warm(stamps)=%.1fms", syncCold, syncWarm))

        print(String(format: "SCALE notes=10000 scan=%.1fms fullIndex=%.1fms saveRoundTrip(full rescan+reindex)=%.1fms incrementalIndex=%.1fms", scan, fullIndex, fullRoundTrip, incrementalIndex))
    }
}
