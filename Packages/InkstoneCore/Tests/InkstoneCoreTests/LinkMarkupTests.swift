import Testing
import Foundation
@testable import InkstoneCore

/// The two settings that decide what a newly inserted link says.
///
/// Both had a control in Settings and no reader anywhere until this was written,
/// so every test here is also the first evidence that the switch does anything.
@Suite("Link markup")
struct LinkMarkupTests {
    let root = URL(fileURLWithPath: "/vault")

    private func note(_ path: String, text: String = "") -> NoteMetadata {
        NoteParser.parse(text: text, url: root.appending(path: path))
    }

    private func index(_ notes: [NoteMetadata]) -> IndexSnapshot {
        IndexBuilder.assemble(notes, vaultRoot: root)
    }

    // MARK: - newLinkFormat

    @Test("Wikilink and Markdown formats produce different markup")
    func honoursTheFormatSetting() {
        let target = root.appending(path: "work/Plan.md")
        let source = root.appending(path: "Index.md")

        let wiki = LinkMarkup.markup(for: target, from: source, vaultRoot: root,
                                     format: .wikilink, shortest: false, isEmbed: false)
        let md = LinkMarkup.markup(for: target, from: source, vaultRoot: root,
                                   format: .markdown, shortest: false, isEmbed: false)

        #expect(wiki == "[[work/Plan]]")
        #expect(md == "[Plan](work/Plan)")
        #expect(wiki != md)
    }

    @Test("An embed is the same markup with a bang")
    func marksEmbeds() {
        let target = root.appending(path: "shots/diagram.png")
        let source = root.appending(path: "Index.md")

        #expect(LinkMarkup.markup(for: target, from: source, vaultRoot: root,
                                  format: .wikilink, shortest: false, isEmbed: true)
                == "![[shots/diagram.png]]")
        #expect(LinkMarkup.markup(for: target, from: source, vaultRoot: root,
                                  format: .markdown, shortest: false, isEmbed: true)
                == "![diagram](shots/diagram.png)")
    }

    @Test("A Markdown destination with a space is percent-encoded")
    func encodesMarkdownDestinations() {
        // Legal in a wikilink, broken in a Markdown URL. The label keeps the
        // space, because a reader reads the label.
        let target = root.appending(path: "my notes/A Plan.md")
        let markup = LinkMarkup.markup(for: target, from: root.appending(path: "Index.md"),
                                       vaultRoot: root, format: .markdown,
                                       shortest: false, isEmbed: false)
        #expect(markup == "[A Plan](my%20notes/A%20Plan)")
    }

    // MARK: - useShortestPathLinks

    @Test("Shortest paths use the bare name when it is unambiguous")
    func shortensUnambiguousNames() {
        let snapshot = index([note("work/Plan.md"), note("Index.md")])
        let target = root.appending(path: "work/Plan.md")

        #expect(LinkMarkup.reference(for: target, from: root.appending(path: "Index.md"),
                                     vaultRoot: root, shortest: true, snapshot: snapshot) == "Plan")
        #expect(LinkMarkup.reference(for: target, from: root.appending(path: "Index.md"),
                                     vaultRoot: root, shortest: false, snapshot: snapshot)
                == "work/Plan")
    }

    @Test("An ambiguous name is never shortened")
    func refusesToShortenAmbiguousNames() {
        // The whole reason the setting is not simply "always use the file name":
        // two notes called Plan, and a bare [[Plan]] resolves to whichever
        // happens to be nearest — a link that silently points at the wrong file.
        let snapshot = index([note("work/Plan.md"), note("personal/Plan.md"), note("Index.md")])
        let reference = LinkMarkup.reference(
            for: root.appending(path: "work/Plan.md"),
            from: root.appending(path: "Index.md"),
            vaultRoot: root, shortest: true, snapshot: snapshot
        )
        #expect(reference == "work/Plan")
    }

    @Test("With no index to ask, the full path is used")
    func fallsBackWithoutAnIndex() {
        // A drop that lands before the first scan finishes. The full path can
        // never be wrong; a guessed short name can.
        let reference = LinkMarkup.reference(
            for: root.appending(path: "work/Plan.md"),
            from: root.appending(path: "Index.md"),
            vaultRoot: root, shortest: true, snapshot: nil
        )
        #expect(reference == "work/Plan")
    }

    // MARK: - Paths

    @Test("A note drops its extension and an attachment keeps it")
    func handlesExtensions() {
        #expect(LinkMarkup.vaultRelativePath(of: root.appending(path: "a/B.md"), in: root) == "a/B")
        #expect(LinkMarkup.vaultRelativePath(of: root.appending(path: "a/B.png"), in: root) == "a/B.png")
    }

    @Test("A file outside the vault falls back to its name")
    func handlesFilesOutsideTheVault() {
        let outside = URL(fileURLWithPath: "/elsewhere/Thing.md")
        #expect(LinkMarkup.vaultRelativePath(of: outside, in: root) == "Thing.md")
    }

    @Test("Whatever it writes, the index can resolve it back")
    func roundTrips() {
        // The property that actually matters. Every other test here checks a
        // string; this one checks that the string is a working link.
        let snapshot = index([note("work/Plan.md"), note("personal/Plan.md"),
                              note("solo/Unique.md"), note("Index.md")])
        let source = root.appending(path: "Index.md")

        for target in [root.appending(path: "work/Plan.md"),
                       root.appending(path: "solo/Unique.md")] {
            for shortest in [true, false] {
                let reference = LinkMarkup.reference(for: target, from: source, vaultRoot: root,
                                                     shortest: shortest, snapshot: snapshot)
                #expect(snapshot.resolve(reference, from: source, vaultRoot: root) == target,
                        "\(reference) did not resolve back to \(target.lastPathComponent)")
            }
        }
    }
}

/// Full-text search, after it was moved off the main thread and parallelised.
@Suite("Full-text search")
struct FullTextSearchTests {
    let root = URL(fileURLWithPath: "/vault")

    /// A vault on disk, because the whole point of this function is that it
    /// reads files.
    private func vault(_ files: [String: String]) throws -> (URL, NoteStore, IndexSnapshot) {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "search-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        var notes: [NoteMetadata] = []
        for (name, text) in files {
            let url = base.appending(path: name)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
            notes.append(NoteParser.parse(text: text, url: url))
        }
        return (base, NoteStore(root: base), IndexBuilder.assemble(notes, vaultRoot: base))
    }

    @Test("Parallel search finds what the serial one found")
    func agreesWithTheSerialVersion() async throws {
        // The property that matters when replacing an implementation.
        let (base, store, snapshot) = try vault([
            "a.md": "the quick brown fox\nand a second line",
            "b/c.md": "quick again here",
            "d.md": "nothing relevant",
            "e.md": "---\ntags: [findable]\n---\nquick with a tag",
        ])
        defer { try? FileManager.default.removeItem(at: base) }

        for query in ["quick", "second", "tag:findable", "tag:findable quick", "absent"] {
            let serial = SearchEngine.fullText(query: query, in: snapshot, store: store)
            let parallel = await SearchEngine.fullTextConcurrently(query: query, in: snapshot, store: store)
            #expect(Set(serial.map(\.url)) == Set(parallel.map(\.url)), "disagreed on \(query.debugDescription)")
        }
    }

    @Test("The same search twice gives the same order")
    func isStable() async throws {
        // A task group answers in whatever order the disk does. A result list
        // that reshuffles between two identical searches is worse than a slow one.
        let files = Dictionary(uniqueKeysWithValues: (0..<40).map {
            ("note-\($0).md", "shared term in note \($0)")
        })
        let (base, store, snapshot) = try vault(files)
        defer { try? FileManager.default.removeItem(at: base) }

        let first = await SearchEngine.fullTextConcurrently(query: "shared", in: snapshot, store: store)
        let second = await SearchEngine.fullTextConcurrently(query: "shared", in: snapshot, store: store)
        #expect(first.map(\.url) == second.map(\.url))
        #expect(first.count == 40)
    }

    @Test("It stops at the limit rather than reading the whole vault")
    func honoursTheLimit() async throws {
        let files = Dictionary(uniqueKeysWithValues: (0..<50).map {
            ("note-\($0).md", "common word")
        })
        let (base, store, snapshot) = try vault(files)
        defer { try? FileManager.default.removeItem(at: base) }

        let hits = await SearchEngine.fullTextConcurrently(
            query: "common", in: snapshot, store: store, limit: 10, batchSize: 4)
        #expect(hits.count == 10)
    }

    @Test("A metadata-only query needs no file reads")
    func handlesMetadataOnlyQueries() async throws {
        let (base, store, snapshot) = try vault([
            "a.md": "---\ntags: [wanted]\n---\nbody",
            "b.md": "no tag here",
        ])
        defer { try? FileManager.default.removeItem(at: base) }

        let hits = await SearchEngine.fullTextConcurrently(query: "tag:wanted", in: snapshot, store: store)
        #expect(hits.count == 1)
        #expect(hits[0].url.lastPathComponent == "a.md")
    }

    @Test("The note order the snapshot carries is stable and complete")
    func ordersNotesOnce() throws {
        let (base, _, snapshot) = try vault([
            "z.md": "", "a.md": "", "m/n.md": "",
        ])
        defer { try? FileManager.default.removeItem(at: base) }

        #expect(snapshot.orderedNotes.count == snapshot.notes.count)
        #expect(Set(snapshot.orderedNotes) == Set(snapshot.notes.keys))
        #expect(snapshot.orderedNotes == snapshot.orderedNotes.sorted {
            $0.path(percentEncoded: false) < $1.path(percentEncoded: false)
        })
    }
}
