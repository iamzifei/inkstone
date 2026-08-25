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
            case tag(String)
            case quote(depth: Int)
            case table
            case horizontalRule
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
    public static func render(_ markdown: String, scanner: SyntaxScanner = SyntaxScanner()) -> ReadingDocument {
        let source = markdown as NSString
        let tokens = scanner.scan(markdown)

        // 1. Everything to delete, as ranges in the *source*.
        var cuts: [NSRange] = []
        // 2. Text to substitute in place, for the few things that read better as
        //    a symbol than as their markup.
        var substitutions: [(range: NSRange, text: String)] = []

        for token in tokens {
            switch token.kind {
            // Whole blocks that are not prose.
            case .frontmatter, .comment:
                cuts.append(lineRange(token.range, in: source))

            // Fences go; the code between them stays.
            case .codeBlock:
                cuts.append(contentsOf: fenceLines(of: token, in: source))

            // Inline pairs: drop the delimiters either side of the content.
            case .bold, .italic, .strikethrough, .highlight, .inlineCode,
                 .superscript, .subscript, .mathInline:
                cuts.append(contentsOf: delimiters(of: token))

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
            if case .link = style, let replacement = displayText(of: token) {
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
        case .embed(let link): .link(target: link.target)
        case .markdownLink(let destination): .link(target: destination)
        case .tag(let name): .tag(name)
        case .blockquote(let depth): .quote(depth: depth)
        case .table: .table
        case .horizontalRule: .horizontalRule
        default: nil
        }
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
}
