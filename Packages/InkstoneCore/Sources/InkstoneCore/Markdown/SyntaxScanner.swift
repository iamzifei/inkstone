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
    /// `>` quote prefix. `depth` counts the nesting of `>` characters.
    case blockquote(depth: Int)
    /// The `-`/`*`/`1.` at the head of a list item. `level` is the indent depth.
    case listMarker(level: Int, ordered: Bool)
    /// A `- [ ]` item. `level` is the indent depth, matching `listMarker`, so a
    /// nested task lines up with the nested bullets around it.
    case task(checked: Bool, level: Int)
    case comment
    case horizontalRule
    case frontmatter
    /// `[^1]` in the body of a note.
    case footnoteReference(id: String)
    /// `[^1]: …` at the start of a line, defining the note.
    case footnoteDefinition(id: String)
    /// `[TOC]` on its own line — a placeholder the renderer replaces with a
    /// table of contents built from the document's headings.
    case tableOfContents
    /// `^text^`
    case superscript
    /// `~text~` — distinct from `~~strikethrough~~`.
    case `subscript`
    /// A whole GFM table block, header and body together.
    case table
    /// The header row of a table, so it can be weighted differently.
    case tableHeaderRow
    /// The `|---|:--:|` alignment row, which is scaffolding rather than content
    /// and is hidden in live preview.
    case tableDelimiterRow
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

    /// The display size Obsidian reads out of an embed's pipe.
    ///
    /// `![[photo.png|300]]` is 300 points wide, `![[photo.png|300x200]]` is that
    /// box exactly. The same pipe means display *text* on an ordinary wikilink,
    /// which is why this is nil unless the alias is nothing but digits — a note
    /// embedded as `![[Meeting|notes]]` is not 0 points wide.
    public struct EmbedSize: Hashable, Sendable {
        public let width: Double
        /// Nil means "keep the picture's own proportions".
        public let height: Double?
    }

    public var embedSize: EmbedSize? {
        guard let alias, !alias.isEmpty else { return nil }
        let parts = alias.split(separator: "x", maxSplits: 1, omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard let width = Double(parts[0]), width > 0 else { return nil }
        guard parts.count == 2 else { return EmbedSize(width: width, height: nil) }
        guard let height = Double(parts[1]), height > 0 else { return nil }
        return EmbedSize(width: width, height: height)
    }
}


/// Finds every syntactic element in a Markdown note.
///
/// Two implementations exist and produce the same `[SyntaxToken]` stream:
///
///   - `.parser` — a real cmark-gfm parse via `swift-markdown`, with the
///     Obsidian-only syntax layered on as regexes over the prose regions the
///     parse isolates. This is the one that runs.
///   - `.legacy` — the original thirty-regex scan over the raw text. Kept only
///     so the two can be diffed token for token on real notes; it is not
///     reachable from the app.
///
/// The reason the switch exists at all is that the port is a behaviour change
/// dressed as a refactor. Every difference between the engines is either a fix
/// or a regression, and the only way to tell which is to be able to run both.
public struct SyntaxScanner: Sendable {
    public enum Engine: Sendable {
        case parser
        case legacy
    }

    public let engine: Engine

    public init(engine: Engine = .parser) {
        self.engine = engine
    }

    public func scan(_ text: String) -> [SyntaxToken] {
        switch engine {
        case .parser: return DocumentScanner().scan(text)
        case .legacy: return LegacyScanner().scan(text)
        }
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
}
