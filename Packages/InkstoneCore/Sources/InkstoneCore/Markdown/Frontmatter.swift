import Foundation
import Yams

/// A YAML frontmatter value, restricted to the shapes notes actually use.
///
/// Modelled as an enum rather than `Any` so the whole note model stays `Sendable`
/// and can cross actor boundaries during indexing.
public enum PropertyValue: Hashable, Sendable {
    case text(String)
    case number(Double)
    case boolean(Bool)
    case date(Date)
    case list([PropertyValue])
    case null

    public var stringValue: String? {
        switch self {
        case .text(let value): return value
        case .number(let value): return value.formatted()
        case .boolean(let value): return String(value)
        case .date(let value): return value.formatted(.iso8601.year().month().day())
        case .list, .null: return nil
        }
    }

    /// Flattens scalars and lists into strings — how `tags:` and `aliases:` are read.
    public var stringList: [String] {
        switch self {
        case .list(let values): return values.compactMap(\.stringValue)
        case .null: return []
        default: return stringValue.map { [$0] } ?? []
        }
    }
}

/// Parsed YAML frontmatter plus the byte range it occupied in the source.
public struct Frontmatter: Hashable, Sendable {
    public var properties: [String: PropertyValue]
    /// Character range of the whole `---` fenced block, so the editor can hide or
    /// render it as a property table without re-scanning the document.
    public var sourceRange: Range<String.Index>?

    public static let empty = Frontmatter(properties: [:], sourceRange: nil)

    public var tags: [String] {
        // Obsidian accepts both `tag:` and `tags:`.
        let raw = (properties["tags"]?.stringList ?? []) + (properties["tag"]?.stringList ?? [])
        return raw.flatMap { $0.split(separator: ",") }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { $0.hasPrefix("#") ? String($0.dropFirst()) : $0 }
    }

    public var aliases: [String] {
        ((properties["aliases"]?.stringList ?? []) + (properties["alias"]?.stringList ?? []))
            .filter { !$0.isEmpty }
    }

    /// Custom CSS classes applied to the note, matching Obsidian's `cssclasses`.
    public var cssClasses: [String] {
        (properties["cssclasses"]?.stringList ?? []) + (properties["cssclass"]?.stringList ?? [])
    }

    public init(properties: [String: PropertyValue], sourceRange: Range<String.Index>?) {
        self.properties = properties
        self.sourceRange = sourceRange
    }
}

public enum FrontmatterParser {
    /// Extracts frontmatter from a note's text.
    ///
    /// Frontmatter is only recognised when the document *starts* with `---`,
    /// which is what keeps a horizontal rule in the middle of a note from being
    /// mistaken for a property block.
    public static func parse(_ text: String) -> (frontmatter: Frontmatter, body: Substring) {
        guard text.hasPrefix("---") else { return (.empty, text[...]) }

        // The opening fence must be a line of its own.
        guard let openingLineEnd = text.firstIndex(where: \.isNewline),
              text[text.startIndex..<openingLineEnd].trimmingCharacters(in: .whitespaces) == "---" else {
            return (.empty, text[...])
        }

        let bodyStart = text.index(after: openingLineEnd)
        guard let closingRange = text.range(of: "\n---", range: bodyStart..<text.endIndex) else {
            return (.empty, text[...])
        }

        let yaml = String(text[bodyStart..<closingRange.lowerBound])
        // Skip past the closing fence and its trailing newline.
        var contentStart = closingRange.upperBound
        while contentStart < text.endIndex, !text[contentStart].isNewline {
            contentStart = text.index(after: contentStart)
        }
        if contentStart < text.endIndex { contentStart = text.index(after: contentStart) }

        let properties = (try? Yams.load(yaml: yaml)).flatMap { $0 as? [String: Any] } ?? [:]
        let frontmatter = Frontmatter(
            properties: properties.mapValues(convert),
            sourceRange: text.startIndex..<contentStart
        )
        return (frontmatter, text[contentStart...])
    }

    /// Serialises properties back to a `---` fenced block, preserving key order
    /// alphabetically so diffs stay stable in git.
    public static func render(_ frontmatter: Frontmatter) -> String {
        guard !frontmatter.properties.isEmpty else { return "" }
        let plain = frontmatter.properties.mapValues(unconvert)
        guard let yaml = try? Yams.dump(object: plain, sortKeys: true) else { return "" }
        return "---\n\(yaml)---\n"
    }

    private static func convert(_ value: Any) -> PropertyValue {
        switch value {
        case let value as String: return .text(value)
        case let value as Bool: return .boolean(value)
        case let value as Int: return .number(Double(value))
        case let value as Double: return .number(value)
        case let value as Date: return .date(value)
        case let value as [Any]: return .list(value.map(convert))
        default: return .null
        }
    }

    private static func unconvert(_ value: PropertyValue) -> Any {
        switch value {
        case .text(let value): return value
        case .number(let value): return value == value.rounded() ? Int(value) : value
        case .boolean(let value): return value
        case .date(let value): return value
        case .list(let values): return values.map(unconvert)
        case .null: return NSNull()
        }
    }
}
