import Testing
import Foundation
@testable import InkstoneCore

@Suite("Frontmatter")
struct FrontmatterTests {
    @Test("Parses a YAML block at the top of a note")
    func parsesBlock() {
        let text = """
        ---
        title: Reading Notes
        tags: [book, 读书]
        aliases:
          - Notes on Reading
        ---

        # Body
        """
        let (frontmatter, body) = FrontmatterParser.parse(text)
        #expect(frontmatter.properties["title"]?.stringValue == "Reading Notes")
        #expect(frontmatter.tags.sorted() == ["book", "读书"])
        #expect(frontmatter.aliases == ["Notes on Reading"])
        #expect(body.hasPrefix("\n# Body") || body.hasPrefix("# Body"))
    }

    @Test("A horizontal rule mid-document is not frontmatter")
    func ignoresMidDocumentRule() {
        let text = "# Title\n\n---\n\nnot: frontmatter\n---\n"
        let (frontmatter, body) = FrontmatterParser.parse(text)
        #expect(frontmatter.properties.isEmpty)
        #expect(body == text[...])
    }

    @Test("Comma-separated tags are split")
    func splitsInlineTagList() {
        let (frontmatter, _) = FrontmatterParser.parse("---\ntags: a, b, c\n---\n")
        #expect(frontmatter.tags == ["a", "b", "c"])
    }
}

@Suite("Syntax scanner")
struct SyntaxScannerTests {
    let scanner = SyntaxScanner()

    @Test("Parses wikilink targets, fragments, and aliases")
    func parsesWikiLinks() {
        let links = scanner.links(in: "See [[Note A]], [[Note B#Section]] and [[Note C|display]].")
        #expect(links.count == 3)
        #expect(links[0].target == "Note A")
        #expect(links[1].fragment == "Section")
        #expect(links[2].alias == "display")
        #expect(links[2].displayText == "display")
    }

    @Test("Ignores tags and links inside code")
    func masksCode() {
        let text = """
        Real #tag here.

        ```swift
        // #nottag and [[not a link]]
        ```

        Inline `#alsonot` too.
        """
        #expect(scanner.tags(in: text) == ["tag"])
        #expect(scanner.links(in: text).isEmpty)
    }

    @Test("A bare number is not a tag")
    func rejectsNumericTags() {
        #expect(scanner.tags(in: "See issue #1 and #v2release").sorted() == ["v2release"])
    }

    @Test("Recognises CJK tags")
    func supportsCJKTags() {
        #expect(scanner.tags(in: "今天读了 #读书笔记 很好") == ["读书笔记"])
    }

    @Test("Frontmatter contents are excluded from tags")
    func masksFrontmatter() {
        let text = "---\nsomething: \"#notatag\"\n---\n\n#real\n"
        #expect(scanner.tags(in: text) == ["real"])
    }

    @Test("Detects embeds separately from links")
    func detectsEmbeds() {
        let tokens = scanner.scan("![[diagram.png]] and [[Note]]")
        let embeds = tokens.filter { if case .embed = $0.kind { return true } else { return false } }
        let links = tokens.filter { if case .wikiLink = $0.kind { return true } else { return false } }
        #expect(embeds.count == 1)
        #expect(links.count == 1)
    }
}

@Suite("Note parsing")
struct NoteParsingTests {
    @Test("Title falls back from frontmatter to H1 to filename")
    func resolvesTitle() {
        let url = URL(fileURLWithPath: "/vault/My File.md")
        #expect(NoteParser.parse(text: "---\ntitle: From Frontmatter\n---\n# H1\n", url: url).title == "From Frontmatter")
        #expect(NoteParser.parse(text: "# From Heading\n", url: url).title == "From Heading")
        #expect(NoteParser.parse(text: "no heading\n", url: url).title == "My File")
    }

    @Test("Nested tags imply their ancestors")
    func expandsNestedTags() {
        let note = NoteParser.parse(text: "#project/inkstone/ui", url: URL(fileURLWithPath: "/v/a.md"))
        #expect(note.tags == ["project", "project/inkstone", "project/inkstone/ui"])
    }

    @Test("Word count treats CJK characters individually and Latin runs as words")
    func countsMixedScript() {
        #expect(NoteParser.wordCount(of: "hello world") == 2)
        #expect(NoteParser.wordCount(of: "你好世界") == 4)
        #expect(NoteParser.wordCount(of: "你好 world 世界") == 5)
    }
}

@Suite("Index")
struct IndexTests {
    let root = URL(fileURLWithPath: "/vault")

    private func note(_ path: String, text: String) -> NoteMetadata {
        NoteParser.parse(text: text, url: root.appending(path: path))
    }

    @Test("Resolves links and records backlinks")
    func buildsGraph() {
        let snapshot = IndexBuilder.assemble([
            note("A.md", text: "Link to [[B]]"),
            note("B.md", text: "# B"),
        ], vaultRoot: root)

        let b = root.appending(path: "B.md")
        #expect(snapshot.edges.count == 1)
        #expect(snapshot.edges[0].destination == b)
        #expect(snapshot.incoming(to: b).count == 1)
        #expect(snapshot.unresolved.isEmpty)
    }

    @Test("Records links to notes that don't exist")
    func tracksUnresolved() {
        let snapshot = IndexBuilder.assemble([note("A.md", text: "[[Ghost]] [[Ghost]]")], vaultRoot: root)
        #expect(snapshot.unresolved["Ghost"] == 2)
    }

    @Test("Aliases resolve to their note")
    func resolvesAliases() {
        let snapshot = IndexBuilder.assemble([
            note("A.md", text: "[[Second Name]]"),
            note("B.md", text: "---\naliases: [Second Name]\n---\n"),
        ], vaultRoot: root)
        #expect(snapshot.edges.first?.destination == root.appending(path: "B.md"))
    }

    @Test("Ambiguous names resolve to the nearest note")
    func prefersNearestOnAmbiguity() {
        let snapshot = IndexBuilder.assemble([
            note("work/Index.md", text: "[[Shared]]"),
            note("work/Shared.md", text: ""),
            note("personal/deep/nested/Shared.md", text: ""),
        ], vaultRoot: root)
        #expect(snapshot.edges.first?.destination == root.appending(path: "work/Shared.md"))
    }
}

@Suite("Search")
struct SearchTests {
    @Test("Fuzzy match requires a subsequence")
    func requiresSubsequence() {
        #expect(SearchEngine.fuzzyMatch(query: "abc", in: "a-b-c") != nil)
        #expect(SearchEngine.fuzzyMatch(query: "xyz", in: "a-b-c") == nil)
    }

    @Test("Word-start matches outrank scattered ones")
    func ranksWordStarts() {
        let good = SearchEngine.fuzzyMatch(query: "dn", in: "Daily Notes")!
        let poor = SearchEngine.fuzzyMatch(query: "dn", in: "Bidirectional Nonsense")!
        #expect(good.score > poor.score)
    }

    @Test("Exact matches win")
    func ranksExactHighest() {
        let exact = SearchEngine.fuzzyMatch(query: "notes", in: "notes")!
        let longer = SearchEngine.fuzzyMatch(query: "notes", in: "notes about notes")!
        #expect(exact.score > longer.score)
    }

    @Test("Query operators are parsed out of the terms")
    func parsesOperators() {
        let query = SearchQuery(raw: "tag:#book path:reading actual words")
        #expect(query.tags == ["book"])
        #expect(query.pathFragments == ["reading"])
        #expect(query.terms == ["actual", "words"])
    }
}

@Suite("Canvas")
struct CanvasTests {
    @Test("Round-trips through the JSON Canvas format")
    func roundTrips() throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "test-\(UUID().uuidString).canvas")
        defer { try? FileManager.default.removeItem(at: url) }

        var document = CanvasDocument()
        let a = CanvasNode(type: .text, x: 0, y: 0, width: 200, height: 100, text: "Hello")
        let b = CanvasNode(type: .file, x: 300, y: 0, width: 200, height: 100, file: "Note.md")
        document.nodes = [a, b]
        document.edges = [CanvasEdge(fromNode: a.id, toNode: b.id)]
        try document.save(to: url)

        let loaded = try CanvasDocument.load(from: url)
        #expect(loaded.nodes.count == 2)
        #expect(loaded.node(id: a.id)?.text == "Hello")
        #expect(loaded.edges.first?.toNode == b.id)
    }

    @Test("An empty file loads as an empty canvas")
    func handlesEmptyFile() throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "empty-\(UUID().uuidString).canvas")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data().write(to: url)
        #expect(try CanvasDocument.load(from: url).nodes.isEmpty)
    }

    @Test("Preset colours map to hex")
    func mapsPresetColors() {
        #expect(CanvasColor.preset(1).hexValue == "#D95C5C")
        #expect(CanvasColor.hex("#123456").hexValue == "#123456")
    }
}

@Suite("Link rewriting")
struct LinkRewriterTests {
    @Test("Renaming updates links but preserves fragments and aliases")
    func rewritesLinks() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = NoteStore(root: root)
        let source = root.appending(path: "Source.md")
        try store.write(
            "[[Old Name]] and [[Old Name#Heading|shown]] plus `[[Old Name]]` in code",
            to: source
        )

        let changed = LinkRewriter(store: store).rename(from: "Old Name", to: "New Name", in: [source])
        #expect(changed == [source])

        let result = try store.read(source)
        #expect(result.contains("[[New Name]]"))
        #expect(result.contains("[[New Name#Heading|shown]]"))
        // The occurrence inside inline code must be left alone.
        #expect(result.contains("`[[Old Name]]`"))
    }
}

@Suite("Graph")
struct GraphTests {
    @Test("Local graph keeps only neighbours within the given depth")
    func limitsDepth() {
        let data = GraphData(
            nodes: ["a", "b", "c", "d"].map { GraphNode(id: $0, kind: .unresolved($0), label: $0) },
            links: [
                GraphLink(source: "a", target: "b"),
                GraphLink(source: "b", target: "c"),
                GraphLink(source: "c", target: "d"),
            ]
        )
        #expect(Set(data.localGraph(around: "a", depth: 1).nodes.map(\.id)) == ["a", "b"])
        #expect(Set(data.localGraph(around: "a", depth: 2).nodes.map(\.id)) == ["a", "b", "c"])
    }

    @Test("Simulation is deterministic for a given seed")
    func isDeterministic() {
        let data = GraphData(
            nodes: (0..<20).map { GraphNode(id: "\($0)", kind: .tag("\($0)"), label: "\($0)") },
            links: (0..<19).map { GraphLink(source: "\($0)", target: "\($0 + 1)") }
        )
        var first = GraphSimulation(data: data, seed: 7)
        var second = GraphSimulation(data: data, seed: 7)
        for _ in 0..<30 {
            first.step(alpha: 0.5)
            second.step(alpha: 0.5)
        }
        #expect(first.position(of: "5") == second.position(of: "5"))
    }
}
