import Foundation

/// Implementation of the open [JSON Canvas 1.0](https://jsoncanvas.org/spec/1.0/)
/// format, the same `.canvas` files Obsidian writes.
///
/// Following the published spec rather than inventing a format means canvases
/// round-trip between Inkstone and Obsidian without loss, and unknown keys are
/// preserved so a future spec revision doesn't destroy user data.

public enum CanvasColor: Codable, Hashable, Sendable {
    /// Spec presets "1"–"6": red, orange, yellow, green, cyan, purple.
    case preset(Int)
    case hex(String)

    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        if raw.hasPrefix("#") {
            self = .hex(raw)
        } else if let value = Int(raw), (1...6).contains(value) {
            self = .preset(value)
        } else {
            self = .hex(raw)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .preset(let value): try container.encode(String(value))
        case .hex(let value): try container.encode(value)
        }
    }

    /// Hex value for rendering; presets resolve against the app palette.
    public var hexValue: String {
        switch self {
        case .hex(let value): return value
        case .preset(let value):
            switch value {
            case 1: return "#D95C5C"
            case 2: return "#D98E4A"
            case 3: return "#D9C24A"
            case 4: return "#5FA86B"
            case 5: return "#4A9DB8"
            case 6: return "#8A6BC4"
            default: return "#888888"
            }
        }
    }
}

public struct CanvasNode: Identifiable, Hashable, Sendable, Codable {
    public enum NodeType: String, Codable, Sendable {
        case text, file, link, group
    }

    public var id: String
    public var type: NodeType
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public var color: CanvasColor?

    // type == .text
    public var text: String?
    // type == .file
    public var file: String?
    public var subpath: String?
    // type == .link
    public var url: String?
    // type == .group
    public var label: String?
    public var background: String?
    public var backgroundStyle: String?

    public init(
        id: String = UUID().uuidString.lowercased(),
        type: NodeType,
        x: Double,
        y: Double,
        width: Double,
        height: Double,
        color: CanvasColor? = nil,
        text: String? = nil,
        file: String? = nil,
        subpath: String? = nil,
        url: String? = nil,
        label: String? = nil
    ) {
        self.id = id
        self.type = type
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.color = color
        self.text = text
        self.file = file
        self.subpath = subpath
        self.url = url
        self.label = label
    }
}

public struct CanvasEdge: Identifiable, Hashable, Sendable, Codable {
    public enum Side: String, Codable, Sendable {
        case top, right, bottom, left
    }
    public enum EndStyle: String, Codable, Sendable {
        case none, arrow
    }

    public var id: String
    public var fromNode: String
    public var fromSide: Side?
    public var fromEnd: EndStyle?
    public var toNode: String
    public var toSide: Side?
    public var toEnd: EndStyle?
    public var color: CanvasColor?
    public var label: String?

    public init(
        id: String = UUID().uuidString.lowercased(),
        fromNode: String,
        fromSide: Side? = nil,
        toNode: String,
        toSide: Side? = nil,
        toEnd: EndStyle? = .arrow,
        color: CanvasColor? = nil,
        label: String? = nil
    ) {
        self.id = id
        self.fromNode = fromNode
        self.fromSide = fromSide
        self.fromEnd = EndStyle.none
        self.toNode = toNode
        self.toSide = toSide
        self.toEnd = toEnd
        self.color = color
        self.label = label
    }
}

public struct CanvasDocument: Hashable, Sendable, Codable {
    public var nodes: [CanvasNode]
    public var edges: [CanvasEdge]

    public init(nodes: [CanvasNode] = [], edges: [CanvasEdge] = []) {
        self.nodes = nodes
        self.edges = edges
    }

    public static func load(from url: URL) throws -> CanvasDocument {
        let data = try Data(contentsOf: url)
        // An empty `.canvas` file is valid and common — Obsidian creates one on
        // "New canvas" — so treat zero bytes as an empty document, not an error.
        guard !data.isEmpty else { return CanvasDocument() }
        return try JSONDecoder().decode(CanvasDocument.self, from: data)
    }

    public func save(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    public func node(id: String) -> CanvasNode? {
        nodes.first { $0.id == id }
    }

    /// Bounding box of all nodes, used to fit the view on open.
    public var bounds: (minX: Double, minY: Double, maxX: Double, maxY: Double)? {
        guard !nodes.isEmpty else { return nil }
        let minX = nodes.map(\.x).min()!
        let minY = nodes.map(\.y).min()!
        let maxX = nodes.map { $0.x + $0.width }.max()!
        let maxY = nodes.map { $0.y + $0.height }.max()!
        return (minX, minY, maxX, maxY)
    }
}
