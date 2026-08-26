import Testing
import Foundation
@testable import InkstoneCore

/// What the vault graph is *of*, and what it costs to lay out.
///
/// Both halves are regressions from the same report: on a vault of 8,844 notes
/// the graph tab froze the app, and the nodes it eventually drew were labelled
/// with headings out of the files rather than with the files.
@Suite("Vault graph")
struct VaultGraphTests {
    let root = URL(fileURLWithPath: "/vault")

    private func note(_ path: String, text: String) -> NoteMetadata {
        NoteParser.parse(text: text, url: root.appending(path: path))
    }

    private func build(
        _ notes: [NoteMetadata],
        filters: GraphData.Filters = GraphData.Filters(showTags: false)
    ) -> GraphData {
        GraphData.build(
            from: IndexBuilder.assemble(notes, vaultRoot: root),
            filters: filters,
            vaultRoot: root
        )
    }

    // MARK: - What the nodes are

    @Test("A node is named after its file, not after the first heading inside it")
    func labelsNodesWithFileNames() {
        // Both of these have a first-level heading that is *not* the file's name;
        // labelling by title made the graph read as a list of section headings.
        let data = build([
            note("选题装配模板.md", text: "# 选题装配：标题\n\nSee [[解答型口播稿模板]]."),
            note("解答型口播稿模板.md", text: "# 选题：\n"),
        ])

        #expect(Set(data.nodes.map(\.label)) == ["选题装配模板", "解答型口播稿模板"])
    }

    @Test("Two notes whose first headings match stay two distinguishable nodes")
    func keepsSameHeadingNotesApart() {
        let data = build([
            note("README.md", text: "# 内容结构化系统\n\n[[AGENTS]]"),
            note("AGENTS.md", text: "# 内容结构化系统\n"),
        ])

        #expect(Set(data.nodes.map(\.label)) == ["README", "AGENTS"])
    }

    @Test("Headings inside a note are not nodes")
    func doesNotGraphHeadings() {
        let data = build([
            note("One.md", text: """
            # One

            ## A section
            ### A subsection
            ## Another section
            """),
        ])

        #expect(data.nodes.count == 1)
        #expect(data.links.isEmpty)
    }

    @Test("An edge is a link from one note to another")
    func graphsLinksBetweenNotes() {
        let data = build([
            note("A.md", text: "[[B]] and [[Ghost]]"),
            note("B.md", text: ""),
        ])

        let a = "/vault/A.md"
        let b = "/vault/B.md"
        #expect(data.links.contains(GraphLink(source: a, target: b)))
        // The link to a note that doesn't exist yet is kept as a ghost node.
        #expect(data.nodes.contains { $0.label == "Ghost" })
    }

    // MARK: - Filters

    @Test("Orphans can be left out, and only notes count as orphans")
    func hidesOrphans() {
        let notes = [
            note("Linked.md", text: "[[Other]] #kept"),
            note("Other.md", text: ""),
            note("Alone.md", text: "nothing here"),
        ]
        let withOrphans = build(notes, filters: .init(showTags: true))
        let without = build(notes, filters: .init(showTags: true, showOrphans: false))

        #expect(Set(withOrphans.nodes.map(\.label)).contains("Alone"))
        #expect(!Set(without.nodes.map(\.label)).contains("Alone"))
        // Linked, Other and the #kept tag survive — a tag exists because a note
        // points at it, so it can never be an orphan.
        #expect(Set(without.nodes.map(\.label)) == ["Linked", "Other", "#kept"])
    }

    @Test("Existing files only drops the ghost nodes")
    func hidesUnresolved() {
        let notes = [note("A.md", text: "[[B]] and [[Ghost]]"), note("B.md", text: "")]

        #expect(build(notes).nodes.contains { $0.label == "Ghost" })
        #expect(!build(notes, filters: .init(showTags: false, showUnresolved: false))
            .nodes.contains { $0.label == "Ghost" })
    }

    @Test("An embed of a file that exists is an attachment, not a dead link")
    func separatesAttachmentsFromGhosts() {
        // `IndexSnapshot` only ever resolves `.md`, so an embedded png arrives
        // looking unresolved. The attachment index is what tells them apart.
        let tree = FileNode(
            url: root,
            isDirectory: true,
            children: [FileNode(url: root.appending(path: "diagram.png"), isDirectory: false)]
        )
        let notes = [note("A.md", text: "![[diagram.png]] and [[Ghost]]")]
        let snapshot = IndexBuilder.assemble(notes, vaultRoot: root)

        let hidden = GraphData.build(
            from: snapshot,
            attachments: AttachmentIndex(tree: tree),
            filters: .init(showTags: false, showAttachments: false),
            vaultRoot: root
        )
        // The png is gone; the genuinely dead link is not.
        #expect(!hidden.nodes.contains { $0.label == "diagram.png" })
        #expect(hidden.nodes.contains { $0.label == "Ghost" })

        let shown = GraphData.build(
            from: snapshot,
            attachments: AttachmentIndex(tree: tree),
            filters: .init(showTags: false, showAttachments: true),
            vaultRoot: root
        )
        #expect(shown.nodes.contains { $0.label == "diagram.png" })
        #expect(shown.nodes.contains { if case .attachment = $0.kind { true } else { false } })
    }

    @Test("The search box narrows the graph to matching files")
    func filtersBySearch() {
        let notes = [
            note("work/Plan.md", text: "[[work/Notes]]"),
            note("work/Notes.md", text: ""),
            note("personal/Diary.md", text: ""),
        ]
        let data = build(notes, filters: .init(search: "work", showTags: false))

        #expect(Set(data.nodes.map(\.label)) == ["Plan", "Notes"])
        // And a link whose source was filtered out is not drawn either.
        #expect(build(notes, filters: .init(search: "Diary", showTags: false)).links.isEmpty)
    }

    // MARK: - Colour groups

    @Test("A group colours every node its query matches")
    func assignsColourGroups() {
        let notes = [
            note("work/Plan.md", text: "#project"),
            note("personal/Diary.md", text: ""),
        ]
        let snapshot = IndexBuilder.assemble(notes, vaultRoot: root)
        let data = GraphData.build(from: snapshot, filters: .init(showTags: true), vaultRoot: root)

        let membership = data.groupMembership(queries: ["work", "tag:project"], snapshot: snapshot)
        let byLabel = Dictionary(uniqueKeysWithValues: zip(data.nodes.map(\.label), membership))

        #expect(byLabel["Plan"] == 0)          // first matching query wins
        #expect(byLabel["#project"] == 1)
        #expect(byLabel["Diary"] == .some(nil))
    }

    @Test("An empty group query captures nothing")
    func ignoresEmptyGroupQueries() {
        let notes = [note("A.md", text: "")]
        let snapshot = IndexBuilder.assemble(notes, vaultRoot: root)
        let data = GraphData.build(from: snapshot, filters: .init(showTags: false), vaultRoot: root)

        // A group that has just been added has no query yet; it must not turn
        // the whole graph its colour while someone is still typing.
        #expect(data.groupMembership(queries: ["  "], snapshot: snapshot) == [nil])
    }

    // MARK: - Determinism

    @Test("The same vault produces the same node order every time")
    func ordersNodesStably() {
        // `nodes` used to come straight out of a dictionary, whose iteration
        // order is seeded per process — so the seeded PRNG handed the *same*
        // starting position to a different note on every launch and the layout
        // moved between runs anyway. Sorting is what actually makes it stable.
        let notes = (0..<50).map { note("note-\($0).md", text: "[[note-\(($0 + 1) % 50)]]") }
        let first = build(notes)
        let second = build(notes.shuffled())

        #expect(first.nodes.map(\.id) == second.nodes.map(\.id))
        #expect(first.links == second.links)
    }

    // MARK: - The local graph

    @Test("The local graph is the neighbourhood of one note")
    func buildsLocalGraphFromIndex() {
        let snapshot = IndexBuilder.assemble([
            note("Centre.md", text: "[[Out]] and [[Ghost]]"),
            note("In.md", text: "[[Centre]]"),
            note("Out.md", text: ""),
            note("Far.md", text: "[[Out]]"),
            note("Unrelated.md", text: ""),
        ], vaultRoot: root)

        let data = GraphData.local(
            from: snapshot,
            around: root.appending(path: "Centre.md"),
            depth: 1,
            filters: .init(showTags: false, showUnresolved: true),
            vaultRoot: root
        )

        let labels = Set(data.nodes.map(\.label))
        // One hop: what Centre links to, what links to Centre, and its ghosts.
        #expect(labels == ["Centre", "In", "Out", "Ghost"])
        // Two hops away, and not connected to Centre at all.
        #expect(!labels.contains("Far"))
        #expect(!labels.contains("Unrelated"))
    }

    @Test("The local graph keeps no link whose far end was left out")
    func dropsDanglingLocalLinks() {
        let snapshot = IndexBuilder.assemble([
            note("Centre.md", text: "[[Out]]"),
            note("Out.md", text: "[[Beyond]]"),
            note("Beyond.md", text: ""),
        ], vaultRoot: root)

        let data = GraphData.local(
            from: snapshot,
            around: root.appending(path: "Centre.md"),
            depth: 1,
            filters: .init(showTags: false, showUnresolved: false),
            vaultRoot: root
        )

        let ids = Set(data.nodes.map(\.id))
        // A spring pulling on a node that isn't in the layout would drag the
        // whole thumbnail off to one side.
        for link in data.links {
            #expect(ids.contains(link.source))
            #expect(ids.contains(link.target))
        }
    }

    @Test("Depth decides how many rings out the local graph reaches")
    func honoursLocalDepth() {
        // Centre → Out → Beyond → Further: one chain, so each extra hop should
        // add exactly one more note.
        let snapshot = IndexBuilder.assemble([
            note("Centre.md", text: "[[Out]]"),
            note("Out.md", text: "[[Beyond]]"),
            note("Beyond.md", text: "[[Further]]"),
            note("Further.md", text: ""),
        ], vaultRoot: root)

        func labels(depth: Int) -> Set<String> {
            Set(GraphData.local(
                from: snapshot,
                around: root.appending(path: "Centre.md"),
                depth: depth,
                filters: .init(showTags: false),
                vaultRoot: root
            ).nodes.map(\.label))
        }

        #expect(labels(depth: 1) == ["Centre", "Out"])
        #expect(labels(depth: 2) == ["Centre", "Out", "Beyond"])
        #expect(labels(depth: 3) == ["Centre", "Out", "Beyond", "Further"])
    }

    @Test("The local graph keeps its own note however the search is set")
    func alwaysKeepsTheFocus() {
        let snapshot = IndexBuilder.assemble([
            note("Centre.md", text: "[[Out]]"),
            note("Out.md", text: ""),
        ], vaultRoot: root)

        let data = GraphData.local(
            from: snapshot,
            around: root.appending(path: "Centre.md"),
            depth: 1,
            filters: .init(search: "nothing-matches-this", showTags: false),
            vaultRoot: root
        )

        // A local graph of a note that filtered itself out is an empty box with
        // no explanation of why.
        #expect(data.nodes.map(\.label) == ["Centre"])
    }

    @Test("The local graph shows tags when the filter asks for them")
    func showsTagsLocally() {
        let snapshot = IndexBuilder.assemble([
            note("Centre.md", text: "#project [[Out]]"),
            note("Out.md", text: ""),
        ], vaultRoot: root)

        func labels(showTags: Bool) -> Set<String> {
            Set(GraphData.local(
                from: snapshot,
                around: root.appending(path: "Centre.md"),
                depth: 1,
                filters: .init(showTags: showTags),
                vaultRoot: root
            ).nodes.map(\.label))
        }

        #expect(labels(showTags: false) == ["Centre", "Out"])
        #expect(labels(showTags: true) == ["Centre", "Out", "#project"])
    }

    @Test("The local graph excludes unresolved links when asked to")
    func honoursUnresolvedFilterLocally() {
        let snapshot = IndexBuilder.assemble([
            note("Centre.md", text: "[[Ghost]]"),
        ], vaultRoot: root)

        let data = GraphData.local(
            from: snapshot,
            around: root.appending(path: "Centre.md"),
            depth: 1,
            filters: .init(showTags: false, showUnresolved: false),
            vaultRoot: root
        )

        #expect(data.nodes.map(\.label) == ["Centre"])
    }
}

/// The layout's cost, measured by shape rather than by a stopwatch.
///
/// **Nothing here asserts a millisecond figure**, for the reason spelled out in
/// `ScannerPerformanceTests`: absolute times are a property of the build, not of
/// the code. Measured on the same machine on the same day, one frame of the
/// 8,844-node vault costs
///
///     debug    246 ms
///     release  5.2 ms
///
/// Before the Barnes–Hut rewrite the release figure was **3,993 ms** — and it ran
/// on the main thread inside the drawing closure, which is what made opening the
/// graph tab hang the window. The number that protects against that coming back
/// is not a ceiling but `staysSubQuadratic`: the old layout compared every node
/// with every other, and no amount of constant-factor tuning fixes that shape.
@Suite("Graph layout performance")
struct GraphPerformanceTests {
    /// A ring plus a scattering of chords: connected enough to have structure,
    /// sparse enough to look like a real vault, where most notes link to one or
    /// two others and plenty link to nothing.
    static func synthetic(nodes count: Int) -> GraphData {
        var nodes: [GraphNode] = []
        var links: [GraphLink] = []
        for index in 0..<count {
            nodes.append(GraphNode(id: "/vault/note-\(index).md", kind: .unresolved("n\(index)"), label: "n\(index)"))
        }
        for index in 0..<count {
            links.append(GraphLink(
                source: "/vault/note-\(index).md",
                target: "/vault/note-\((index * 7 + 3) % count).md"
            ))
            if index.isMultiple(of: 2) {
                links.append(GraphLink(
                    source: "/vault/note-\(index).md",
                    target: "/vault/note-\((index * 13 + 11) % count).md"
                ))
            }
        }
        return GraphData(nodes: nodes, links: links)
    }

    private static func frameCost(nodes: Int, frames: Int = 5) -> Double {
        var simulation = GraphSimulation(data: synthetic(nodes: nodes))
        // One warm-up frame: the first builds the quadtree from scratch into an
        // array that later frames reserve against.
        simulation.step(alpha: 1)
        let start = Date()
        for _ in 0..<frames { simulation.step(alpha: 1) }
        return Date().timeIntervalSince(start) / Double(frames) * 1000
    }

    @Test("Cost is near-linear in node count, not quadratic")
    func staysSubQuadratic() {
        let small = Self.frameCost(nodes: 1_000)
        let large = Self.frameCost(nodes: 8_000)
        let ratio = large / small

        print(String(format: "layout frame: 1k %.2f ms | 8k %.2f ms | %.1f×", small, large, ratio))

        // Eight times the nodes. All-pairs would be ~64×; n log n is ~9.6×. The
        // ceiling is set well above that and well below quadratic, so it catches
        // a return to all-pairs without failing on a noisy machine.
        #expect(ratio < 20)
    }

    @Test("Two nodes on top of each other do not shove each other off the map")
    func boundsCloseRangeRepulsion() {
        // Repulsion goes as 1/d³, and used to have no floor above a hundredth of
        // a unit: a pair that close pushed each other at the velocity clamp, and
        // then kept doing it — 60 units a frame, every frame, for the whole run.
        // On the vault this was found on (9,350 nodes) twelve of them finished
        // 14,000 out from a graph whose 99th percentile was 1,685, so "fit on
        // screen" framed a dozen stragglers and squashed the real graph into a
        // speck in the corner.
        let data = GraphData(
            nodes: [
                GraphNode(id: "a", kind: .unresolved("a"), label: "a"),
                GraphNode(id: "b", kind: .unresolved("b"), label: "b"),
            ],
            links: []
        )
        var simulation = GraphSimulation(data: data)
        simulation.pin("a", at: SIMD2(0, 0))
        simulation.pin("b", at: SIMD2(0.001, 0))
        simulation.unpin("a")
        simulation.unpin("b")

        simulation.step(alpha: 1)

        // Treated as `minimumSeparation` apart, the pair moves 38.4 units in the
        // first frame. Without the floor the force is effectively infinite, the
        // 60-unit velocity clamp is the only thing left holding them, and they
        // travel exactly 60 — every frame, in the same direction, for ever.
        for position in simulation.positions {
            let travelled = (position.x * position.x + position.y * position.y).squareRoot()
            #expect(travelled < 55)
            // And they do move apart: a floor that stopped repulsion entirely
            // would let coincident nodes sit on top of each other.
            #expect(travelled > 1)
        }
    }

    @Test("A large graph settles into a spread-out layout rather than a knot")
    func spreadsOut() {
        let count = 4_000
        var simulation = GraphSimulation(data: Self.synthetic(nodes: count))
        var alpha = 1.0
        while alpha > 0.02 {
            simulation.step(alpha: alpha)
            alpha *= 0.97
        }

        var low = simulation.positions[0]
        var high = simulation.positions[0]
        for position in simulation.positions {
            low.x = min(low.x, position.x)
            low.y = min(low.y, position.y)
            high.x = max(high.x, position.x)
            high.y = max(high.y, position.y)
        }
        let width = high.x - low.x
        let height = high.y - low.y

        // Finite, and big enough that the nodes are not piled on top of each
        // other: with a starting cloud that scaled with the node count and true
        // long-range repulsion, thousands of nodes need thousands of units.
        #expect(width.isFinite && height.isFinite)
        #expect(width > 1_000)
        #expect(height > 1_000)
        // And not flung to infinity by an unstable integration step.
        #expect(width < 1_000_000)
    }
}

/// Frontmatter is shown as a properties table at the top of the note, so the
/// order the rows come out in is the order the author wrote them.
@Suite("Note properties")
struct NotePropertiesTests {
    @Test("Property rows keep the order they were written in")
    func keepsFileOrder() {
        // `Frontmatter.properties` is a dictionary, and Swift seeds its hashing
        // per process — so reading `keys` directly would reorder someone's own
        // table differently on every launch. The order comes from the source.
        let source = """
        ---
        status: draft
        aliases: [第二个名字]
        tags: [对标, 采集]
        配套: 对标采集-爬虫需求.md
        ---
        """
        let (frontmatter, _) = FrontmatterParser.parse(source)
        #expect(NotePropertyOrder.keys(of: frontmatter, in: source)
                == ["status", "aliases", "tags", "配套"])
    }

    @Test("A list value indented under its key is still one property")
    func handlesBlockLists() {
        let source = """
        ---
        tags:
          - 对标
          - 采集
        title: A note
        ---
        """
        let (frontmatter, _) = FrontmatterParser.parse(source)
        // The `- 对标` lines belong to `tags`; they are not properties of their own.
        #expect(NotePropertyOrder.keys(of: frontmatter, in: source) == ["tags", "title"])
    }

    @Test("A key the line scan misses is still listed, not dropped")
    func doesNotDropQuotedKeys() {
        let source = """
        ---
        "quoted key": yes
        plain: no
        ---
        """
        let (frontmatter, _) = FrontmatterParser.parse(source)
        let keys = NotePropertyOrder.keys(of: frontmatter, in: source)
        #expect(Set(keys) == Set(frontmatter.properties.keys))
    }
}

/// Plain file paths written in prose become links, so an index note's rows can
/// be clicked instead of read out and typed into the switcher.
@Suite("Vault path detection")
struct VaultPathDetectorTests {
    private func found(in text: String) -> [String] {
        VaultPathDetector.candidates(in: text).map {
            (text as NSString).substring(with: $0)
        }
    }

    @Test("A path in prose is found, whatever punctuation is against it")
    func findsPathsInProse() {
        #expect(found(in: "见 _已发布/已发布内容库.md 那一条") == ["_已发布/已发布内容库.md"])
        // CJK punctuation sits straight up against the path with no space, so a
        // space-only split would swallow the closing bracket into the file name.
        #expect(found(in: "（见 06-选题装配/选题池.md）") == ["06-选题装配/选题池.md"])
        #expect(found(in: "`01-原始素材区/知识库/10-Polanyi.md`") == ["01-原始素材区/知识库/10-Polanyi.md"])
    }

    @Test("Two paths on one line are both found")
    func findsSeveral() {
        #expect(found(in: "a/b.md 和 c/d.canvas") == ["a/b.md", "c/d.canvas"])
    }

    @Test("Things that merely contain a dot are left alone")
    func ignoresNonPaths() {
        // Prose is full of these, and offering every one as a file would turn a
        // paragraph into a field of false links.
        #expect(found(in: "版本 v3.2 发布于 1966. 见 google.com 与 3.14") == [])
        #expect(found(in: "https://example.com/a.md") == [])
        #expect(found(in: ".md") == [])
    }

    @Test("Absolute paths are candidates now; whether they are inside is asked later")
    func offersAbsolutePaths() {
        // This assertion is the reverse of what it used to be, deliberately.
        // The detector rejected anything starting `/` or `~` on the stated
        // grounds that it was "outside the vault" — an assumption that is wrong
        // exactly when someone writes out where a file in their vault lives,
        // which is the case where a link helps most.
        //
        // Deciding what is inside needs the vault root, which this function does
        // not have, so it now offers the candidate and `vaultRelative` refuses
        // the ones that point elsewhere.
        #expect(found(in: "/etc/hosts.md") == ["/etc/hosts.md"])
        #expect(found(in: "~/notes/a.md") == ["~/notes/a.md"])

        let root = URL(fileURLWithPath: "/vault")
        #expect(VaultPathDetector.vaultRelative("/etc/hosts.md", vaultRoot: root) == nil)
        #expect(VaultPathDetector.vaultRelative("/vault/a.md", vaultRoot: root) == "a.md")
    }

    @Test("Ranges are UTF-16, so CJK and emoji do not shift them")
    func returnsUTF16Ranges() {
        let text = "前面的中文📌 docs/plan.md 后面"
        let ranges = VaultPathDetector.candidates(in: text)
        #expect(ranges.count == 1)
        // The proof that the offsets are right: slicing the NSString by the
        // range gives the path back.
        #expect((text as NSString).substring(with: ranges[0]) == "docs/plan.md")
    }
}

/// The path scan runs on every highlight pass, so its cost has to be linear in
/// the text and small enough not to be felt while typing.
@Suite("Vault path detection performance")
struct VaultPathDetectorPerformanceTests {
    static func document(paragraphs: Int) -> String {
        (0..<paragraphs).map { index in
            """
            这是第 \(index) 段，提到 docs/plans/note-\(index).md 与 assets/shot-\(index).png，
            还有一些不该被当成路径的东西：v3.\(index)、1966. 与 example.com。
            """
        }.joined(separator: "\n\n")
    }

    @Test("Cost is linear in document size, not quadratic")
    func staysLinear() {
        func cost(_ paragraphs: Int) -> Double {
            let text = Self.document(paragraphs: paragraphs)
            let start = Date()
            for _ in 0..<5 { _ = VaultPathDetector.candidates(in: text) }
            return Date().timeIntervalSince(start) / 5 * 1000
        }
        let small = cost(200)
        let large = cost(800)

        print(String(format: "path scan: 200¶ %.2f ms | 800¶ %.2f ms | %.1f×", small, large, large / small))
        // Four times the text. Linear is 4×; the ceiling leaves room for a noisy
        // machine and still catches a return to anything quadratic.
        #expect(large / small < 10)
    }

    @Test("Every path in the document is found")
    func findsThemAll() {
        let text = Self.document(paragraphs: 50)
        // Two per paragraph, and none of the decoys.
        #expect(VaultPathDetector.candidates(in: text).count == 100)
    }
}

/// `outgoing(from:)` is a dictionary lookup now, not a filter over every edge.
@Suite("Outgoing link index")
struct OutgoingLinkIndexTests {
    let root = URL(fileURLWithPath: "/vault")

    private func note(_ path: String, text: String) -> NoteMetadata {
        NoteParser.parse(text: text, url: root.appending(path: path))
    }

    @Test("It returns exactly what filtering the edges would have")
    func matchesTheOldFilter() {
        // The property that matters when replacing an implementation: the new
        // one answers the same question. Checked for *every* note, including the
        // ones with no outgoing links at all.
        let snapshot = IndexBuilder.assemble([
            note("A.md", text: "[[B]] then [[C]] then [[Ghost]] and [[B]] again"),
            note("B.md", text: "[[C]]"),
            note("C.md", text: "no links here"),
            note("D.md", text: "[Markdown](C.md)"),
        ], vaultRoot: root)

        for url in snapshot.notes.keys {
            #expect(snapshot.outgoing(from: url) == snapshot.edges.filter { $0.source == url })
        }
    }

    @Test("Order within a note is document order")
    func keepsDocumentOrder() {
        // The inspector lists outgoing links, and a list that reorders itself
        // between openings of the same note is worse than an unsorted one.
        let snapshot = IndexBuilder.assemble([
            note("A.md", text: "[[First]] [[Second]] [[Third]]"),
        ], vaultRoot: root)
        let targets = snapshot.outgoing(from: root.appending(path: "A.md")).map(\.unresolvedTarget)
        #expect(targets == ["First", "Second", "Third"])
    }

    @Test("A note nothing links out of returns empty, not nil-ish nonsense")
    func handlesNotesWithNoLinks() {
        let snapshot = IndexBuilder.assemble([note("Alone.md", text: "plain")], vaultRoot: root)
        #expect(snapshot.outgoing(from: root.appending(path: "Alone.md")).isEmpty)
        #expect(snapshot.outgoing(from: root.appending(path: "DoesNotExist.md")).isEmpty)
    }
}

/// Paths written as prose, now that they are links rather than decoration.
///
/// The reported symptoms were three, and two of them had one cause: an absolute
/// path was never clickable anywhere, and a note joined to another by a dozen
/// path references stood alone in the graph. The detector was only ever called
/// by the editor's highlighter — never by the index, so no edge existed, and
/// never by reading mode, so nothing was clickable there.
@Suite("Paths as links")
struct PathLinkTests {
    let root = URL(fileURLWithPath: "/vault")

    private func note(_ path: String, text: String = "") -> NoteMetadata {
        NoteParser.parse(text: text, url: root.appending(path: path))
    }

    // MARK: - Absolute paths

    @Test("An absolute path inside the vault becomes a vault-relative one")
    func acceptsAbsolutePathsInside() {
        // The case that was rejected outright, on the assumption that a leading
        // slash means "outside". A note recording where something lives writes
        // the whole path, and that file is very much inside.
        #expect(VaultPathDetector.vaultRelative("/vault/_published/index.md", vaultRoot: root)
                == "_published/index.md")
    }

    @Test("An absolute path outside the vault is refused")
    func refusesAbsolutePathsOutside() {
        #expect(VaultPathDetector.vaultRelative("/etc/passwd.md", vaultRoot: root) == nil)
        // A sibling directory whose name merely starts the same way. String
        // prefixing without the separator would accept this.
        #expect(VaultPathDetector.vaultRelative("/vault-backup/a.md", vaultRoot: root) == nil)
    }

    @Test("A relative path passes through untouched")
    func passesRelativePathsThrough() {
        #expect(VaultPathDetector.vaultRelative("_drafts/pool.md", vaultRoot: root)
                == "_drafts/pool.md")
    }

    @Test("A tilde path is expanded before being judged")
    func expandsTilde() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let vault = home.appending(path: "notes")
        #expect(VaultPathDetector.vaultRelative("~/notes/a.md", vaultRoot: vault) == "a.md")
    }

    @Test("An absolute path is now path-like at all")
    func recognisesAbsolutePaths() {
        #expect(VaultPathDetector.isPathLike("/Users/j/vault/a.md"))
        #expect(VaultPathDetector.isPathLike("~/vault/a.md"))
        // Still not a URL.
        #expect(!VaultPathDetector.isPathLike("https://example.com/a.md"))
    }

    // MARK: - The index

    @Test("A path in prose is an edge in the graph")
    func makesAnEdge() {
        // The reported symptom: a note referring to three files by path showed
        // as an isolated dot.
        let source = note("N20.md", text: """
            对照 `/vault/_published/index.md` 与 `_drafts/pool.md`。
            """)
        let snapshot = IndexBuilder.assemble(
            [source, note("_published/index.md"), note("_drafts/pool.md")], vaultRoot: root)

        let targets = Set(snapshot.outgoing(from: source.url).compactMap(\.destination))
        #expect(targets == [root.appending(path: "_published/index.md"),
                            root.appending(path: "_drafts/pool.md")])
    }

    @Test("The destination gets a backlink")
    func makesABacklink() {
        let source = note("N20.md", text: "见 `_drafts/pool.md`")
        let target = note("_drafts/pool.md")
        let snapshot = IndexBuilder.assemble([source, target], vaultRoot: root)
        #expect(snapshot.backlinks[target.url]?.map(\.source) == [source.url])
    }

    @Test("A path pointing nowhere makes no edge and no noise")
    func ignoresUnresolvedPaths() {
        // Unlike a wikilink, which is a note waiting to be written, a path that
        // resolves to nothing is usually prose that happened to look like one.
        let source = note("N20.md", text: "参考 `_drafts/absent.md` 和 v3.2 与 google.com")
        let snapshot = IndexBuilder.assemble([source], vaultRoot: root)
        #expect(snapshot.outgoing(from: source.url).isEmpty)
        #expect(snapshot.unresolved.isEmpty)
    }

    @Test("A note that names its own file does not link to itself")
    func ignoresSelfReferences() {
        // The reported note opens by saying its own filename is out of date.
        // A self-loop would put a stray edge on every such note.
        let source = note("N20.md", text: "文件名仍是旧名（`N20.md`）")
        let snapshot = IndexBuilder.assemble([source], vaultRoot: root)
        #expect(snapshot.outgoing(from: source.url).isEmpty)
    }

    @Test("Paths inside backticks count, because that is how paths are written")
    func findsPathsInsideCode() {
        let source = note("A.md", text: "对照 `_drafts/pool.md`，按核心结论比对")
        #expect(source.pathTargets.contains("_drafts/pool.md"))
    }

    // MARK: - Reading mode

    @Test("Reading mode links a path only when it resolves")
    func linksResolvablePathsOnly() {
        let document = ReadingRenderer.render(
            "对照 `_drafts/pool.md` 和 `_drafts/absent.md`",
            isLinkable: { $0 == "_drafts/pool.md" })
        let links = document.spans.compactMap { span -> String? in
            if case .link(let target) = span.style { return target }
            return nil
        }
        #expect(links == ["_drafts/pool.md"])
    }

    @Test("By default reading mode invents no links at all")
    func inventsNothingByDefault() {
        // The default predicate says "no", so a caller without the vault gets a
        // document with no fabricated destinations.
        let document = ReadingRenderer.render("见 `_drafts/pool.md`")
        #expect(!document.spans.contains { if case .link = $0.style { return true }; return false })
    }

    @Test("A path in a code block is a sample, not a destination")
    func skipsCodeBlocks() {
        let document = ReadingRenderer.render("""
            ```sh
            cat _drafts/pool.md
            ```
            """, isLinkable: { _ in true })
        #expect(!document.spans.contains { if case .link = $0.style { return true }; return false })
    }

    @Test("A path linked by Markdown is not linked twice")
    func doesNotDoubleLink() {
        let document = ReadingRenderer.render("[池](_drafts/pool.md)", isLinkable: { _ in true })
        let links = document.spans.filter { if case .link = $0.style { return true }; return false }
        #expect(links.count == 1)
    }

    @Test("Linking a path does not change a single character of the text")
    func changesNoText() {
        // The property that matters most: this pass adds spans, and a span is a
        // range over text that must still say what it said.
        let markdown = "对照 `/vault/_published/index.md` + `06-选题装配/` 各池"
        let plain = ReadingRenderer.render(markdown)
        let linked = ReadingRenderer.render(markdown, isLinkable: { _ in true })
        #expect(plain.text == linked.text)
    }
}
