import Foundation

/// Single-pass-ish scanner over raw Markdown source.
///
/// Implemented with `NSRegularExpression` rather than a hand-written lexer: the
/// patterns are the spec here, they run in a few milliseconds on notes of
/// realistic size, and code regions are masked out first so a `#hashtag` inside a
/// fenced block never becomes a tag.
struct LegacyScanner: Sendable {
    func scan(_ text: String) -> [SyntaxToken] {
        let nsText = text as NSString
        let full = NSRange(location: 0, length: nsText.length)

        var tokens: [SyntaxToken] = []
        // An IndexSet, not an array of ranges.
        //
        // `isMasked` runs once per regex match, and the masked set grows with the
        // document, so a linear scan made the whole pass quadratic: a 55KB note
        // took 39ms to scan — over a frame, on every keystroke — and a 223KB one
        // took 517ms. IndexSet keeps sorted, coalesced ranges and answers
        // intersection queries in logarithmic time.
        var maskedRegions = IndexSet()

        // Frontmatter is masked so its YAML `#comments` and `[[values]]` don't
        // leak into the token stream as tags and links.
        if let frontmatterRange = Self.frontmatterRange(in: nsText) {
            tokens.append(SyntaxToken(kind: .frontmatter, range: frontmatterRange))
            maskedRegions.insert(range: frontmatterRange)
        }

        for match in LegacyPatterns.codeBlock.matches(in: text, range: full) {
            let language = match.range(at: 2).location != NSNotFound
                ? nsText.substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespaces)
                : nil
            tokens.append(SyntaxToken(
                kind: .codeBlock(language: language?.isEmpty == false ? language : nil),
                range: match.range
            ))
            maskedRegions.insert(range: match.range)
        }

        // Tables are emitted before the inline patterns so the block-level
        // attributes land first, but deliberately *not* masked: a cell can hold
        // bold text, a [[wikilink]] or a #tag, and those must still be scanned.
        for match in LegacyPatterns.table.matches(in: text, range: full)
        where !maskedRegions.intersects(match.range) {
            tokens.append(contentsOf: tableTokens(for: match.range, in: nsText))
        }

        for match in LegacyPatterns.mathBlock.matches(in: text, range: full)
        where !maskedRegions.intersects(match.range) {
            tokens.append(SyntaxToken(kind: .mathBlock, range: match.range, contentRange: match.range(at: 1)))
            maskedRegions.insert(range: match.range)
        }

        for match in LegacyPatterns.comment.matches(in: text, range: full)
        where !maskedRegions.intersects(match.range) {
            tokens.append(SyntaxToken(kind: .comment, range: match.range))
            maskedRegions.insert(range: match.range)
        }

        for match in LegacyPatterns.inlineCode.matches(in: text, range: full)
        where !maskedRegions.intersects(match.range) {
            tokens.append(SyntaxToken(kind: .inlineCode, range: match.range, contentRange: match.range(at: 1)))
            maskedRegions.insert(range: match.range)
        }

        // From here on, every pattern respects the mask.
        func addMatches(
            _ regex: NSRegularExpression,
            _ makeToken: (NSTextCheckingResult, NSString) -> SyntaxToken?
        ) {
            for match in regex.matches(in: text, range: full) {
                guard !maskedRegions.intersects(match.range) else { continue }
                if let token = makeToken(match, nsText) { tokens.append(token) }
            }
        }

        addMatches(LegacyPatterns.heading) { match, text in
            let level = match.range(at: 1).length
            return SyntaxToken(kind: .heading(level: level), range: match.range, contentRange: match.range(at: 2))
        }

        addMatches(LegacyPatterns.blockquote) { match, text in
            let markers = text.substring(with: match.range(at: 2))
            return SyntaxToken(
                kind: .blockquote(depth: markers.filter { $0 == ">" }.count),
                range: match.range,
                contentRange: match.range(at: 2)
            )
        }

        addMatches(LegacyPatterns.listMarker) { match, text in
            let indent = text.substring(with: match.range(at: 1))
            let marker = text.substring(with: match.range(at: 2))
            // A tab counts as one level; spaces are grouped in pairs, which is
            // what both Obsidian and most Markdown formatters emit.
            let spaces = indent.reduce(0) { $0 + ($1 == "\t" ? 2 : 1) }
            return SyntaxToken(
                kind: .listMarker(level: spaces / 2, ordered: marker.first?.isNumber == true),
                range: match.range,
                contentRange: match.range(at: 2)
            )
        }

        addMatches(LegacyPatterns.callout) { match, text in
            let type = text.substring(with: match.range(at: 1)).lowercased()
            let foldMarker = match.range(at: 2).length > 0 ? text.substring(with: match.range(at: 2)) : ""
            let title = match.range(at: 3).location != NSNotFound
                ? text.substring(with: match.range(at: 3)) : ""
            // contentRange points at the title so the renderer can conceal the
            // `[!type]` marker in front of it while keeping the words visible.
            return SyntaxToken(
                kind: .callout(type: type, folded: foldMarker == "-", title: title),
                range: match.range,
                contentRange: match.range(at: 3).location != NSNotFound
                    ? match.range(at: 3)
                    : NSRange(location: match.range.location + match.range.length, length: 0)
            )
        }

        addMatches(LegacyPatterns.wikiLink) { match, text in
            let isEmbed = text.substring(with: match.range).hasPrefix("!")
            let link = Self.makeWikiLink(match: match, text: text)
            return SyntaxToken(
                kind: isEmbed ? .embed(link) : .wikiLink(link),
                range: match.range,
                contentRange: match.range(at: 1)
            )
        }

        addMatches(LegacyPatterns.markdownLink) { match, text in
            SyntaxToken(
                kind: .markdownLink(destination: text.substring(with: match.range(at: 2))),
                range: match.range,
                contentRange: match.range(at: 1)
            )
        }

        addMatches(LegacyPatterns.tag) { match, text in
            SyntaxToken(kind: .tag(text.substring(with: match.range(at: 1))), range: match.range)
        }

        addMatches(LegacyPatterns.blockIdentifier) { match, text in
            SyntaxToken(kind: .blockIdentifier(text.substring(with: match.range(at: 1))), range: match.range(at: 0))
        }

        addMatches(LegacyPatterns.task) { match, text in
            let indent = text.substring(with: match.range(at: 1))
            let marker = text.substring(with: match.range(at: 2))
            let spaces = indent.reduce(0) { $0 + ($1 == "\t" ? 2 : 1) }
            return SyntaxToken(
                kind: .task(checked: marker != " ", level: spaces / 2),
                range: match.range,
                contentRange: match.range(at: 2)
            )
        }

        // Footnote definitions before references: `[^1]: text` at the head of a
        // line is a definition, and its `[^1]` must not also match as a
        // reference to itself.
        addMatches(LegacyPatterns.footnoteDefinition) { match, text in
            SyntaxToken(
                kind: .footnoteDefinition(id: text.substring(with: match.range(at: 1))),
                range: match.range,
                contentRange: match.range(at: 1)
            )
        }
        addMatches(LegacyPatterns.footnoteReference) { match, text in
            SyntaxToken(
                kind: .footnoteReference(id: text.substring(with: match.range(at: 1))),
                range: match.range,
                contentRange: match.range(at: 1)
            )
        }

        addMatches(LegacyPatterns.tableOfContents) { match, _ in
            SyntaxToken(kind: .tableOfContents, range: match.range)
        }

        addMatches(LegacyPatterns.superscript) { match, _ in
            SyntaxToken(kind: .superscript, range: match.range, contentRange: match.range(at: 1))
        }
        addMatches(LegacyPatterns.subscript) { match, _ in
            SyntaxToken(kind: .subscript, range: match.range, contentRange: match.range(at: 1))
        }

        addMatches(LegacyPatterns.bold) { match, _ in
            SyntaxToken(kind: .bold, range: match.range, contentRange: match.range(at: 1))
        }
        addMatches(LegacyPatterns.italic) { match, _ in
            SyntaxToken(kind: .italic, range: match.range, contentRange: match.range(at: 1))
        }
        addMatches(LegacyPatterns.strikethrough) { match, _ in
            SyntaxToken(kind: .strikethrough, range: match.range, contentRange: match.range(at: 1))
        }
        addMatches(LegacyPatterns.highlight) { match, _ in
            SyntaxToken(kind: .highlight, range: match.range, contentRange: match.range(at: 1))
        }
        addMatches(LegacyPatterns.mathInline) { match, _ in
            SyntaxToken(kind: .mathInline, range: match.range, contentRange: match.range(at: 1))
        }
        addMatches(LegacyPatterns.horizontalRule) { match, _ in
            SyntaxToken(kind: .horizontalRule, range: match.range)
        }


        return tokens.sorted { $0.range.location < $1.range.location }
    }

    // MARK: - Convenience extraction

    func links(in text: String) -> [WikiLink] {
        scan(text).compactMap { token in
            switch token.kind {
            case .wikiLink(let link), .embed(let link): return link
            default: return nil
            }
        }
    }

    /// Inline `#tags`, excluding those inside code, comments, or frontmatter.
    /// Nested tags contribute their ancestors too, so `#a/b` also matches `#a`.
    func tags(in text: String) -> [String] {
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

    /// Splits a matched table block into the whole-block token plus a token for
    /// the header row and one for the alignment row.
    ///
    /// The renderer needs the three separately: the block gets a monospaced font
    /// so columns line up, the header gets weight, and the alignment row is
    /// hidden in live preview because it carries no information a reader wants.
    private func tableTokens(for blockRange: NSRange, in text: NSString) -> [SyntaxToken] {
        var tokens = [SyntaxToken(kind: .table, range: blockRange)]

        var lineStart = blockRange.location
        let blockEnd = blockRange.location + blockRange.length
        var lineIndex = 0

        while lineStart < blockEnd, lineIndex < 2 {
            let lineRange = text.lineRange(for: NSRange(location: lineStart, length: 0))
            // Clip to the block and drop the trailing newline so the attribute
            // does not bleed into the following paragraph.
            let end = min(lineRange.location + lineRange.length, blockEnd)
            var length = end - lineRange.location
            while length > 0,
                  let last = Unicode.Scalar(text.character(at: lineRange.location + length - 1)),
                  CharacterSet.newlines.contains(last) {
                length -= 1
            }

            if length > 0 {
                let trimmed = NSRange(location: lineRange.location, length: length)
                tokens.append(SyntaxToken(
                    kind: lineIndex == 0 ? .tableHeaderRow : .tableDelimiterRow,
                    range: trimmed
                ))
            }

            lineStart = lineRange.location + lineRange.length
            lineIndex += 1
        }

        return tokens
    }

    static func frontmatterRange(in text: NSString) -> NSRange? {
        guard text.hasPrefix("---") else { return nil }
        let full = NSRange(location: 0, length: text.length)
        guard let match = LegacyPatterns.frontmatter.firstMatch(in: text as String, range: full),
              match.range.location == 0 else { return nil }
        return match.range
    }

}

/// The regex catalogue. Kept in one place so the syntax "spec" is reviewable.
private enum LegacyPatterns {
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

    static let task = make(#"(?m)^([ \t]*)[-*+][ \t]+\[(.)\][ \t]+"#)

    static let bold = make(#"(?<!\*)\*\*(?!\s)([^\*]+?)(?<!\s)\*\*(?!\*)"#)
    static let italic = make(#"(?<![\*\w])\*(?!\s|\*)([^\*\n]+?)(?<!\s)\*(?!\*)"#)
    static let strikethrough = make(#"~~(?!\s)([^~]+?)(?<!\s)~~"#)

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

    static let horizontalRule = make(#"(?m)^[ \t]*(?:-{3,}|\*{3,}|_{3,})[ \t]*$"#)

    /// The `>` prefix of a quoted line, including nested `> >`.
    static let blockquote = make(#"(?m)^([ \t]*)((?:>[ \t]?)+)"#)

    /// A list item's leading marker. The lookahead skips `- [ ]` task items,
    /// which are scanned separately and rendered as checkboxes rather than
    /// bullets; without it every task would get both treatments.
    static let listMarker = make(#"(?m)^([ \t]*)([-*+]|\d+[.)])[ \t]+(?!\[.\][ \t])"#)

    /// A GFM table: a header row, an alignment row, then zero or more body rows.
    /// Requires the leading and trailing pipes — the pipe-less form GFM also
    /// allows is ambiguous with ordinary prose containing a `|`, and every editor
    /// that writes these files (Obsidian included) emits the fenced form.
    static let table = make(
        #"(?m)^[ \t]*\|[^\n]*\|[ \t]*\n"#          // header row
        + #"[ \t]*\|(?:[ \t]*:?-+:?[ \t]*\|)+[ \t]*\n"#  // |---|:--:| alignment row
        + #"(?:[ \t]*\|[^\n]*\|[ \t]*(?:\n|\z))*"#       // body rows
    )

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
