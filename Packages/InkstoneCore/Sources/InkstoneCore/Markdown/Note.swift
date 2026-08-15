import Foundation

/// A heading extracted from a note, used for the outline pane and `[[Note#Heading]]` resolution.
public struct Heading: Hashable, Sendable {
    public let level: Int
    public let text: String
    public let range: NSRange

    public init(level: Int, text: String, range: NSRange) {
        self.level = level
        self.text = text
        self.range = range
    }
}

/// Everything the index knows about a note without holding its full text.
///
/// Kept small and value-typed: a 20,000-note vault has to fit in memory, so the
/// body stays on disk and only metadata is retained.
public struct NoteMetadata: Identifiable, Hashable, Sendable {
    public let url: URL
    public var id: URL { url }

    /// Filename without extension. This is the link target other notes use.
    public let basename: String
    /// Display title: frontmatter `title`, else first H1, else basename.
    public let title: String
    public let frontmatter: Frontmatter
    /// Inline `#tags` plus frontmatter tags, deduplicated, without leading `#`.
    public let tags: [String]
    /// Outgoing links in document order, including embeds.
    public let outgoingLinks: [WikiLink]
    /// Bare URLs and `[text](path.md)` links pointing at other notes.
    public let markdownLinkTargets: [String]
    public let headings: [Heading]
    /// `^block-id` anchors defined in this note.
    public let blockIdentifiers: [String]
    public let modified: Date
    public let created: Date
    public let wordCount: Int

    public var aliases: [String] { frontmatter.aliases }

    /// All names this note answers to when resolving a link.
    public var linkNames: [String] { [basename] + aliases }
}

public enum NoteParser {
    private static let scanner = SyntaxScanner()

    /// Builds metadata from a note's raw text. Pure and `Sendable`, so indexing
    /// can be parallelised across files with `TaskGroup`.
    public static func parse(
        text: String,
        url: URL,
        modified: Date = .now,
        created: Date = .now
    ) -> NoteMetadata {
        let (frontmatter, _) = FrontmatterParser.parse(text)
        let tokens = scanner.scan(text)
        let nsText = text as NSString

        var links: [WikiLink] = []
        var markdownTargets: [String] = []
        var headings: [Heading] = []
        var blockIdentifiers: [String] = []
        var inlineTags: [String] = []

        for token in tokens {
            switch token.kind {
            case .wikiLink(let link), .embed(let link):
                links.append(link)
            case .markdownLink(let destination):
                // Only internal targets matter for the graph; external URLs are
                // rendered but never become graph edges.
                if !destination.contains("://"), !destination.hasPrefix("mailto:") {
                    markdownTargets.append(destination.removingPercentEncoding ?? destination)
                }
            case .heading(let level):
                headings.append(Heading(
                    level: level,
                    text: nsText.substring(with: token.contentRange),
                    range: token.range
                ))
            case .blockIdentifier(let identifier):
                blockIdentifiers.append(identifier)
            case .tag(let name):
                inlineTags.append(name)
            default:
                break
            }
        }

        let basename = url.deletingPathExtension().lastPathComponent
        let title = frontmatter.properties["title"]?.stringValue
            ?? headings.first(where: { $0.level == 1 })?.text
            ?? basename

        // Nested tags imply their ancestors: `#project/inkstone` also matches `#project`.
        let allTags = expandNested(inlineTags + frontmatter.tags)

        return NoteMetadata(
            url: url,
            basename: basename,
            title: title,
            frontmatter: frontmatter,
            tags: allTags,
            outgoingLinks: links,
            markdownLinkTargets: markdownTargets,
            headings: headings,
            blockIdentifiers: blockIdentifiers,
            modified: modified,
            created: created,
            wordCount: wordCount(of: text)
        )
    }

    /// Counts CJK characters individually and Latin runs as words, so a mixed
    /// Chinese/English note reports a number that means something to the user.
    public static func wordCount(of text: String) -> Int {
        var count = 0
        var inLatinRun = false
        for scalar in text.unicodeScalars {
            if isCJK(scalar) {
                count += 1
                inLatinRun = false
            } else if CharacterSet.alphanumerics.contains(scalar) {
                if !inLatinRun { count += 1 }
                inLatinRun = true
            } else {
                inLatinRun = false
            }
        }
        return count
    }

    private static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x4E00...0x9FFF,   // CJK Unified Ideographs
             0x3400...0x4DBF,   // Extension A
             0xF900...0xFAFF,   // Compatibility Ideographs
             0x3040...0x30FF,   // Kana
             0xAC00...0xD7AF:   // Hangul syllables
            return true
        default:
            return false
        }
    }

    private static func expandNested(_ tags: [String]) -> [String] {
        var result: Set<String> = []
        for tag in tags {
            let parts = tag.split(separator: "/")
            for index in parts.indices {
                result.insert(parts[0...index].joined(separator: "/"))
            }
        }
        return result.sorted()
    }
}
