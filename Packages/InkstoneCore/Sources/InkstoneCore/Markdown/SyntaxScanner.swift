import Foundation

/// Every syntactic element Inkstone highlights or indexes.
///
/// One scanner feeds three consumers — the editor's syntax highlighter, the
/// live-preview renderer, and the link/tag index — so the definition of "what is
/// a tag" lives in exactly one place.
public enum TokenKind: Hashable, Sendable {
    case heading(level: Int)
    case bold
    case italic
    case strikethrough
    case highlight
    case inlineCode
    case codeBlock(language: String?)
    case mathInline
    case mathBlock
    case wikiLink(WikiLink)
    case embed(WikiLink)
    case markdownLink(destination: String)
    case tag(String)
    case blockIdentifier(String)
    case callout(type: String, folded: Bool, title: String)
    case blockquote
    case listMarker
    case task(checked: Bool)
    case comment
    case horizontalRule
    case frontmatter
}

public struct SyntaxToken: Hashable, Sendable {
    public let kind: TokenKind
    /// UTF-16 range, matching what TextKit and `NSAttributedString` expect.
    public let range: NSRange
    /// Range of the meaningful content inside the delimiters, used by live
    /// preview to hide `**` while keeping the bold text visible.
    public let contentRange: NSRange

    public init(kind: TokenKind, range: NSRange, contentRange: NSRange? = nil) {
        self.kind = kind
        self.range = range
        self.contentRange = contentRange ?? range
    }
}

/// A parsed `[[wikilink]]` target.
public struct WikiLink: Hashable, Sendable {
    /// Note name or path as typed, without extension. Empty for same-note links.
    public let target: String
    /// `#Heading` or `#^blockId` fragment, without the leading `#`.
    public let fragment: String?
    /// Display text after `|`. For embeds this doubles as a size hint ("300x200").
    public let alias: String?

    public init(target: String, fragment: String? = nil, alias: String? = nil) {
        self.target = target
        self.fragment = fragment
        self.alias = alias
    }

    public var displayText: String {
        if let alias, !alias.isEmpty { return alias }
        if target.isEmpty, let fragment { return fragment }
        return target
    }

    /// True when the fragment points at a `^block-id` rather than a heading.
    public var isBlockReference: Bool { fragment?.hasPrefix("^") == true }
}

/// Single-pass-ish scanner over raw Markdown source.
///
/// Implemented with `NSRegularExpression` rather than a hand-written lexer: the
/// patterns are the spec here, they run in a few milliseconds on notes of
/// realistic size, and code regions are masked out first so a `#hashtag` inside a
/// fenced block never becomes a tag.
public struct SyntaxScanner: Sendable {
    public init() {}

    public func scan(_ text: String) -> [SyntaxToken] {
        let nsText = text as NSString
        let full = NSRange(location: 0, length: nsText.length)

        var tokens: [SyntaxToken] = []
        var maskedRegions: [NSRange] = []

        // Frontmatter is masked so its YAML `#comments` and `[[values]]` don't
        // leak into the token stream as tags and links.
        if let frontmatterRange = frontmatterRange(in: nsText) {
            tokens.append(SyntaxToken(kind: .frontmatter, range: frontmatterRange))
            maskedRegions.append(frontmatterRange)
        }

        for match in Patterns.codeBlock.matches(in: text, range: full) {
            let language = match.range(at: 2).location != NSNotFound
                ? nsText.substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespaces)
                : nil
            tokens.append(SyntaxToken(
                kind: .codeBlock(language: language?.isEmpty == false ? language : nil),
                range: match.range
            ))
            maskedRegions.append(match.range)
        }

        for match in Patterns.mathBlock.matches(in: text, range: full)
        where !isMasked(match.range, in: maskedRegions) {
            tokens.append(SyntaxToken(kind: .mathBlock, range: match.range, contentRange: match.range(at: 1)))
            maskedRegions.append(match.range)
        }

        for match in Patterns.comment.matches(in: text, range: full)
        where !isMasked(match.range, in: maskedRegions) {
            tokens.append(SyntaxToken(kind: .comment, range: match.range))
            maskedRegions.append(match.range)
        }

        for match in Patterns.inlineCode.matches(in: text, range: full)
        where !isMasked(match.range, in: maskedRegions) {
            tokens.append(SyntaxToken(kind: .inlineCode, range: match.range, contentRange: match.range(at: 1)))
            maskedRegions.append(match.range)
        }

        // From here on, every pattern respects the mask.
        func addMatches(
            _ regex: NSRegularExpression,
            _ makeToken: (NSTextCheckingResult, NSString) -> SyntaxToken?
        ) {
            for match in regex.matches(in: text, range: full) {
                guard !isMasked(match.range, in: maskedRegions) else { continue }
                if let token = makeToken(match, nsText) { tokens.append(token) }
            }
        }

        addMatches(Patterns.heading) { match, text in
            let level = match.range(at: 1).length
            return SyntaxToken(kind: .heading(level: level), range: match.range, contentRange: match.range(at: 2))
        }

        addMatches(Patterns.callout) { match, text in
            let type = text.substring(with: match.range(at: 1)).lowercased()
            let foldMarker = match.range(at: 2).length > 0 ? text.substring(with: match.range(at: 2)) : ""
            let title = match.range(at: 3).location != NSNotFound
                ? text.substring(with: match.range(at: 3)) : ""
            return SyntaxToken(
                kind: .callout(type: type, folded: foldMarker == "-", title: title),
                range: match.range
            )
        }

        addMatches(Patterns.wikiLink) { match, text in
            let isEmbed = text.substring(with: match.range).hasPrefix("!")
            let link = Self.makeWikiLink(match: match, text: text)
            return SyntaxToken(
                kind: isEmbed ? .embed(link) : .wikiLink(link),
                range: match.range,
                contentRange: match.range(at: 1)
            )
        }

        addMatches(Patterns.markdownLink) { match, text in
            SyntaxToken(
                kind: .markdownLink(destination: text.substring(with: match.range(at: 2))),
                range: match.range,
                contentRange: match.range(at: 1)
            )
        }

        addMatches(Patterns.tag) { match, text in
            SyntaxToken(kind: .tag(text.substring(with: match.range(at: 1))), range: match.range)
        }

        addMatches(Patterns.blockIdentifier) { match, text in
            SyntaxToken(kind: .blockIdentifier(text.substring(with: match.range(at: 1))), range: match.range(at: 0))
        }

        addMatches(Patterns.task) { match, text in
            let marker = text.substring(with: match.range(at: 1))
            return SyntaxToken(kind: .task(checked: marker != " "), range: match.range, contentRange: match.range(at: 1))
        }

        addMatches(Patterns.bold) { match, _ in
            SyntaxToken(kind: .bold, range: match.range, contentRange: match.range(at: 1))
        }
        addMatches(Patterns.italic) { match, _ in
            SyntaxToken(kind: .italic, range: match.range, contentRange: match.range(at: 1))
        }
        addMatches(Patterns.strikethrough) { match, _ in
            SyntaxToken(kind: .strikethrough, range: match.range, contentRange: match.range(at: 1))
        }
        addMatches(Patterns.highlight) { match, _ in
            SyntaxToken(kind: .highlight, range: match.range, contentRange: match.range(at: 1))
        }
        addMatches(Patterns.mathInline) { match, _ in
            SyntaxToken(kind: .mathInline, range: match.range, contentRange: match.range(at: 1))
        }
        addMatches(Patterns.horizontalRule) { match, _ in
            SyntaxToken(kind: .horizontalRule, range: match.range)
        }

        return tokens.sorted { $0.range.location < $1.range.location }
    }

    // MARK: - Convenience extraction

    public func links(in text: String) -> [WikiLink] {
        scan(text).compactMap { token in
            switch token.kind {
            case .wikiLink(let link), .embed(let link): return link
            default: return nil
            }
        }
    }

    /// Inline `#tags`, excluding those inside code, comments, or frontmatter.
    /// Nested tags contribute their ancestors too, so `#a/b` also matches `#a`.
    public func tags(in text: String) -> [String] {
        scan(text).compactMap { token in
            if case .tag(let name) = token.kind { return name }
            return nil
        }
    }

    // MARK: - Helpers

    private static func makeWikiLink(match: NSTextCheckingResult, text: NSString) -> WikiLink {
        let target = text.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespaces)
        var fragment: String?
        if match.range(at: 2).location != NSNotFound {
            // Group 2 includes the leading `#`, which we drop but keep any `^`.
            fragment = String(text.substring(with: match.range(at: 2)).dropFirst())
        }
        var alias: String?
        if match.range(at: 3).location != NSNotFound {
            alias = String(text.substring(with: match.range(at: 3)).dropFirst())
        }
        return WikiLink(target: target, fragment: fragment, alias: alias)
    }

    private func frontmatterRange(in text: NSString) -> NSRange? {
        guard text.hasPrefix("---") else { return nil }
        let full = NSRange(location: 0, length: text.length)
        guard let match = Patterns.frontmatter.firstMatch(in: text as String, range: full),
              match.range.location == 0 else { return nil }
        return match.range
    }

    private func isMasked(_ range: NSRange, in regions: [NSRange]) -> Bool {
        regions.contains { NSIntersectionRange($0, range).length > 0 }
    }
}

/// The regex catalogue. Kept in one place so the syntax "spec" is reviewable.
private enum Patterns {
    static let frontmatter = make(#"\A---[ \t]*\n[\s\S]*?\n---[ \t]*(?:\n|\z)"#)

    /// Fenced code blocks, including unterminated ones at end of file.
    static let codeBlock = make(#"(?m)^[ \t]*(`{3,}|~{3,})[ \t]*([^\n]*)\n[\s\S]*?(?:^[ \t]*\1[ \t]*$|\z)"#)
    static let inlineCode = make(#"`([^`\n]+)`"#)

    static let mathBlock = make(#"\$\$([\s\S]*?)\$\$"#)
    static let mathInline = make(#"(?<!\$)\$(?!\s)([^\$\n]+?)(?<!\s)\$(?!\$)"#)

    static let comment = make(#"%%[\s\S]*?%%"#)

    static let heading = make(#"(?m)^(#{1,6})[ \t]+(.*?)[ \t]*#*$"#)

    /// `> [!note]+ Optional title` — the callout header line.
    static let callout = make(#"(?m)^[ \t]*>[ \t]*\[!([A-Za-z0-9_-]+)\]([+-]?)[ \t]*(.*)$"#)

    /// `[[target#fragment|alias]]`, optionally prefixed with `!` for embeds.
    static let wikiLink = make(#"!?\[\[([^\[\]\|#]*)(#[^\[\]\|]*)?(\|[^\[\]]*)?\]\]"#)

    static let markdownLink = make(#"!?\[([^\]\n]*)\]\(([^)\s]+)(?:[ \t]+"[^"]*")?\)"#)

    /// A tag must contain at least one non-numeric character, otherwise `#1`
    /// in "issue #1" would be indexed as a tag. Unicode letters are allowed so
    /// `#中文标签` works.
    static let tag = make(#"(?<![\p{L}\p{N}_/#])#([\p{L}\p{N}_/-]*[\p{L}_-][\p{L}\p{N}_/-]*)"#)

    /// Block identifier anchored at end of line: `Some text ^my-block`.
    static let blockIdentifier = make(#"(?m)(?:^|[ \t])\^([A-Za-z0-9][A-Za-z0-9-]*)[ \t]*$"#)

    static let task = make(#"(?m)^[ \t]*[-*+][ \t]+\[(.)\][ \t]+"#)

    static let bold = make(#"(?<!\*)\*\*(?!\s)([^\*]+?)(?<!\s)\*\*(?!\*)"#)
    static let italic = make(#"(?<![\*\w])\*(?!\s|\*)([^\*\n]+?)(?<!\s)\*(?!\*)"#)
    static let strikethrough = make(#"~~(?!\s)([^~]+?)(?<!\s)~~"#)
    static let highlight = make(#"==(?!\s)([^=\n]+?)(?<!\s)=="#)

    static let horizontalRule = make(#"(?m)^[ \t]*(?:-{3,}|\*{3,}|_{3,})[ \t]*$"#)

    private static func make(_ pattern: String) -> NSRegularExpression {
        // Patterns are compile-time constants; a failure here is a programmer
        // error and should surface loudly during development, not at runtime.
        try! NSRegularExpression(pattern: pattern)
    }
}

extension NSRegularExpression {
    fileprivate func matches(in string: String, range: NSRange) -> [NSTextCheckingResult] {
        matches(in: string, options: [], range: range)
    }
}
