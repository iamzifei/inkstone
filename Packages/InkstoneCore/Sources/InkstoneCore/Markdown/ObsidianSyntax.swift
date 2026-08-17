import Foundation

/// The syntax Obsidian added that CommonMark and GFM know nothing about.
///
/// cmark cannot be extended to see these — verified against the parser, not
/// assumed: `[[wikilink]]`, `![[embed]]`, `#tag`, `==highlight==`, `$maths$`,
/// `[^footnote]` and `> [!callout]` all arrive as the contents of a single
/// `Text` node. So they stay regex-matched.
///
/// What changed is *where* the regexes run. Before, they ran over the whole file
/// and had to defend themselves against every context they might land in — which
/// is why the old scanner needed a mask built from a code-fence pattern, and why
/// a fence that ended on a newline could let a `#tag` escape from inside a code
/// block. Now they run only over regions the parser has already established are
/// prose. A tag inside a fenced block is not excluded by a rule; it is simply
/// never looked at.
enum ObsidianSyntax {

    /// - Parameters:
    ///   - prose: regions that are ordinary text. A match is kept only if it
    ///     lies *wholly* inside one; a pattern that straddles the boundary
    ///     between prose and code is not a match, it is a coincidence.
    static func scan(
        text: String,
        nsText: NSString,
        prose: IndexSet,
        into tokens: inout [SyntaxToken]
    ) {
        let full = NSRange(location: 0, length: nsText.length)
        // Consumed regions, so a `#tag` inside a `$$formula$$` is part of the
        // formula and a `==mark==` inside a `%%comment%%` is part of the comment.
        // Ordered the same way as the legacy scanner: block constructs claim
        // their text before inline ones get to look at it.
        var claimed = IndexSet()

        func addMatches(
            _ regex: NSRegularExpression,
            claiming: Bool = true,
            _ makeToken: (NSTextCheckingResult, NSString) -> SyntaxToken?
        ) {
            for match in regex.matches(in: text, options: [], range: full) {
                guard prose.containsAll(match.range), !claimed.intersects(match.range) else { continue }
                guard let token = makeToken(match, nsText) else { continue }
                tokens.append(token)
                if claiming { claimed.insert(range: match.range) }
            }
        }

        addMatches(Patterns.mathBlock) { match, _ in
            SyntaxToken(kind: .mathBlock, range: match.range, contentRange: match.range(at: 1))
        }

        addMatches(Patterns.comment) { match, _ in
            SyntaxToken(kind: .comment, range: match.range)
        }

        addMatches(Patterns.wikiLink) { match, text in
            let isEmbed = text.character(at: match.range.location) == 0x21  // "!"
            let link = makeWikiLink(match: match, text: text)
            return SyntaxToken(
                kind: isEmbed ? .embed(link) : .wikiLink(link),
                range: match.range,
                contentRange: match.range(at: 1)
            )
        }

        // Definitions before references: `[^1]: text` at the head of a line is a
        // definition, and its own `[^1]` must not also match as a reference.
        addMatches(Patterns.footnoteDefinition) { match, text in
            SyntaxToken(
                kind: .footnoteDefinition(id: text.substring(with: match.range(at: 1))),
                range: match.range,
                contentRange: match.range(at: 1)
            )
        }
        addMatches(Patterns.footnoteReference) { match, text in
            SyntaxToken(
                kind: .footnoteReference(id: text.substring(with: match.range(at: 1))),
                range: match.range,
                contentRange: match.range(at: 1)
            )
        }

        addMatches(Patterns.tag) { match, text in
            SyntaxToken(kind: .tag(text.substring(with: match.range(at: 1))), range: match.range)
        }

        // Before superscript, which would otherwise claim `^block-id` as `^…^`
        // whenever two identifiers appeared on one line.
        addMatches(Patterns.blockIdentifier) { match, text in
            SyntaxToken(
                kind: .blockIdentifier(text.substring(with: match.range(at: 1))),
                range: match.range
            )
        }

        addMatches(Patterns.tableOfContents) { match, _ in
            SyntaxToken(kind: .tableOfContents, range: match.range)
        }

        addMatches(Patterns.superscript) { match, _ in
            SyntaxToken(kind: .superscript, range: match.range, contentRange: match.range(at: 1))
        }
        addMatches(Patterns.subscript) { match, _ in
            SyntaxToken(kind: .subscript, range: match.range, contentRange: match.range(at: 1))
        }
        addMatches(Patterns.highlight) { match, _ in
            SyntaxToken(kind: .highlight, range: match.range, contentRange: match.range(at: 1))
        }
        addMatches(Patterns.mathInline) { match, _ in
            SyntaxToken(kind: .mathInline, range: match.range, contentRange: match.range(at: 1))
        }
    }

    /// Parses a matched `[[target#fragment|alias]]`.
    static func makeWikiLink(match: NSTextCheckingResult, text: NSString) -> WikiLink {
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

    /// What is left of the regex catalogue. Every pattern here describes syntax
    /// no Markdown parser implements; anything a parser *does* implement was
    /// deleted, not moved.
    enum Patterns {
        static let mathBlock = make(#"\$\$([\s\S]*?)\$\$"#)
        static let mathInline = make(#"(?<!\$)\$(?!\s)([^\$\n]+?)(?<!\s)\$(?!\$)"#)

        static let comment = make(#"%%[\s\S]*?%%"#)

        /// `[[target#fragment|alias]]`, optionally prefixed with `!` for embeds.
        static let wikiLink = make(#"!?\[\[([^\[\]\|#]*)(#[^\[\]\|]*)?(\|[^\[\]]*)?\]\]"#)

        /// A tag must contain at least one non-numeric character, otherwise `#1`
        /// in "issue #1" would be indexed as a tag. Unicode letters are allowed so
        /// `#中文标签` works.
        static let tag = make(#"(?<![\p{L}\p{N}_/#])#([\p{L}\p{N}_/-]*[\p{L}_-][\p{L}\p{N}_/-]*)"#)

        /// Block identifier anchored at end of line: `Some text ^my-block`.
        static let blockIdentifier = make(#"(?m)(?:^|[ \t])\^([A-Za-z0-9][A-Za-z0-9-]*)[ \t]*$"#)

        /// `[^1]: …` — a definition, anchored to the start of a line.
        static let footnoteDefinition = make(#"(?m)^\[\^([^\]\s]+)\]:[ \t]*"#)
        /// `[^1]` used in the body. The lookahead keeps it from swallowing a
        /// definition's own marker.
        static let footnoteReference = make(#"\[\^([^\]\s]+)\](?!:)"#)

        /// `[TOC]` alone on a line, case-insensitively, as Typora accepts it.
        static let tableOfContents = make(#"(?mi)^[ \t]*\[toc\][ \t]*$"#)

        /// `^text^`. Spaces are excluded so `2^10^` works but `a ^ b` is arithmetic.
        static let superscript = make(#"\^(?!\s)([^\^\s]+)(?<!\s)\^"#)
        /// `~text~`, guarded on both sides so `~~strikethrough~~` is not mistaken
        /// for two adjacent subscripts.
        static let `subscript` = make(#"(?<!~)~(?!~|\s)([^~\n]+?)(?<!\s)~(?!~)"#)
        static let highlight = make(#"==(?!\s)([^=\n]+?)(?<!\s)=="#)

        private static func make(_ pattern: String) -> NSRegularExpression {
            // Patterns are compile-time constants; a failure here is a programmer
            // error and should surface loudly during development, not at runtime.
            try! NSRegularExpression(pattern: pattern)
        }
    }
}
