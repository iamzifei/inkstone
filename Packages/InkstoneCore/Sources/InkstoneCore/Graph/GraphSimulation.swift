import Foundation

public struct GraphNode: Identifiable, Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case note(URL)
        case unresolved(String)
        case tag(String)
        case attachment(URL)
    }

    public let id: String
    public let kind: Kind
    public let label: String
    /// Number of connections; drives node radius so hubs read as hubs.
    public var degree: Int = 0

    public init(id: String, kind: Kind, label: String, degree: Int = 0) {
        self.id = id
        self.kind = kind
        self.label = label
        self.degree = degree
    }
}

public struct GraphLink: Hashable, Sendable {
    public let source: String
    public let target: String
    public init(source: String, target: String) {
        self.source = source
        self.target = target
    }
}

public struct GraphData: Sendable {
    public var nodes: [GraphNode]
    public var links: [GraphLink]

    public init(nodes: [GraphNode] = [], links: [GraphLink] = []) {
        self.nodes = nodes
        self.links = links
    }

    /// Everything the graph pane can filter on, in Obsidian's own vocabulary so
    /// a setting means the same thing in both apps.
    public struct Filters: Sendable, Equatable {
        /// Free text. Plain words match a note's path; `tag:` matches a tag —
        /// the same syntax the search pane takes.
        public var search: String
        public var showTags: Bool
        public var showAttachments: Bool
        /// Obsidian words this the other way round, as "Existing files only".
        public var showUnresolved: Bool
        /// Notes with nothing linking to or from them. Most vaults are mostly
        /// orphans, so this decides whether the graph is a map or a dust cloud.
        public var showOrphans: Bool

        public init(
            search: String = "",
            showTags: Bool = true,
            showAttachments: Bool = false,
            showUnresolved: Bool = true,
            showOrphans: Bool = true
        ) {
            self.search = search
            self.showTags = showTags
            self.showAttachments = showAttachments
            self.showUnresolved = showUnresolved
            self.showOrphans = showOrphans
        }
    }

    /// Builds the graph from an index snapshot, honouring the user's filters.
    ///
    /// This is the *vault* graph: one node per note, one edge per link between
    /// notes. Headings inside a note are not nodes — a note is a single point
    /// here however it is structured internally.
    public static func build(
        from snapshot: IndexSnapshot,
        attachments: AttachmentIndex = AttachmentIndex(),
        filters: Filters,
        vaultRoot: URL
    ) -> GraphData {
        var nodes: [String: GraphNode] = [:]
        var links: Set<GraphLink> = []

        let query = SearchQuery(raw: filters.search)

        for (url, note) in snapshot.notes where query.matchesWithoutBody(note) {
            let id = url.path(percentEncoded: false)
            nodes[id] = GraphNode(id: id, kind: .note(url), label: label(for: note))
        }

        for edge in snapshot.edges {
            let sourceID = edge.source.path(percentEncoded: false)
            // A link out of a note the search excluded is not a link at all.
            guard nodes[sourceID] != nil else { continue }

            if let destination = edge.destination {
                let targetID = destination.path(percentEncoded: false)
                guard sourceID != targetID, nodes[targetID] != nil else { continue }
                links.insert(GraphLink(source: sourceID, target: targetID))
                continue
            }
            guard !edge.unresolvedTarget.isEmpty else { continue }

            // An embed of a file that exists is an attachment, not a dead link.
            // `IndexSnapshot` only ever resolves `.md`, so `![[diagram.png]]`
            // arrives here looking unresolved; the attachment index is what
            // tells the two apart.
            if let file = attachments.resolve(edge.unresolvedTarget, from: edge.source, vaultRoot: vaultRoot) {
                guard filters.showAttachments else { continue }
                let targetID = file.path(percentEncoded: false)
                nodes[targetID] = GraphNode(
                    id: targetID,
                    kind: .attachment(file),
                    label: file.lastPathComponent
                )
                links.insert(GraphLink(source: sourceID, target: targetID))
            } else if filters.showUnresolved {
                let targetID = "unresolved:" + edge.unresolvedTarget.lowercased()
                nodes[targetID] = GraphNode(
                    id: targetID,
                    kind: .unresolved(edge.unresolvedTarget),
                    label: edge.unresolvedTarget
                )
                links.insert(GraphLink(source: sourceID, target: targetID))
            }
        }

        if filters.showTags {
            for (url, note) in snapshot.notes {
                let sourceID = url.path(percentEncoded: false)
                guard nodes[sourceID] != nil else { continue }
                for tag in note.tags {
                    let tagID = "tag:" + tag
                    nodes[tagID] = GraphNode(id: tagID, kind: .tag(tag), label: "#" + tag)
                    links.insert(GraphLink(source: sourceID, target: tagID))
                }
            }
        }

        // Degree drives visual weight.
        for link in links {
            nodes[link.source]?.degree += 1
            nodes[link.target]?.degree += 1
        }

        if !filters.showOrphans {
            // Only notes can be orphans: a tag or a ghost link exists *because*
            // something points at it, so one with no edges cannot occur.
            nodes = nodes.filter { _, node in
                if case .note = node.kind { return node.degree > 0 }
                return true
            }
        }

        // Sorted, not `Array(nodes.values)`. Dictionary iteration order is seeded
        // per process, and the simulation hands out its starting positions in
        // node order — so an unsorted array laid the same vault out differently
        // on every launch, which the seeded PRNG was supposed to prevent.
        return GraphData(
            nodes: nodes.values.sorted { $0.id < $1.id },
            links: links.sorted { ($0.source, $0.target) < ($1.source, $1.target) }
        )
    }

    /// For each node, the index of the first group query it matches, or nil.
    ///
    /// Parallel to `nodes`, so the drawing loop can look a colour up by slot
    /// without hashing anything. Queries are the search pane's: plain words
    /// match the path, `tag:` matches a tag.
    public func groupMembership(queries: [String], snapshot: IndexSnapshot) -> [Int?] {
        let parsed = queries.map { (raw: $0, query: SearchQuery(raw: $0)) }
        return nodes.map { node in
            parsed.firstIndex { candidate in
                // An empty query is a group still being written; it should not
                // silently capture the whole graph.
                guard !candidate.raw.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
                return matches(node, candidate.query, snapshot: snapshot)
            }
        }
    }

    private func matches(_ node: GraphNode, _ query: SearchQuery, snapshot: IndexSnapshot) -> Bool {
        switch node.kind {
        case .note(let url):
            guard let note = snapshot.metadata(for: url) else { return false }
            return query.matchesWithoutBody(note)
        case .tag(let tag):
            // `tag:project` catches `#project/inkstone` the same way it does for
            // a note; a bare word matches the tag's own text.
            guard query.pathFragments.isEmpty else { return false }
            let byOperator = query.tags.allSatisfy { tag == $0 || tag.hasPrefix($0 + "/") }
            let byText = query.terms.allSatisfy { tag.localizedCaseInsensitiveContains($0) }
            return byOperator && byText && !(query.tags.isEmpty && query.terms.isEmpty)
        case .unresolved(let name):
            guard query.tags.isEmpty else { return false }
            let text = query.terms + query.pathFragments
            return !text.isEmpty && text.allSatisfy { name.localizedCaseInsensitiveContains($0) }
        case .attachment(let url):
            guard query.tags.isEmpty else { return false }
            let path = url.path(percentEncoded: false)
            let text = query.terms + query.pathFragments
            return !text.isEmpty && text.allSatisfy { path.localizedCaseInsensitiveContains($0) }
        }
    }

    /// The neighbourhood of one note, built straight from the index.
    ///
    /// The inspector's local graph used to build the *whole* vault graph and
    /// then throw all but a handful of nodes away — on every note it opened. On
    /// a vault of a few thousand notes that is seconds of work per click for a
    /// thumbnail showing five circles.
    public static func local(
        from snapshot: IndexSnapshot,
        around url: URL,
        depth: Int,
        includeUnresolved: Bool
    ) -> GraphData {
        var visited: Set<URL> = [url]
        var frontier: [URL] = [url]
        /// Unresolved targets are leaves — they have no links of their own to
        /// follow — so they are collected separately and never expanded.
        var unresolved: Set<String> = []
        var links: Set<GraphLink> = []

        func id(_ url: URL) -> String { url.path(percentEncoded: false) }

        for _ in 0..<max(1, depth) {
            var next: [URL] = []
            for note in frontier {
                for edge in snapshot.outgoing(from: note) {
                    if let destination = edge.destination {
                        guard destination != note else { continue }
                        links.insert(GraphLink(source: id(note), target: id(destination)))
                        if visited.insert(destination).inserted { next.append(destination) }
                    } else if includeUnresolved, !edge.unresolvedTarget.isEmpty {
                        unresolved.insert(edge.unresolvedTarget)
                        links.insert(GraphLink(
                            source: id(note),
                            target: "unresolved:" + edge.unresolvedTarget.lowercased()
                        ))
                    }
                }
                for edge in snapshot.incoming(to: note) where edge.source != note {
                    links.insert(GraphLink(source: id(edge.source), target: id(note)))
                    if visited.insert(edge.source).inserted { next.append(edge.source) }
                }
            }
            if next.isEmpty { break }
            frontier = next
        }

        var nodes: [GraphNode] = visited.map { url in
            GraphNode(
                id: id(url),
                kind: .note(url),
                label: snapshot.metadata(for: url).map(label(for:)) ?? url.deletingPathExtension().lastPathComponent
            )
        }
        nodes += unresolved.map { target in
            GraphNode(id: "unresolved:" + target.lowercased(), kind: .unresolved(target), label: target)
        }

        var byID = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
        // Links whose far end fell outside the depth limit would otherwise leave
        // a spring pulling on a node that isn't there.
        let kept = links.filter { byID[$0.source] != nil && byID[$0.target] != nil }
        for link in kept {
            byID[link.source]?.degree += 1
            byID[link.target]?.degree += 1
        }

        return GraphData(
            nodes: byID.values.sorted { $0.id < $1.id },
            links: kept.sorted { ($0.source, $0.target) < ($1.source, $1.target) }
        )
    }

    /// What a note is called in the graph.
    ///
    /// The file name, not the note's display title. The title falls back to the
    /// first `# heading` in the file, so labelling nodes with it turned the vault
    /// graph into a wall of section headings — two notes whose first heading
    /// happened to match became two indistinguishable circles, and a note whose
    /// first heading was "选题：" was labelled "选题：". A graph of a vault is
    /// about which *files* link to which, so it says which files they are.
    private static func label(for note: NoteMetadata) -> String {
        note.basename
    }

    /// Nodes within `depth` hops of a node — the "local graph" panel.
    ///
    /// Prefer ``local(from:around:depth:includeUnresolved:)`` when starting from
    /// an index; this one is for narrowing a graph already in hand.
    public func localGraph(around nodeID: String, depth: Int) -> GraphData {
        var frontier: Set<String> = [nodeID]
        var visited: Set<String> = [nodeID]

        for _ in 0..<max(1, depth) {
            var next: Set<String> = []
            for link in links {
                if frontier.contains(link.source), !visited.contains(link.target) { next.insert(link.target) }
                if frontier.contains(link.target), !visited.contains(link.source) { next.insert(link.source) }
            }
            visited.formUnion(next)
            frontier = next
            if frontier.isEmpty { break }
        }

        return GraphData(
            nodes: nodes.filter { visited.contains($0.id) },
            links: links.filter { visited.contains($0.source) && visited.contains($0.target) }
        )
    }
}

/// Force-directed layout: repulsion between all nodes, springs along links, and a
/// weak pull toward the centre so disconnected components don't drift away.
///
/// Everything the per-frame loop touches lives in flat arrays indexed by *slot* —
/// slot `i` is `data.nodes[i]` in `positions`, `velocities`, `radii` and
/// `pinned` alike. That is not tidiness, it is the whole performance story. The
/// previous version kept a `[String: Body]` dictionary, rebuilt a neighbour list
/// per node per frame and *sorted* it — by string — to stay deterministic. On the
/// 8,844-note vault this was measured at **3,993 ms for a single frame** in a
/// release build, on the main thread, inside the drawing closure: the graph tab
/// hung the app rather than drew anything. With slots and the quadtree below the
/// same frame is a few milliseconds.
/// The graph's four force dials.
///
/// Names, ranges and default readings are Obsidian's, so a number noted there
/// means the same thing here. The `as…` properties below convert each reading
/// into this simulation's own units; the constants are picked so that the
/// defaults reproduce the tuning that was already right, rather than being
/// meaningful in themselves.
public struct Forces: Sendable, Equatable {
    /// 0…1. Pull toward the centre, which is what stops disconnected components
    /// drifting away for ever.
    public var centre: Double = 0.52
    /// 0…20. Node-to-node repulsion.
    public var repel: Double = 10
    /// 0…1. Spring stiffness along links.
    public var link: Double = 1
    /// 30…500. Spring rest length.
    public var linkDistance: Double = 250

    public init() {}

    public init(centre: Double, repel: Double, link: Double, linkDistance: Double) {
        self.centre = centre
        self.repel = repel
        self.link = link
        self.linkDistance = linkDistance
    }

    public static let centreRange: ClosedRange<Double> = 0...1
    public static let repelRange: ClosedRange<Double> = 0...20
    public static let linkRange: ClosedRange<Double> = 0...1
    public static let linkDistanceRange: ClosedRange<Double> = 30...500

    var asCentreGravity: Double { centre * 0.0231 }
    var asRepulsion: Double { repel * 300 }
    var asSpringStrength: Double { link * 0.02 }
    /// One layout unit per unit on the dial. Scaling this down — an earlier
    /// draft used a quarter — made the default 250 behave like 60, and the
    /// linked part of a vault collapsed into a knot in the middle of the orphans
    /// instead of spreading out among them the way Obsidian's does.
    var asSpringLength: Double { linkDistance }
}

public struct GraphSimulation: Sendable {
    public private(set) var data: GraphData

    /// Node positions, parallel to `data.nodes`.
    public private(set) var positions: [SIMD2<Double>]
    /// Node radii, parallel to `data.nodes`.
    public private(set) var radii: [Double]
    /// Link endpoints as slot pairs, so neither drawing nor the spring pass has
    /// to hash a string.
    public private(set) var linkSlots: [SIMD2<Int32>]

    private var velocities: [SIMD2<Double>]
    private var pinned: [Bool]
    private var slots: [String: Int]

    /// The four dials, carrying Obsidian's names, ranges and default readings.
    public var forces = Forces()
    public var damping: Double = 0.82
    /// Barnes–Hut opening angle. A cell stands in for its members when it
    /// subtends less than this; smaller is more accurate and slower. 0.9 is the
    /// usual compromise and is what d3-force ships.
    public var theta: Double = 0.9
    /// Repulsion is computed as if no two nodes were ever closer than this.
    ///
    /// Without a floor the force goes as 1/d³ and has no ceiling: a pair that
    /// happened to start at the same point pushed each other at the velocity
    /// clamp *every frame for the whole run*, and drifted off at a steady 60
    /// units a frame while the other nine thousand nodes settled into a tidy
    /// disc around the origin. On the vault this was found on, twelve nodes —
    /// six coincident pairs — ended up 14,000 units out from a graph whose 99th
    /// percentile was 1,685, so fitting it on screen shrank the real graph to a
    /// dot in the corner.
    ///
    /// Eight units is about two node radii: the distance at which two circles
    /// touch, and so the closest they have any business being. Ordinary
    /// neighbours settle 20–60 apart and never reach it.
    public var minimumSeparation: Double = 8

    public init(data: GraphData, forces: Forces = Forces(), seed: UInt64 = 42) {
        self.data = data
        self.forces = forces
        let count = data.nodes.count

        positions = []
        positions.reserveCapacity(count)
        radii = []
        radii.reserveCapacity(count)
        velocities = Array(repeating: .zero, count: count)
        pinned = Array(repeating: false, count: count)

        // The starting cloud grows with the square root of the node count, so
        // 20 notes and 20,000 notes start at the same *density*. Seeding 8,844
        // nodes into the same 340-unit disc a handful of nodes get put them tens
        // deep in every cell and gave the layout a knot to untie before it could
        // start spreading.
        var generator = SplitMix64(seed: seed)
        let spread = 40 + 34 * (Double(count).squareRoot())
        var table = [String: Int](minimumCapacity: count)
        for (slot, node) in data.nodes.enumerated() {
            // Deterministic pseudo-random start so a given vault always lays out
            // the same way — a moving graph between launches feels broken.
            //
            // The whole 64-bit draw, not `% 10_000`: the coarse version placed
            // every node on a 10,000 × 10,000 lattice of angles and radii, and
            // on a vault of nine thousand notes that produced a handful of pairs
            // sharing a cell exactly. Two nodes at the same point repel each
            // other at the force limit for ever — see `minimumSeparation`.
            let angle = generator.unitInterval() * 2 * .pi
            let distance = 40 + generator.unitInterval() * spread
            positions.append(SIMD2(cos(angle) * distance, sin(angle) * distance))
            radii.append(4 + min(14, (Double(node.degree)).squareRoot() * 3))
            table[node.id] = slot
        }
        slots = table

        linkSlots = data.links.compactMap { link in
            guard let source = table[link.source], let target = table[link.target] else { return nil }
            return SIMD2(Int32(source), Int32(target))
        }
    }

    public func slot(of nodeID: String) -> Int? { slots[nodeID] }
    public func radius(for nodeID: String) -> Double { slots[nodeID].map { radii[$0] } ?? 4 }
    public func position(of nodeID: String) -> SIMD2<Double>? { slots[nodeID].map { positions[$0] } }

    public mutating func pin(_ nodeID: String, at position: SIMD2<Double>) {
        guard let slot = slots[nodeID] else { return }
        positions[slot] = position
        velocities[slot] = .zero
        pinned[slot] = true
    }

    public mutating func unpin(_ nodeID: String) {
        guard let slot = slots[nodeID] else { return }
        pinned[slot] = false
    }

    /// Advances the simulation one frame. `alpha` cools from 1 → 0 so motion
    /// settles instead of jittering forever.
    public mutating func step(alpha: Double) {
        guard !positions.isEmpty else { return }
        var netForces = [SIMD2<Double>](repeating: .zero, count: positions.count)

        // Repulsion, approximated with a Barnes–Hut quadtree.
        let box = boundingBox()
        var tree = QuadTree(centre: box.centre, half: box.half, capacity: positions.count)
        for slot in positions.indices {
            tree.insert(slot, at: positions[slot], positions: positions)
        }
        let repulsion = forces.asRepulsion
        let springLength = forces.asSpringLength
        let springStrength = forces.asSpringStrength
        let centerGravity = forces.asCentreGravity
        let thetaSquared = theta * theta
        // One scratch stack for the whole pass rather than one array per node.
        var stack: [Int32] = []
        stack.reserveCapacity(64)
        for slot in positions.indices {
            netForces[slot] = tree.repulsion(
                on: slot,
                positions: positions,
                strength: repulsion,
                thetaSquared: thetaSquared,
                minimumSeparationSquared: minimumSeparation * minimumSeparation,
                stack: &stack
            )
        }

        // Springs along links.
        for link in linkSlots {
            let source = Int(link.x)
            let target = Int(link.y)
            let delta = positions[target] - positions[source]
            let distance = max(0.01, (delta.x * delta.x + delta.y * delta.y).squareRoot())
            let displacement = (distance - springLength) * springStrength
            let force = delta / distance * displacement
            netForces[source] += force
            netForces[target] -= force
        }

        // Integrate.
        for slot in positions.indices where !pinned[slot] {
            var force = netForces[slot]
            force -= positions[slot] * centerGravity
            var velocity = (velocities[slot] + force * alpha) * damping
            // Clamp so a bad frame can't fling nodes to infinity.
            let speed = (velocity.x * velocity.x + velocity.y * velocity.y).squareRoot()
            if speed > 60 { velocity = velocity / speed * 60 }
            velocities[slot] = velocity
            positions[slot] += velocity
        }
    }

    /// Square box containing every node, which the quadtree subdivides.
    private func boundingBox() -> (centre: SIMD2<Double>, half: Double) {
        var lowX = positions[0].x, lowY = positions[0].y
        var highX = lowX, highY = lowY
        for position in positions {
            lowX = min(lowX, position.x)
            lowY = min(lowY, position.y)
            highX = max(highX, position.x)
            highY = max(highY, position.y)
        }
        // Slightly oversized so a node sitting exactly on the far edge still
        // falls inside the root cell.
        let half = max(1, max(highX - lowX, highY - lowY) / 2 * 1.0001)
        return (SIMD2((lowX + highX) / 2, (lowY + highY) / 2), half)
    }
}

/// Barnes–Hut quadtree over the node positions.
///
/// A cell far enough away is replaced by a single body at its centre of mass
/// carrying the mass of everything inside it, which turns all-pairs repulsion
/// from O(n²) into O(n log n). Cells live in one flat array and refer to each
/// other by index; `SIMD4<Int32>` holds the four quadrant links, `-1` for empty.
private struct QuadTree {
    struct Cell {
        var centre: SIMD2<Double>
        var half: Double
        /// Sum of member positions. Divided by `mass` this is the centre of mass;
        /// kept as a sum so insertion is a single add.
        var sum: SIMD2<Double> = .zero
        /// Number of nodes inside. Every node weighs the same.
        var mass: Double = 0
        var children: SIMD4<Int32> = SIMD4(repeating: -1)
        var hasChildren = false
        /// Slot of the one node in this leaf, or `-1` for none.
        var body: Int32 = -1
    }

    /// Two nodes closer together than 2⁻⁴⁰ of the graph's width cannot be
    /// separated by further subdivision, so insertion stops there and leaves them
    /// merged in one cell. Their mass still counts; only the individual body does
    /// not. Reaching this needs genuinely coincident positions.
    private static let maxDepth = 40

    private var cells: [Cell]

    init(centre: SIMD2<Double>, half: Double, capacity: Int) {
        cells = []
        // A quadtree over n points settles at roughly 2n cells.
        cells.reserveCapacity(capacity * 2 + 1)
        cells.append(Cell(centre: centre, half: half))
    }

    private static func quadrant(of point: SIMD2<Double>, around centre: SIMD2<Double>) -> Int {
        (point.x < centre.x ? 0 : 1) | (point.y < centre.y ? 0 : 2)
    }

    /// The child cell for a quadrant, created on first use.
    private mutating func child(of cell: Int, quadrant: Int) -> Int {
        let existing = cells[cell].children[quadrant]
        if existing >= 0 { return Int(existing) }

        let half = cells[cell].half / 2
        let centre = cells[cell].centre
        cells.append(Cell(
            centre: SIMD2(
                centre.x + (quadrant & 1 == 0 ? -half : half),
                centre.y + (quadrant & 2 == 0 ? -half : half)
            ),
            half: half
        ))
        let index = cells.count - 1
        cells[cell].children[quadrant] = Int32(index)
        cells[cell].hasChildren = true
        return index
    }

    /// Inserts one node, splitting leaves as needed.
    ///
    /// Iterative rather than recursive: near-coincident nodes can drive the
    /// descent dozens of levels deep, and this runs once per node per frame.
    mutating func insert(_ slot: Int, at point: SIMD2<Double>, positions: [SIMD2<Double>]) {
        var cell = 0
        var depth = 0
        while true {
            cells[cell].sum += point
            cells[cell].mass += 1

            if !cells[cell].hasChildren {
                if cells[cell].body < 0 {
                    cells[cell].body = Int32(slot)
                    return
                }
                guard depth < Self.maxDepth else { return }

                // Occupied leaf: push the node already there down a level first,
                // then carry on placing this one. If both land in the same
                // quadrant the next turn of the loop splits again.
                let resident = Int(cells[cell].body)
                let residentPoint = positions[resident]
                cells[cell].body = -1
                let target = child(of: cell, quadrant: Self.quadrant(of: residentPoint, around: cells[cell].centre))
                cells[target].sum += residentPoint
                cells[target].mass += 1
                cells[target].body = Int32(resident)
            }

            cell = child(of: cell, quadrant: Self.quadrant(of: point, around: cells[cell].centre))
            depth += 1
        }
    }

    /// Total repulsive force on one node.
    ///
    /// `stack` is passed in and reused across nodes; a fresh array per node was
    /// most of the cost of the traversal.
    func repulsion(
        on slot: Int,
        positions: [SIMD2<Double>],
        strength: Double,
        thetaSquared: Double,
        minimumSeparationSquared: Double,
        stack: inout [Int32]
    ) -> SIMD2<Double> {
        let point = positions[slot]
        var force = SIMD2<Double>.zero
        stack.removeAll(keepingCapacity: true)
        stack.append(0)

        while let index = stack.popLast() {
            let cell = cells[Int(index)]
            guard cell.mass > 0 else { continue }

            var delta = point - cell.sum / cell.mass
            var distanceSquared = delta.x * delta.x + delta.y * delta.y

            // The Barnes–Hut criterion: stand in for the cell only when its width
            // over the distance to it is below θ. A node inside a cell is by
            // definition not far from it, so this also stops a node repelling
            // itself through an ancestor.
            let width = cell.half * 2
            if cell.hasChildren, width * width > thetaSquared * distanceSquared {
                for quadrant in 0..<4 where cell.children[quadrant] >= 0 {
                    stack.append(cell.children[quadrant])
                }
                continue
            }
            if cell.body == Int32(slot) { continue }

            if distanceSquared < minimumSeparationSquared {
                if distanceSquared < 1e-9 {
                    // Exactly coincident: no direction to push in. Pick a fixed
                    // diagonal so the result stays reproducible.
                    delta = SIMD2(0.7071, 0.7071)
                } else {
                    // Keep the direction, drop the magnitude to the floor.
                    delta /= distanceSquared.squareRoot()
                }
                delta *= minimumSeparationSquared.squareRoot()
                distanceSquared = minimumSeparationSquared
            }
            force += delta * (strength * cell.mass / (distanceSquared * distanceSquared.squareRoot()))
        }
        return force
    }
}

/// Small deterministic PRNG so layouts are reproducible across launches.
struct SplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// A draw in `0..<1`, using the 53 bits a `Double` can hold exactly.
    mutating func unitInterval() -> Double {
        Double(next() >> 11) * (1.0 / 9_007_199_254_740_992.0)
    }
}
