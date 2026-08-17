import Foundation
import Markdown

/// Produces the same `[SyntaxToken]` stream as `LegacyScanner`, but from a real
/// cmark-gfm parse instead of thirty regexes over the raw text.
///
/// The token stream stays the interface on purpose. The highlighter and the
/// renderer are large, work, and know nothing about how tokens are found; making
/// the AST *produce* tokens rather than *replace* them is what lets the two
/// engines be diffed against each other on real notes before either is trusted.
///
/// Division of labour:
///
///   - Everything CommonMark and GFM define — headings, code, lists, tasks,
///     quotes, tables, emphasis, links — comes from the AST, with correct
///     nesting and no possibility of matching inside a fenced block.
///   - Everything Obsidian added on top — `[[wikilinks]]`, `#tags`, `==marks==`,
///     `$maths$`, `[^footnotes]`, callouts — is invisible to cmark and stays
///     regex-matched, but now only over the prose regions the parse has already
///     isolated. That is the part that makes the remaining regexes reliable:
///     they can no longer fire inside code, and no longer have to know what a
///     code fence is.
struct DocumentScanner {

    func scan(_ text: String) -> [SyntaxToken] {
        let nsText = text as NSString
        guard nsText.length > 0 else { return [] }

        var walk = Walk(map: SourceMap(nsText), source: text)

        // Frontmatter is stripped before parsing rather than masked after it.
        // `---\n…\n---` is not inert to cmark: the opening `---` is a thematic
        // break and the closing one turns whatever precedes it into a setext
        // heading, so a parse of the whole file mis-structures the real content
        // that follows. Parsing only the body and shifting every reported line by
        // a constant is exact, because columns are per-line and unaffected.
        var body = text
        if let frontmatter = LegacyScanner.frontmatterRange(in: nsText) {
            walk.tokens.append(SyntaxToken(kind: .frontmatter, range: frontmatter))
            walk.lineOffset = nsText.substring(with: frontmatter)
                .reduce(0) { $0 + ($1 == "\n" ? 1 : 0) }
            body = nsText.substring(from: NSMaxRange(frontmatter))
        }

        // `accept` rather than a `switch markup { case let x as … }` chain.
        // swift-markdown dispatches statically through each node's own `accept`,
        // where the chain cost a run of dynamic casts on every node of the tree —
        // measured at 1.7ms of the 6.5ms walk on a 55KB document.
        walk.visit(Document(parsing: body))
        walk.restoreFootnoteDefinitions(text: text)

        ObsidianSyntax.scan(
            text: text,
            nsText: nsText,
            prose: walk.proseRegions(),
            into: &walk.tokens
        )

        return walk.tokens.sorted { $0.range.location < $1.range.location }
    }

    // MARK: - The walk

    /// Walks the tree and accumulates the token stream.
    ///
    /// A `MarkupVisitor` rather than a hand-written recursion: swift-markdown
    /// gives every node an `accept` that calls the right `visitXxx` directly, so
    /// dispatch is static. The recursion this replaced tried up to eight `as?`
    /// casts per node, which is a runtime conformance lookup each time.
    ///
    /// A struct rather than a class: the walk is single-threaded, and this keeps
    /// the scanner `Sendable` without a lock.
    private struct Walk: MarkupVisitor {
        typealias Result = Void

        let map: SourceMap
        /// The document as a `String`, held once.
        ///
        /// `NSRegularExpression` wants a `String` and `SourceMap` holds an
        /// `NSString`, and `map.text as String` at each call site is not a cast —
        /// it is a bridge that copies. Doing it per blockquote line and per list
        /// item made the walk allocate a fresh copy of the whole document
        /// hundreds of times.
        let source: String
        /// Lines consumed by frontmatter, added to every position cmark reports.
        var lineOffset = 0
        var tokens: [SyntaxToken] = []
        /// Regions that are ordinary prose, and so are the only places the
        /// Obsidian regexes are allowed to match. Built as the walk goes:
        /// paragraph, heading and table-cell interiors, minus inline code and
        /// minus the `(destination)` half of links and images.
        ///
        /// Accumulated as two flat lists and combined into an `IndexSet` once, at
        /// the end. Inserting and removing ranges as the walk found them meant
        /// every inline code span re-coalesced the set in the middle of building
        /// it, and that churn was the single largest cost in the walk.
        var included: [NSRange] = []
        var excluded: [NSRange] = []
        /// Code, fenced or indented. Nothing may be matched inside it.
        var verbatim: [NSRange] = []

        /// The prose regions, as the Obsidian pass wants them.
        func proseRegions() -> IndexSet {
            var set = IndexSet()
            for range in included { set.insert(range: range) }
            for range in excluded { set.remove(range: range) }
            return set
        }

        /// Nesting depth of the list being walked. -1 outside any list, so a
        /// top-level item is level 0.
        var listDepth = -1
        /// Whether an enclosing blockquote has already emitted this line's
        /// markers.
        var insideBlockQuote = false

        // MARK: - Dispatch

        mutating func defaultVisit(_ markup: Markup) { descend(markup) }

        mutating func descend(_ markup: Markup) {
            for child in markup.children { visit(child) }
        }

        // `Markdown.Heading`, qualified: InkstoneCore has a `Heading` of its own
        // (the outline entry in `Note`), and the unqualified name resolves to
        // that one — with a `range` that is already an `NSRange`, so the mistake
        // typechecks halfway and fails somewhere confusing.
        mutating func visitHeading(_ heading: Markdown.Heading) {
            emitHeading(heading)
            descend(heading)
        }

        mutating func visitCodeBlock(_ codeBlock: CodeBlock) { emitCodeBlock(codeBlock) }

        mutating func visitBlockQuote(_ blockQuote: BlockQuote) {
            // Only the outermost quote emits. cmark nests a `> >` as a quote
            // inside a quote, and both cover the same lines, so emitting at every
            // level would give each line as many tokens as it has `>` characters.
            // Depth is recovered by counting the markers on the line itself.
            if !insideBlockQuote { emitBlockQuoteLines(blockQuote) }
            let wasInside = insideBlockQuote
            insideBlockQuote = true
            descend(blockQuote)
            insideBlockQuote = wasInside
        }

        mutating func visitListItem(_ listItem: ListItem) {
            emitListItem(listItem, level: max(0, listDepth))
            descend(listItem)
        }

        mutating func visitUnorderedList(_ list: UnorderedList) { descendList(list) }
        mutating func visitOrderedList(_ list: OrderedList) { descendList(list) }

        private mutating func descendList(_ list: Markup) {
            listDepth += 1
            descend(list)
            listDepth -= 1
        }

        mutating func visitTable(_ table: Table) {
            emitTable(table)
            descend(table)
        }

        mutating func visitThematicBreak(_ thematicBreak: ThematicBreak) {
            guard let range = thematicBreak.range else { return }
            // The AST range takes the trailing newline with it; a token that
            // includes the newline would push its paragraph attributes onto
            // the following line.
            tokens.append(SyntaxToken(
                kind: .horizontalRule,
                range: map.lineContentRange(range.lowerBound.line + lineOffset)
            ))
        }

        mutating func visitParagraph(_ paragraph: Paragraph) {
            if let range = nsRange(paragraph.range) { included.append(range) }
            descend(paragraph)
        }

        /// Puts `[^id]: …` lines back into the prose regions.
        ///
        /// CommonMark's link reference definitions and Obsidian's footnote
        /// definitions have the same shape, and cmark wins the collision: it consumes
        /// `[^why]: Because.` as a definition of the link label `^why`, emits no node
        /// for it, and then resolves `[^why]` elsewhere in the document into a
        /// shortcut reference *link*. The line therefore belongs to no paragraph and
        /// would never be looked at.
        ///
        /// The tell is the `^`. A real link label starting with a caret is not
        /// something anyone writes; a footnote is the only thing this can be.
        mutating func restoreFootnoteDefinitions(text: String) {
            let full = NSRange(location: 0, length: map.text.length)
            for match in Patterns.footnoteDefinitionLine.matches(in: text, options: [], range: full) {
                guard !verbatim.contains(where: { NSIntersectionRange($0, match.range).length > 0 })
                else { continue }
                included.append(map.lineRange(containing: match.range.location))
            }
        }

        // MARK: - Blocks

        private mutating func emitHeading(_ heading: Markdown.Heading) {
            guard let range = nsRange(heading.range) else { return }
            let content = childSpan(of: heading) ?? range
            tokens.append(SyntaxToken(
                kind: .heading(level: heading.level), range: range, contentRange: content
            ))
            // The heading's *content*, not the whole node: the leading `#` characters
            // are syntax, and letting the tag pattern see them would be asking for
            // trouble the moment someone writes `#### 4th`.
            included.append(content)
        }

        private mutating func emitCodeBlock(_ code: CodeBlock) {
            guard let range = nsRange(code.range) else { return }
            let language = code.language?.trimmingCharacters(in: .whitespaces)
            // An indented code block's range covers only the code, not the four
            // spaces that mark it, so it has to be widened to whole lines or the
            // block's background paints halfway into the gutter. There is no flag on
            // the node saying which kind it is, so the opening line is what tells us.
            let block = isFenced(range)
                ? range
                : wholeLines(covering: range)
            tokens.append(SyntaxToken(
                kind: .codeBlock(language: language?.isEmpty == false ? language : nil),
                range: block
            ))
            // Deliberately *not* added to `prose`: this is the whole point.
            verbatim.append(block)
        }

        private mutating func emitBlockQuoteLines(_ quote: BlockQuote) {
            guard let range = quote.range else { return }
            let first = range.lowerBound.line + lineOffset
            let last = range.upperBound.line + lineOffset

            for line in first...max(first, last) {
                let lineRange = map.lineContentRange(line)
                guard lineRange.length > 0 else { continue }
                guard let match = Patterns.quotePrefix.firstMatch(
                    in: source, options: [], range: lineRange
                ), match.range.location == lineRange.location else { continue }

                let markers = match.range(at: 2)
                var depth = 0
                for offset in 0..<markers.length where map.unit(at: markers.location + offset) == 0x3E {
                    depth += 1
                }
                tokens.append(SyntaxToken(
                    kind: .blockquote(depth: depth), range: match.range, contentRange: markers
                ))

                // A callout is a blockquote whose first line opens with `[!type]`.
                // Matched here rather than in the prose pass because the pattern needs
                // the `>` prefix, which is not part of any paragraph's range.
                if line == first,
                   let callout = Patterns.callout.firstMatch(
                       in: source, options: [], range: lineRange
                   ) {
                    let type = map.text.substring(with: callout.range(at: 1)).lowercased()
                    let fold = callout.range(at: 2).length > 0
                        ? map.text.substring(with: callout.range(at: 2)) : ""
                    let titleRange = callout.range(at: 3)
                    let title = titleRange.location != NSNotFound
                        ? map.text.substring(with: titleRange) : ""
                    tokens.append(SyntaxToken(
                        kind: .callout(type: type, folded: fold == "-", title: title),
                        range: callout.range,
                        contentRange: titleRange.location != NSNotFound
                            ? titleRange
                            : NSRange(location: NSMaxRange(callout.range), length: 0)
                    ))
                }
            }
        }

        private mutating func emitListItem(_ item: ListItem, level: Int) {
            guard let itemRange = nsRange(item.range) else { return }
            // The marker is everything before the item's first block of content:
            // `- `, `1. `, or `- [x] ` for a task. Taking it from the gap between the
            // item and its first child means the checkbox and the bullet are measured
            // the same way, and neither has to be re-matched with a regex.
            let contentStart = childSpan(of: item)?.location ?? NSMaxRange(itemRange)
            // The item's range starts at the bullet, but the indent in front of it is
            // part of the marker as far as the editor is concerned: the marker is
            // collapsed to nothing and the indent re-expressed as a paragraph inset,
            // so leaving the literal spaces visible would indent a nested item twice.
            // Walked back rather than taken from the line start, which would swallow
            // the `> ` of a list inside a blockquote.
            let indentStart = startOfIndent(before: itemRange.location)
            let marker = NSRange(
                location: indentStart,
                length: max(0, min(contentStart, NSMaxRange(itemRange)) - indentStart)
            )
            guard marker.length > 0 else { return }

            // Task state is read from the text, not from `item.checkbox`.
            //
            // GFM defines exactly two checkboxes, `[ ]` and `[x]`, and that is all
            // cmark will report. Obsidian allows any single character between the
            // brackets and treats every non-blank one as done — `[/]` in progress,
            // `[-]` cancelled, `[✓]` pasted from somewhere else — and notes in the
            // wild are full of them. Reading the character keeps those working, and
            // keeps the reported range identical to what `TaskMarker.toggled`
            // expects: the whole `- [x] ` prefix.
            let lineEnd = NSMaxRange(map.lineRange(containing: indentStart))
            if let match = Patterns.taskMarker.firstMatch(
                in: source,
                options: [.anchored],
                range: NSRange(location: indentStart, length: lineEnd - indentStart)
            ) {
                let state = match.range(at: 2)
                let checked = map.unit(at: state.location) != 0x20
                tokens.append(SyntaxToken(
                    kind: .task(checked: checked, level: level),
                    range: match.range,
                    contentRange: state
                ))
            } else {
                let delimiter = trimmingWhitespace(marker)
                let ordered = (0x30...0x39).contains(map.unit(at: delimiter.location))
                // `delimiter` is the marker without the indent before it or the
                // space after — an ordered item keeps its number visible, so the
                // range the highlighter tints has to be exactly the number.
                tokens.append(SyntaxToken(
                    kind: .listMarker(level: level, ordered: ordered),
                    range: marker,
                    contentRange: delimiter
                ))
            }
        }

        private mutating func emitTable(_ table: Table) {
            guard var range = nsRange(table.range) else { return }
            // The table's own newline is part of the block.
            //
            // cmark ends the node on the last cell's closing pipe; the regex it
            // replaced consumed each row's newline including the final one. The
            // difference is one character, and it is the character the block's
            // background fill and paragraph spacing are applied through — so the
            // legacy bound is the one that has been looked at on screen, and this
            // matches it rather than tidying it and finding out later.
            if NSMaxRange(range) < map.length,
               SourceMap.isNewline(map.unit(at: NSMaxRange(range))) {
                range.length += 1
            }
            tokens.append(SyntaxToken(kind: .table, range: range))

            guard let headRange = table.head.range else { return }
            let headLine = headRange.lowerBound.line + lineOffset
            tokens.append(SyntaxToken(
                kind: .tableHeaderRow, range: map.lineContentRange(headLine)
            ))
            // The `|---|:--:|` row is consumed by the parser and appears nowhere in
            // the tree — it carries no content, only the alignments, which live on
            // the table itself. It is always the line after the header.
            let delimiter = map.lineContentRange(headLine + 1)
            if delimiter.length > 0 {
                tokens.append(SyntaxToken(kind: .tableDelimiterRow, range: delimiter))
            }

            // A cell is ordinary Markdown, so its interior is prose. Claimed per cell
            // rather than per table so the pipes themselves are never scanned.
            for cell in table.head.cells {
                if let cellRange = nsRange(cell.range) { included.append(cellRange) }
            }
            for row in table.body.rows {
                for cell in row.cells {
                    if let cellRange = nsRange(cell.range) { included.append(cellRange) }
                }
            }
        }

        // MARK: - Inlines

        /// Content span of a delimited inline, or nothing if it is empty.
        private func inlineContent(_ inline: InlineMarkup) -> (NSRange, NSRange)? {
            guard let range = nsRange(inline.range), let content = childSpan(of: inline) else { return nil }
            return (range, content)
        }

        mutating func visitStrong(_ strong: Strong) {
            if let (range, content) = inlineContent(strong) {
                tokens.append(SyntaxToken(kind: .bold, range: range, contentRange: content))
            }
            descend(strong)
        }

        mutating func visitEmphasis(_ emphasis: Emphasis) {
            if let (range, content) = inlineContent(emphasis) {
                tokens.append(SyntaxToken(kind: .italic, range: range, contentRange: content))
            }
            descend(emphasis)
        }

        mutating func visitStrikethrough(_ strikethrough: Strikethrough) {
            if let (range, content) = inlineContent(strikethrough) {
                tokens.append(SyntaxToken(kind: .strikethrough, range: range, contentRange: content))
            }
            descend(strikethrough)
        }

        mutating func visitInlineCode(_ code: InlineCode) {
            guard let range = nsRange(code.range) else { return }
            // An inline code span has no children, so its content is found by
            // stripping the backtick runs — which may be more than one backtick
            // when the code itself contains a backtick.
            tokens.append(SyntaxToken(
                kind: .inlineCode, range: range, contentRange: strippingBackticks(range)
            ))
            // Code is not prose. This is what stops `#tag` inside `` `#tag` ``.
            excluded.append(range)
        }

        mutating func visitLink(_ link: Link) {
            guard let range = nsRange(link.range) else { return }
            // `[^1]` is a footnote reference, not a link — but once its `[^1]: …`
            // definition exists, cmark has a link label to resolve against and
            // hands back a shortcut reference link. Leaving it whole keeps it in
            // prose for the footnote pattern to claim.
            guard !isFootnoteBracket(range) else { return }
            emitLink(destination: link.destination ?? "", range: range, node: link)
            descend(link)
        }

        mutating func visitImage(_ image: Image) {
            guard let range = nsRange(image.range) else { return }
            emitLink(destination: image.source ?? "", range: range, node: image)
            descend(image)
        }

        private mutating func emitLink(destination: String, range: NSRange, node: Markup) {
            let content = childSpan(of: node) ?? range
            tokens.append(SyntaxToken(
                kind: .markdownLink(destination: destination), range: range, contentRange: content
            ))
            // The `(destination)` half is not prose: a URL fragment is not a tag.
            excluded.append(NSRange(
                location: NSMaxRange(content), length: max(0, NSMaxRange(range) - NSMaxRange(content))
            ))
        }

        // MARK: - Range helpers

        private func nsRange(_ source: SourceRange?) -> NSRange? {
            guard let source else { return nil }
            let range = map.range(
                fromLine: source.lowerBound.line + lineOffset,
                fromColumn: source.lowerBound.column,
                toLine: source.upperBound.line + lineOffset,
                toColumn: source.upperBound.column
            )
            return range.length > 0 ? range : nil
        }

        /// The span from the first child's start to the last child's end — a node's
        /// content, with its delimiters left outside.
        ///
        /// Not simply `first.range` to `last.range`: a `SoftBreak` carries no range
        /// at all, so a multi-line paragraph's last child may be range-less and the
        /// last *positioned* child is the one that matters.
        private func childSpan(of markup: Markup) -> NSRange? {
            var start: Int?
            var end: Int?
            for child in markup.children {
                guard let range = nsRange(child.range) else { continue }
                if start == nil { start = range.location }
                end = max(end ?? 0, NSMaxRange(range))
            }
            guard let start, let end, end > start else { return nil }
            return NSRange(location: start, length: end - start)
        }

        /// Start of the run of spaces and tabs immediately before `location`, not
        /// crossing a line break.
        private func startOfIndent(before location: Int) -> Int {
            var start = location
            while start > 0 {
                let unit = map.unit(at: start - 1)
                guard unit == 0x20 || unit == 0x09 else { break }
                start -= 1
            }
            return start
        }

        /// Whether a bracketed run opens with `[^`, the shape of a footnote marker.
        private func isFootnoteBracket(_ range: NSRange) -> Bool {
            guard range.length >= 2 else { return false }
            return map.unit(at: range.location) == 0x5B      // [
                && map.unit(at: range.location + 1) == 0x5E  // ^
        }

        /// Whether a code block is fenced rather than indented, judged by its first
        /// line — the AST does not record which form was used.
        private func isFenced(_ range: NSRange) -> Bool {
            let line = map.lineRange(containing: range.location)
            for offset in 0..<line.length {
                let unit = map.unit(at: line.location + offset)
                if unit == 0x20 || unit == 0x09 { continue }        // leading indent
                return unit == 0x60 || unit == 0x7E                 // ` or ~
            }
            return false
        }

        /// Widens a range to cover whole lines, newline excluded at the end.
        private func wholeLines(covering range: NSRange) -> NSRange {
            let map = map
            let first = map.lineRange(containing: range.location)
            let lastStart = min(max(range.location, NSMaxRange(range) - 1), max(0, map.length - 1))
            var last = map.lineRange(containing: lastStart)
            while last.length > 0, SourceMap.isNewline(map.unit(at: NSMaxRange(last) - 1)) {
                last.length -= 1
            }
            return NSRange(location: first.location, length: max(0, NSMaxRange(last) - first.location))
        }

        private func trimmingWhitespace(_ range: NSRange) -> NSRange {
            let map = map
            var start = range.location
            var end = NSMaxRange(range)
            while start < end, isWhitespace(map.unit(at: start)) { start += 1 }
            while end > start, isWhitespace(map.unit(at: end - 1)) { end -= 1 }
            return NSRange(location: start, length: end - start)
        }

        private func isWhitespace(_ unit: UInt16) -> Bool {
            unit == 0x20 || unit == 0x09 || unit == 0x0A || unit == 0x0D
        }

        /// The interior of an inline code span, with its delimiting backtick runs and
        /// the single optional padding space either side removed.
        private func strippingBackticks(_ range: NSRange) -> NSRange {
            let map = map
            var start = range.location
            var end = NSMaxRange(range)
            while start < end, map.unit(at: start) == 0x60 { start += 1 }
            while end > start, map.unit(at: end - 1) == 0x60 { end -= 1 }
            guard end > start else { return range }
            return NSRange(location: start, length: end - start)
        }

        private enum Patterns {
            /// The `>` prefix of a quoted line, including nested `> >`.
            static let quotePrefix = make(#"^([ \t]*)((?:>[ \t]?)+)"#)
            /// `> [!note]+ Optional title` — the callout header line.
            static let callout = make(#"^[ \t]*>[ \t]*\[!([A-Za-z0-9_-]+)\]([+-]?)[ \t]*(.*)$"#)

            /// A list item's checkbox, with any single character as its state.
            static let taskMarker = make(#"([ \t]*)[-*+][ \t]+\[(.)\][ \t]+"#)

            /// `[^id]: ` at the start of a line.
            static let footnoteDefinitionLine = make(#"(?m)^\[\^[^\]\s]+\]:"#)

            private static func make(_ pattern: String) -> NSRegularExpression {
                try! NSRegularExpression(pattern: pattern)
            }
        }
    }
}

extension IndexSet {
    /// Adds a UTF-16 range.
    mutating func insert(range: NSRange) {
        guard range.length > 0, range.location != NSNotFound else { return }
        insert(integersIn: range.location..<NSMaxRange(range))
    }

    /// Removes a UTF-16 range.
    mutating func remove(range: NSRange) {
        guard range.length > 0, range.location != NSNotFound else { return }
        remove(integersIn: range.location..<NSMaxRange(range))
    }

    /// Whether *every* index of `range` is present.
    func containsAll(_ range: NSRange) -> Bool {
        guard range.length > 0, range.location != NSNotFound else { return false }
        return contains(integersIn: range.location..<NSMaxRange(range))
    }

    /// Whether any part of `range` is present.
    func intersects(_ range: NSRange) -> Bool {
        guard range.length > 0, range.location != NSNotFound else { return false }
        return intersects(integersIn: range.location..<NSMaxRange(range))
    }
}
