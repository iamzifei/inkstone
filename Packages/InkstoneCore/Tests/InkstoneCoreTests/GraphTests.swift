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
            includeUnresolved: true
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
            includeUnresolved: false
        )

        let ids = Set(data.nodes.map(\.id))
        // A spring pulling on a node that isn't in the layout would drag the
        // whole thumbnail off to one side.
        for link in data.links {
            #expect(ids.contains(link.source))
            #expect(ids.contains(link.target))
        }
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
            includeUnresolved: false
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
