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

    /// Builds the graph from an index snapshot, honouring the user's filters.
    public static func build(
        from snapshot: IndexSnapshot,
        includeTags: Bool,
        includeUnresolved: Bool,
        vaultRoot: URL
    ) -> GraphData {
        var nodes: [String: GraphNode] = [:]
        var links: Set<GraphLink> = []

        for (url, note) in snapshot.notes {
            let id = url.path(percentEncoded: false)
            nodes[id] = GraphNode(id: id, kind: .note(url), label: note.title)
        }

        for edge in snapshot.edges {
            let sourceID = edge.source.path(percentEncoded: false)
            if let destination = edge.destination {
                let targetID = destination.path(percentEncoded: false)
                guard sourceID != targetID, nodes[targetID] != nil else { continue }
                links.insert(GraphLink(source: sourceID, target: targetID))
            } else if includeUnresolved, !edge.unresolvedTarget.isEmpty {
                let targetID = "unresolved:" + edge.unresolvedTarget.lowercased()
                nodes[targetID] = GraphNode(
                    id: targetID,
                    kind: .unresolved(edge.unresolvedTarget),
                    label: edge.unresolvedTarget
                )
                links.insert(GraphLink(source: sourceID, target: targetID))
            }
        }

        if includeTags {
            for (url, note) in snapshot.notes {
                let sourceID = url.path(percentEncoded: false)
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

        return GraphData(nodes: Array(nodes.values), links: Array(links))
    }

    /// Nodes within `depth` hops of a note — the "local graph" panel.
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
/// Repulsion uses a uniform spatial grid rather than naive O(n²) so vaults with a
/// few thousand notes still animate at 60fps.
public struct GraphSimulation: Sendable {
    public struct Body: Sendable {
        public var position: SIMD2<Double>
        public var velocity: SIMD2<Double> = .zero
        public var isPinned = false
        public let radius: Double
    }

    public private(set) var bodies: [String: Body] = [:]
    /// Node IDs in a stable order. `bodies` is a dictionary, and dictionary
    /// iteration order varies per process, so accumulating forces in that order
    /// would produce slightly different float results — and therefore a
    /// different layout — on every launch. Everything iterates this instead.
    private var orderedIDs: [String] = []
    public private(set) var data: GraphData

    // Tuned for a calm settle rather than a fast one: users watch this.
    public var repulsion: Double = 3_000
    public var springLength: Double = 60
    public var springStrength: Double = 0.02
    public var centerGravity: Double = 0.012
    public var damping: Double = 0.82
    /// Ignore repulsion beyond this distance; the grid uses it as cell size.
    public var repulsionCutoff: Double = 240

    public init(data: GraphData, seed: UInt64 = 42) {
        self.data = data
        var generator = SplitMix64(seed: seed)
        for node in data.nodes {
            // Deterministic pseudo-random start so a given vault always lays out
            // the same way — a moving graph between launches feels broken.
            let angle = Double(generator.next() % 10_000) / 10_000 * 2 * .pi
            let distance = 40 + Double(generator.next() % 300)
            bodies[node.id] = Body(
                position: SIMD2(cos(angle) * distance, sin(angle) * distance),
                radius: 4 + min(14, sqrt(Double(node.degree)) * 3)
            )
        }
        orderedIDs = data.nodes.map(\.id).sorted()
    }

    public func radius(for nodeID: String) -> Double { bodies[nodeID]?.radius ?? 4 }
    public func position(of nodeID: String) -> SIMD2<Double>? { bodies[nodeID]?.position }

    public mutating func pin(_ nodeID: String, at position: SIMD2<Double>) {
        bodies[nodeID]?.position = position
        bodies[nodeID]?.velocity = .zero
        bodies[nodeID]?.isPinned = true
    }

    public mutating func unpin(_ nodeID: String) {
        bodies[nodeID]?.isPinned = false
    }

    /// Advances the simulation one frame. `alpha` cools from 1 → 0 so motion
    /// settles instead of jittering forever.
    public mutating func step(alpha: Double) {
        guard !bodies.isEmpty else { return }
        var forces: [String: SIMD2<Double>] = [:]

        // Repulsion, restricted to neighbouring grid cells.
        let cellSize = repulsionCutoff
        var grid: [SIMD2<Int>: [String]] = [:]
        for id in orderedIDs {
            guard let body = bodies[id] else { continue }
            let cell = SIMD2(Int(floor(body.position.x / cellSize)), Int(floor(body.position.y / cellSize)))
            grid[cell, default: []].append(id)
        }

        for id in orderedIDs {
            guard let body = bodies[id] else { continue }
            let cell = SIMD2(Int(floor(body.position.x / cellSize)), Int(floor(body.position.y / cellSize)))
            var neighbours: [String] = []
            for dx in -1...1 {
                for dy in -1...1 {
                    neighbours.append(contentsOf: grid[SIMD2(cell.x + dx, cell.y + dy)] ?? [])
                }
            }
            neighbours.sort()
            do {
                var force = SIMD2<Double>.zero
                for otherID in neighbours where otherID != id {
                    guard let other = bodies[otherID] else { continue }
                    var delta = body.position - other.position
                    var distanceSquared = delta.x * delta.x + delta.y * delta.y
                    if distanceSquared < 0.01 {
                        // Perfectly coincident nodes would produce NaN; nudge apart.
                        delta = SIMD2(0.01, 0.01)
                        distanceSquared = 0.0002
                    }
                    guard distanceSquared < cellSize * cellSize else { continue }
                    force += delta * (repulsion / (distanceSquared * sqrt(distanceSquared)))
                }
                forces[id, default: .zero] += force
            }
        }

        // Springs along links.
        for link in data.links {
            guard let a = bodies[link.source], let b = bodies[link.target] else { continue }
            let delta = b.position - a.position
            let distance = max(0.01, sqrt(delta.x * delta.x + delta.y * delta.y))
            let displacement = (distance - springLength) * springStrength
            let force = delta / distance * displacement
            forces[link.source, default: .zero] += force
            forces[link.target, default: .zero] -= force
        }

        // Integrate.
        for id in orderedIDs {
            guard var body = bodies[id], !body.isPinned else { continue }
            var force = forces[id] ?? .zero
            force -= body.position * centerGravity
            body.velocity = (body.velocity + force * alpha) * damping
            // Clamp so a bad frame can't fling nodes to infinity.
            let speed = sqrt(body.velocity.x * body.velocity.x + body.velocity.y * body.velocity.y)
            if speed > 60 { body.velocity = body.velocity / speed * 60 }
            body.position += body.velocity
            bodies[id] = body
        }
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
}
