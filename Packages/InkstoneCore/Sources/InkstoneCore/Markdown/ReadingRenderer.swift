import Foundation

/// A note with its Markdown syntax *removed*, plus where the styling goes.
///
/// This is what reading mode renders. Live preview hides the syntax characters
/// by giving them a 0.01pt clear font — they are still in the document, still
/// selectable, still copied, and they reappear the moment the caret lands on
/// their line. That is exactly right for editing and wrong for reading.
///
/// Here the delimiters are gone. `**bold**` is four characters shorter, copying
/// a paragraph gives prose rather than markup, and nothing reappears because
/// there is no caret.
///
/// Deliberately not a view: it is text and ranges, which means the decisions
/// — what a task list looks like when nobody can tick it, whether a fence is
/// part of the code — are testable without a text view or a simulator.
public struct ReadingDocument: Sendable, Equatable {
    public struct Span: Sendable, Hashable {
        public enum Style: Hashable, Sendable {
            case heading(level: Int)
            case bold
            case italic
            case strikethrough
            case highlight
            case inlineCode
            case codeBlock(language: String?)
            case link(target: String)
            /// `![[file]]` — a picture, a PDF, or another note's content. The
            /// renderer leaves the target's name as text; whoever draws this can
            /// swap in the file itself and fall back to the name if it cannot.
            case embed(target: String)
            /// LaTeX, with the delimiters already removed.
            case math(display: Bool)
            case tag(String)
            case quote(depth: Int)
            case table
            case horizontalRule
            /// A note's frontmatter, kept as text and styled as the aside it is.
            case properties
        }

        public let style: Style
        /// UTF-16 range **in the rendered text**, not in the source.
        public let range: NSRange

        public init(style: Style, range: NSRange) {
            self.style = style
            self.range = range
        }
    }

    public let text: String
    public let spans: [Span]

    public init(text: String, spans: [Span]) {
        self.text = text
        self.spans = spans
    }
}

public enum ReadingRenderer {
    /// Renders `markdown` for reading.
    ///
    /// Reuses the same `SyntaxScanner` the editor and the index use, so "what is
    /// a tag" keeps one definition. What this adds is the deletion pass and the
    /// coordinate mapping that has to come with it.
    /// - Parameter isLinkable: Answers whether a path written as prose points at
    ///   a file that exists. Defaults to "no", which keeps this a pure function
    ///   and means the renderer never invents a link on its own — the existing
    ///   rule is that a link going nowhere is worse than no link, and only a
    ///   caller holding the vault can tell the difference.
    public static func render(
        _ markdown: String,
        scanner: SyntaxScanner = SyntaxScanner(),
        isLinkable: (String) -> Bool = { _ in false }
    ) -> ReadingDocument {
        let source = markdown as NSString
        let tokens = scanner.scan(markdown)

        // 1. Everything to delete, as ranges in the *source*.
        var cuts: [NSRange] = []
        // 2. Text to substitute in place, for the few things that read better as
        //    a symbol than as their markup.
        var substitutions: [(range: NSRange, text: String)] = []

        for token in tokens {
            switch token.kind {
            // Frontmatter keeps its contents and loses its `---` rules.
            //
            // It used to be deleted whole, which threw away a note's properties
            // — and on a header written with full-width colons (`编号：N19`),
            // which YAML reads as one long scalar rather than a mapping, it threw
            // away a dozen lines of the author's own text. The same mistake had
            // already been made once in live preview. Reading mode may restyle
            // anything; it may not lose anything.
            case .frontmatter:
                cuts.append(contentsOf: fenceLines(of: token, in: source))

            // A comment is the one thing here that is *meant* to disappear —
            // `%%like this%%` is Obsidian's "don't render me". Only the comment,
            // though: cutting its whole line took the prose either side of it
            // with it, so `text %%note%% more` rendered as nothing at all.
            case .comment:
                cuts.append(token.range)

            // Fences go; the code between them stays.
            case .codeBlock, .mathBlock:
                cuts.append(contentsOf: fenceLines(of: token, in: source))

            // Inline pairs: drop the delimiters either side of the content.
            case .bold, .italic, .strikethrough, .highlight, .inlineCode,
                 .superscript, .subscript, .mathInline:
                cuts.append(contentsOf: delimiters(of: token))

            // `> [!note] Title` reads as `Title`. The marker is scaffolding; the
            // title is the author's words.
            case .callout:
                if let marker = calloutMarker(of: token, in: source) { cuts.append(marker) }

            // `# ` at the head of a heading.
            case .heading:
                cuts.append(leading(of: token))

            // `> ` on a quote. Not `leading(of:)`: a blockquote token's content
            // range is the whole line, so that would cut nothing and the angle
            // brackets would survive into the rendered text.
            case .blockquote:
                if let marker = quoteMarker(of: token, in: source) { cuts.append(marker) }

            // A link reads as what it shows. Replaced wholesale rather than
            // trimmed, because `[[Note|shown]]` and `[[Note#Heading]]` put the
            // displayed text in different places and `displayText` already knows
            // which. `#tag` keeps its hash — without it a tag is just a word.
            case .wikiLink(let link), .embed(let link):
                substitutions.append((token.range, link.displayText))
            case .markdownLink:
                cuts.append(contentsOf: delimiters(of: token))

            case .listMarker(_, let ordered):
                // An ordered list keeps its numbers — they carry meaning. A
                // bullet becomes a bullet, which is what the `-` was standing in
                // for all along.
                if !ordered {
                    substitutions.append((token.range, bullet(for: token, in: source)))
                }

            case .task(let checked, _):
                // Nobody can tick a box in reading mode, so it is drawn rather
                // than offered: a box that does not respond to a click is worse
                // than a symbol that never claimed to.
                substitutions.append((token.range, checked ? "☑ " : "☐ "))

            case .horizontalRule:
                substitutions.append((lineRange(token.range, in: source), "───"))

            // A table is left as its source here and rebuilt as a real table by
            // whoever draws this. The span says where it is.
            case .table:
                break

            default:
                break
            }
        }

        // 3. Apply, back to front, so earlier offsets stay valid.
        var edits = cuts.map { (range: $0, text: "") } + substitutions
        edits = merge(edits)
        edits.sort { $0.range.location > $1.range.location }

        let rendered = NSMutableString(string: markdown)
        // The map from a source offset to a rendered offset, built as we go.
        var shifts: [(from: Int, delta: Int)] = []
        for edit in edits {
            guard edit.range.location >= 0,
                  NSMaxRange(edit.range) <= rendered.length else { continue }
            rendered.replaceCharacters(in: edit.range, with: edit.text)
            shifts.append((edit.range.location, (edit.text as NSString).length - edit.range.length))
        }
        shifts.sort { $0.from < $1.from }

        func map(_ offset: Int) -> Int {
            var moved = offset
            for shift in shifts where shift.from < offset {
                moved += shift.delta
            }
            return max(0, min(moved, rendered.length))
        }

        // 4. Style spans, in the rendered coordinate system.
        var spans: [ReadingDocument.Span] = []
        for token in tokens {
            guard let style = style(of: token) else { continue }

            // A link was replaced whole, so its content range no longer describes
            // anything — the span is the substituted text, starting where the
            // token did.
            if let replacement = displayText(of: token) {
                let start = map(token.range.location)
                let length = (replacement as NSString).length
                guard length > 0, start + length <= rendered.length else { continue }
                spans.append(.init(style: style, range: NSRange(location: start, length: length)))
                continue
            }

            let start = map(token.contentRange.location)
            let end = map(NSMaxRange(token.contentRange))
            guard end > start else { continue }
            spans.append(.init(style: style, range: NSRange(location: start, length: end - start)))
        }

        spans += pathSpans(in: rendered, avoiding: spans, isLinkable: isLinkable)

        return ReadingDocument(text: rendered as String, spans: spans)
    }

    // MARK: - Pieces

    private static func style(of token: SyntaxToken) -> ReadingDocument.Span.Style? {
        switch token.kind {
        case .heading(let level): .heading(level: level)
        case .bold: .bold
        case .italic: .italic
        case .strikethrough: .strikethrough
        case .highlight: .highlight
        case .inlineCode: .inlineCode
        case .codeBlock(let language): .codeBlock(language: language)
        case .wikiLink(let link): .link(target: link.target)
        case .embed(let link): .embed(target: link.target)
        case .mathInline: .math(display: false)
        case .mathBlock: .math(display: true)
        case .markdownLink(let destination): .link(target: destination)
        case .tag(let name): .tag(name)
        case .blockquote(let depth): .quote(depth: depth)
        case .table: .table
        case .horizontalRule: .horizontalRule
        case .frontmatter: .properties
        default: nil
        }
    }

    /// A table's cells, or nil if the block does not parse as one.
    ///
    /// Only the structure. Drawing it is the view's job, and it draws a real
    /// `NSTextTable` — **not** box-drawing characters, which was the first
    /// attempt and does not work. Measured with `NSAttributedString`, a CJK
    /// character in SF Mono is **1.61×** the width of an ASCII one and in Menlo
    /// **1.66×**, because neither font contains CJK glyphs and the fallback is
    /// not a multiple of the monospaced advance. Padding `列一` as though it were
    /// two ASCII columns puts every rule after it out of true on screen, however
    /// neatly the characters line up in a string.
    ///
    /// - Returns: the rows, and how many of them are header rows (0 when the
    ///   source had no `| --- |` line).
    public static func tableRows(_ block: String) -> (rows: [[String]], headerRows: Int)? {
        let lines = block.components(separatedBy: "\n")
        var rows: [[String]] = []
        var headerRows = 0

        for (offset, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                // Blank lines only at the very end; one in the middle means this
                // is not a single table and it is left alone.
                if offset == lines.count - 1 { continue }
                return nil
            }
            guard trimmed.hasPrefix("|") else { return nil }
            // The alignment row carries no content of its own. It says where the
            // header ends, which is the one thing worth keeping from it.
            if trimmed.contains("-"),
               trimmed.allSatisfy({ $0 == "|" || $0 == "-" || $0 == ":" || $0 == " " }) {
                headerRows = rows.count
                continue
            }
            rows.append(trimmed
                .trimmingCharacters(in: CharacterSet(charactersIn: "|"))
                .components(separatedBy: "|")
                .map { $0.trimmingCharacters(in: .whitespaces) })
        }
        guard rows.count > 1 else { return nil }

        // Ragged rows are squared off, so a short one cannot leave the table
        // open at the end.
        let columns = rows.map(\.count).max() ?? 0
        let squared = rows.map { row in
            row + [String](repeating: "", count: columns - row.count)
        }
        return (squared, headerRows)
    }


    /// The `[!type]` marker at the head of a callout, and the space after it.
    private static func calloutMarker(of token: SyntaxToken, in source: NSString) -> NSRange? {
        let line = source.lineRange(for: NSRange(location: token.range.location, length: 0))
        let text = source.substring(with: line)
        guard let open = text.range(of: "[!"), let close = text.range(of: "]", range: open.upperBound..<text.endIndex)
        else { return nil }
        var end = text.index(after: close.lowerBound)
        // Take the space after it too, and the `+`/`-` fold marker if present.
        while end < text.endIndex, text[end] == "+" || text[end] == "-" || text[end] == " " {
            end = text.index(after: end)
        }
        let start = text.distance(from: text.startIndex, to: open.lowerBound)
        let length = text.distance(from: open.lowerBound, to: end)
        // Distances are in Characters; the range has to be in UTF-16.
        let prefix = String(text[text.startIndex..<open.lowerBound])
        let body = String(text[open.lowerBound..<end])
        _ = start
        return NSRange(location: line.location + (prefix as NSString).length,
                       length: (body as NSString).length)
    }

    /// The `>` characters, and the space after them, at the head of a quote line.
    private static func quoteMarker(of token: SyntaxToken, in source: NSString) -> NSRange? {
        let line = source.lineRange(for: NSRange(location: token.range.location, length: 0))
        var index = line.location
        var sawAngle = false
        while index < NSMaxRange(line) {
            let character = source.character(at: index)
            if character == 0x3E {          // >
                sawAngle = true
                index += 1
            } else if character == 0x20 || character == 0x09 {
                index += 1
            } else {
                break
            }
        }
        guard sawAngle, index > line.location else { return nil }
        return NSRange(location: line.location, length: index - line.location)
    }

    /// What a link token was replaced by, if it was replaced at all.
    private static func displayText(of token: SyntaxToken) -> String? {
        switch token.kind {
        case .wikiLink(let link), .embed(let link): link.displayText
        default: nil
        }
    }

    /// The delimiter ranges either side of a token's content.
    private static func delimiters(of token: SyntaxToken) -> [NSRange] {
        let leading = NSRange(
            location: token.range.location,
            length: token.contentRange.location - token.range.location
        )
        let trailingStart = NSMaxRange(token.contentRange)
        let trailing = NSRange(
            location: trailingStart,
            length: NSMaxRange(token.range) - trailingStart
        )
        return [leading, trailing].filter { $0.length > 0 && $0.location >= 0 }
    }

    private static func leading(of token: SyntaxToken) -> NSRange {
        NSRange(
            location: token.range.location,
            length: max(0, token.contentRange.location - token.range.location)
        )
    }

    /// The whole lines a range sits on, including the newline that ends them.
    private static func lineRange(_ range: NSRange, in source: NSString) -> NSRange {
        guard range.location < source.length else { return range }
        var lines = source.lineRange(for: NSRange(location: range.location, length: 0))
        let end = min(NSMaxRange(range), source.length)
        if end > NSMaxRange(lines) {
            lines = NSUnionRange(lines, source.lineRange(for: NSRange(location: end - 1, length: 0)))
        }
        return lines
    }

    /// The opening and closing fence lines of a code block.
    private static func fenceLines(of token: SyntaxToken, in source: NSString) -> [NSRange] {
        let block = lineRange(token.range, in: source)
        guard block.length > 0 else { return [] }
        let first = source.lineRange(for: NSRange(location: block.location, length: 0))
        let lastStart = max(block.location, NSMaxRange(block) - 1)
        let last = source.lineRange(for: NSRange(location: lastStart, length: 0))
        // A block whose fences are the same line is not a block.
        guard last.location > first.location else { return [first] }
        return [first, last]
    }

    /// The bullet a list marker becomes, indented as deeply as it was.
    private static func bullet(for token: SyntaxToken, in source: NSString) -> String {
        let text = source.substring(with: token.range)
        let indent = text.prefix { $0 == " " || $0 == "\t" }
        return indent + "• "
    }

    /// Drops edits contained inside other edits, and merges overlaps.
    ///
    /// Without this a `**bold**` inside a heading has its delimiters cut twice —
    /// once by its own token and once by the heading's — and the second cut
    /// lands on text that has already moved.
    private static func merge(_ edits: [(range: NSRange, text: String)]) -> [(range: NSRange, text: String)] {
        let sorted = edits
            .filter { $0.range.length > 0 || !$0.text.isEmpty }
            .sorted { $0.range.location == $1.range.location
                      ? $0.range.length > $1.range.length
                      : $0.range.location < $1.range.location }
        var kept: [(range: NSRange, text: String)] = []
        for edit in sorted {
            if let last = kept.last, NSMaxRange(last.range) > edit.range.location {
                // Overlapping. The first one wins, because it is the outer one.
                continue
            }
            kept.append(edit)
        }
        return kept
    }

    /// Link spans for paths written as prose.
    ///
    /// Run over the *rendered* text, not the source: by this point the backticks
    /// around a path are gone, which is exactly why the path is now a bare run of
    /// characters the detector can see. Running it on the source would have to
    /// re-do the coordinate mapping for no gain.
    ///
    /// Skips anything overlapping a span that already means something. A path
    /// inside a fenced code block is a sample, not a destination, and a path that
    /// is already the target of a Markdown link does not need a second link laid
    /// over the first.
    private static func pathSpans(
        in rendered: NSString,
        avoiding existing: [ReadingDocument.Span],
        isLinkable: (String) -> Bool
    ) -> [ReadingDocument.Span] {
        let occupied = existing.compactMap { span -> NSRange? in
            switch span.style {
            case .link, .embed, .codeBlock, .math, .properties: return span.range
            default: return nil
            }
        }
        var found: [ReadingDocument.Span] = []
        for range in VaultPathDetector.candidates(in: rendered as String) {
            guard !occupied.contains(where: { NSIntersectionRange($0, range).length > 0 })
            else { continue }
            let written = rendered.substring(with: range)
            guard isLinkable(written) else { continue }
            found.append(.init(style: .link(target: written), range: range))
        }
        return found
    }
}
