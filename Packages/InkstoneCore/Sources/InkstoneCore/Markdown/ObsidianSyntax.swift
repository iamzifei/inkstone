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

    /// GFM's trailing-punctuation rule: a URL does not end in `.,:;!?'"*_~`,
    /// and a closing `)` is dropped unless the URL opened one.
    static func trimmedURLRange(_ range: NSRange, in text: NSString) -> NSRange {
        var url = text.substring(with: range)
        while let last = url.last {
            if ".,:;!?'\"*_~".contains(last) {
                url.removeLast()
            } else if last == ")", url.filter({ $0 == "(" }).count < url.filter({ $0 == ")" }).count {
                url.removeLast()
            } else {
                break
            }
        }
        return NSRange(location: range.location, length: (url as NSString).length)
    }

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

        // A run of tags, then one token per tag in it: Obsidian starts a tag
        // only after whitespace / line start, or straight after another tag
        // (`#a#b` is two tags). Compared against Obsidian's own rendering of
        // real notes: `……！#短` and `+#tag` are not tags there, `#a#b` is two.
        for match in Patterns.tagRun.matches(in: text, options: [], range: full) {
            guard prose.containsAll(match.range), !claimed.intersects(match.range) else { continue }
            var location = match.range.location
            let end = NSMaxRange(match.range)
            while location < end {
                guard let part = Patterns.tag.firstMatch(
                    in: text, options: [.anchored], range: NSRange(location: location, length: end - location))
                else { break }
                tokens.append(SyntaxToken(kind: .tag(nsText.substring(with: part.range(at: 1))), range: part.range))
                claimed.insert(range: part.range)
                location = NSMaxRange(part.range)
            }
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

        // Bare URLs, which Obsidian (and GFM's autolink extension, which the
        // parser does not enable) turn into links. A plain `https://…` in a
        // note was unclickable text in Inkstone. Emitted as a link whose range
        // is its content, so there is no markup to conceal.
        let existingLinks = tokens.reduce(into: IndexSet()) { set, token in
            if case .markdownLink = token.kind { set.insert(integersIn: Range(token.range) ?? 0..<0) }
        }
        addMatches(Patterns.bareURL) { match, text in
            guard !existingLinks.intersects(integersIn: Range(match.range) ?? 0..<0) else { return nil }
            let range = trimmedURLRange(match.range, in: text)
            guard range.length > 0 else { return nil }
            let url = text.substring(with: range)
            let destination = url.lowercased().hasPrefix("www.") ? "http://" + url : url
            return SyntaxToken(kind: .markdownLink(destination: destination), range: range, contentRange: range)
        }

        // CommonMark rather than Obsidian, and here because of *where* the work
        // has to happen rather than what defines it: cmark resolves escapes and
        // entities into a `Text` node's value and does not report the position of
        // either, so the only way to conceal the source is to find it again. The
        // prose regions are what make that safe — a backslash inside a code span
        // is a backslash.
        //
        // Last, so anything with a meaning of its own has already claimed its
        // text: `\$` inside `$maths$` belongs to the formula.
        addMatches(Patterns.escape, claiming: false) { match, _ in
            // The backslash, not the character it protects: that character is
            // ordinary text and concealing it would delete what was escaped.
            SyntaxToken(kind: .escape, range: NSRange(location: match.range.location, length: 1))
        }
        addMatches(Patterns.entity, claiming: false) { match, text in
            guard let replacement = HTMLEntity.character(for: text.substring(with: match.range))
            else { return nil }
            return SyntaxToken(kind: .entity(replacement), range: match.range)
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
        /// `https://…`, `http://…` or `www.…` not glued to a preceding word.
        /// Stops at whitespace, angle brackets and full-width (CJK)
        /// punctuation, so `https://a.com，然后` links only the URL.
        static let bareURL = make(#"(?<![\p{L}\p{N}/@.:\-])(?:https?://|www\.)[^\s<>\x{3000}-\x{303F}\x{FF00}-\x{FFEF}]+"#)
        static let mathInline = make(#"(?<!\$)\$(?!\s)([^\$\n]+?)(?<!\s)\$(?![\$\d])"#)

        // Obsidian's %%comments%% and HTML <!-- comments --> (which Obsidian
    // also hides when reading; Inkstone's own entry-file markers are these).
    static let comment = make(#"%%[\s\S]*?%%|<!--[\s\S]*?-->"#)

        /// `[[target#fragment|alias]]`, optionally prefixed with `!` for embeds.
        static let wikiLink = make(#"!?\[\[([^\[\]\|#]*)(#[^\[\]\|]*)?(\|[^\[\]]*)?\]\]"#)

        /// A tag must contain at least one non-numeric character, otherwise `#1`
        /// in "issue #1" would be indexed as a tag. Unicode letters are allowed so
        /// `#中文标签` works.
        /// `&` is excluded as well as the rest: `&#x2014;` is an em dash, and
        /// without it the `#x2014` was scanned as a tag — which then claimed the
        /// text and stopped the entity being recognised at all. Found by a test
        /// for entities, not by anyone noticing a stray tag.
        /// Obsidian's tag body, measured against its own rendering: anything
        /// up to whitespace or ASCII punctuation other than `_ - /`. Full-width
        /// (CJK) punctuation is part of a tag there, and a tag may begin with a
        /// digit — it only has to contain a non-digit, so `#1` stays a number.
        /// Characters that end a tag: whitespace and ASCII punctuation other
        /// than `_ - /`.
        private static let tagStop = ##"\s!"#$%&'()*+,.:;<=>?@\[\\\]^`{|}~"##
        private static let tagBody = "[^\(tagStop)]*[^\\d\(tagStop)][^\(tagStop)]*"
        static let tag = make("#(" + tagBody + ")")
        /// One or more tags back to back, starting at line start, after
        /// whitespace, or right after `* _ = ~ [ |` — measured in Obsidian:
        /// `**#a**`, `==#a==`, `~~#a~~` and `[#a]` are tags there, `(#a)`,
        /// `"#a"` and `中文#a` are not.
        static let tagRun = make("(?<![^\\s*_=~\\[|])(?:#" + tagBody + ")+")

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

        /// A backslash escape. The character class is CommonMark's: a backslash
        /// before anything else is a literal backslash, not an escape.
        static let escape = make(#"\\([!-/:-@\[-`{-~])"#)

        /// A named, decimal or hexadecimal HTML entity.
        static let entity = make(#"&(?:#[0-9]{1,7}|#[xX][0-9A-Fa-f]{1,6}|[A-Za-z][A-Za-z0-9]{1,31});"#)

        private static func make(_ pattern: String) -> NSRegularExpression {
            // Patterns are compile-time constants; a failure here is a programmer
            // error and should surface loudly during development, not at runtime.
            try! NSRegularExpression(pattern: pattern)
        }
    }
}
