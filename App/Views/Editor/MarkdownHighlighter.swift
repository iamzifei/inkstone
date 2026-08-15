import Foundation
import InkstoneCore

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Turns scanner tokens into text attributes for the editor.
///
/// This is the "live preview" engine. In live-preview mode the syntax characters
/// (`**`, `[[`, `#`) are collapsed to a near-zero-width font so the text reads
/// like rendered prose, *except* on the line the caret is on, where they reappear
/// so the user can edit them. That is the behaviour that makes an Obsidian-style
/// editor feel like writing rather than like coding.
struct MarkdownHighlighter {
    let style: Style
    let mode: EditorMode
    let scanner = SyntaxScanner()

    /// Font size used to visually collapse syntax markers. Zero is rejected by
    /// TextKit, so we use the smallest size that still lays out.
    private static let concealedFontSize: CGFloat = 0.01

    /// Applies attributes to `storage` in place.
    /// - Parameter caretLineRange: the paragraph containing the caret, which is
    ///   never concealed. Pass `nil` to conceal everything (reading mode).
    func highlight(_ storage: NSTextStorage, caretLineRange: NSRange?) {
        let text = storage.string
        let full = NSRange(location: 0, length: (text as NSString).length)
        guard full.length > 0 else { return }

        storage.beginEditing()
        defer { storage.endEditing() }

        applyBaseAttributes(to: storage, range: full)

        let tokens = scanner.scan(text)
        // Table cells are laid out with a monospaced font so columns line up.
        // Inline runs inside a cell have to use the same metrics or a single bold
        // word would knock the whole column out of alignment, so the ranges are
        // collected up front and consulted when styling those runs.
        let tableRanges = tokens.compactMap { token -> NSRange? in
            if case .table = token.kind { return token.range }
            return nil
        }
        for token in tokens {
            apply(
                token,
                to: storage,
                caretLineRange: caretLineRange,
                fullText: text as NSString,
                tableRanges: tableRanges
            )
        }

        if style.typography.cjkLatinSpacing {
            applyCJKLatinSpacing(to: storage, text: text as NSString)
        }

        // Last, because column alignment and CJK spacing both write `.kern` and
        // the alignment values have to be the ones that survive — otherwise a
        // cell ending on a Han/Latin boundary silently loses its padding.
        if mode != .source {
            for range in tableRanges {
                alignTableColumns(range, in: storage, text: text as NSString)
            }
        }
    }

    // MARK: - Base

    private func applyBaseAttributes(to storage: NSTextStorage, range: NSRange) {
        let typography = style.typography
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = typography.lineHeightMultiple
        paragraph.paragraphSpacing = typography.paragraphSpacing
        // Break CJK text by character; there are no spaces to break on.
        paragraph.lineBreakStrategy = [.pushOut]

        storage.setAttributes([
            .font: typography.editorFont.platformFont(size: typography.editorFontSize),
            .foregroundColor: style.palette.text.platformColor,
            .paragraphStyle: paragraph,
            .kern: typography.letterSpacing,
        ], range: range)
    }

    // MARK: - Tokens

    private func apply(
        _ token: SyntaxToken,
        to storage: NSTextStorage,
        caretLineRange: NSRange?,
        fullText: NSString,
        tableRanges: [NSRange]
    ) {
        let typography = style.typography
        let palette = style.palette
        // Editing the line the caret is on always shows raw syntax.
        let isBeingEdited = mode == .source
            || (caretLineRange.map { NSIntersectionRange($0, token.range).length > 0 } ?? false)

        let isInTable = tableRanges.contains { NSIntersectionRange($0, token.range).length > 0 }

        /// The face an inline run should use, so runs inside a table keep the
        /// monospaced metrics the surrounding cells were laid out with.
        func runFont(weight: PlatformFont.Weight? = nil) -> PlatformFont {
            let family = isInTable ? typography.codeFont : typography.editorFont
            let size = isInTable ? typography.codeFontSize : typography.editorFontSize
            if let weight { return family.platformFont(size: size, weight: weight) }
            return family.platformFont(size: size)
        }

        func setFont(_ font: PlatformFont, range: NSRange) {
            storage.addAttribute(.font, value: font, range: range)
        }

        func conceal(_ ranges: [NSRange]) {
            guard !isBeingEdited, mode != .source else { return }
            let tiny = PlatformFont.systemFont(ofSize: Self.concealedFontSize)
            for range in ranges where range.length > 0 {
                storage.addAttribute(.font, value: tiny, range: range)
                storage.addAttribute(.foregroundColor, value: PlatformColor.clear, range: range)
            }
        }

        /// The delimiter ranges either side of a token's content.
        func delimiters(of token: SyntaxToken) -> [NSRange] {
            let leading = NSRange(
                location: token.range.location,
                length: token.contentRange.location - token.range.location
            )
            let trailingStart = token.contentRange.location + token.contentRange.length
            let trailing = NSRange(
                location: trailingStart,
                length: token.range.location + token.range.length - trailingStart
            )
            return [leading, trailing].filter { $0.length > 0 && $0.location >= 0 }
        }

        switch token.kind {
        case .frontmatter:
            // In live preview the properties are already presented by the
            // inspector, so showing the raw YAML as well pushed the actual note
            // below the fold on every single file. It reappears in source mode,
            // and the moment the caret moves onto one of its lines.
            if isBeingEdited {
                storage.addAttribute(
                    .foregroundColor, value: palette.faintText.platformColor, range: token.range
                )
                setFont(typography.codeFont.platformFont(size: typography.codeFontSize), range: token.range)
            } else {
                conceal([token.range])
            }

        case .heading(let level):
            let size = typography.headingSize(level: level)
            let weight: PlatformFont.Weight = typography.headingWeightBoost ? .bold : .semibold
            setFont(typography.editorFont.platformFont(size: size, weight: weight), range: token.range)
            storage.addAttribute(.foregroundColor, value: palette.text.platformColor, range: token.range)
            // Dim (or hide) the leading `#`s.
            let hashRange = NSRange(
                location: token.range.location,
                length: max(0, token.contentRange.location - token.range.location)
            )
            if isBeingEdited {
                storage.addAttribute(.foregroundColor, value: palette.faintText.platformColor, range: hashRange)
            } else {
                conceal([hashRange])
            }

        case .bold:
            setFont(runFont(weight: .bold), range: token.contentRange)
            styleDelimiters(delimiters(of: token), in: storage, isBeingEdited: isBeingEdited, conceal: conceal)

        case .italic:
            setFont(italicVariant(of: runFont()), range: token.contentRange)
            styleDelimiters(delimiters(of: token), in: storage, isBeingEdited: isBeingEdited, conceal: conceal)

        case .strikethrough:
            storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: token.contentRange)
            storage.addAttribute(.foregroundColor, value: palette.secondaryText.platformColor, range: token.contentRange)
            styleDelimiters(delimiters(of: token), in: storage, isBeingEdited: isBeingEdited, conceal: conceal)

        case .highlight:
            storage.addAttribute(.backgroundColor, value: palette.highlight.platformColor, range: token.contentRange)
            styleDelimiters(delimiters(of: token), in: storage, isBeingEdited: isBeingEdited, conceal: conceal)

        case .inlineCode:
            setFont(typography.codeFont.platformFont(size: typography.codeFontSize), range: token.range)
            storage.addAttribute(.backgroundColor, value: palette.codeBackground.platformColor, range: token.range)
            storage.addAttribute(.foregroundColor, value: palette.accent.platformColor, range: token.contentRange)

        case .codeBlock:
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineHeightMultiple = typography.codeLineHeightMultiple
            paragraph.firstLineHeadIndent = 8
            paragraph.headIndent = 8
            storage.addAttributes([
                .font: typography.codeFont.platformFont(size: typography.codeFontSize),
                .backgroundColor: palette.codeBackground.platformColor,
                .foregroundColor: palette.text.platformColor,
                .paragraphStyle: paragraph,
            ], range: token.range)

        case .mathInline, .mathBlock:
            setFont(typography.codeFont.platformFont(size: typography.codeFontSize), range: token.range)
            storage.addAttribute(.foregroundColor, value: palette.accent.platformColor, range: token.range)

        case .wikiLink(let link), .embed(let link):
            storage.addAttribute(.foregroundColor, value: palette.link.platformColor, range: token.range)
            storage.addAttribute(.inkstoneWikiLink, value: link, range: token.range)
            if !isBeingEdited {
                conceal(delimiters(of: token))
                // When an alias is present, hide the target and pipe too so only
                // the display text remains visible.
                if let alias = link.alias, !alias.isEmpty {
                    let visibleLength = (alias as NSString).length
                    let hiddenEnd = token.range.location + token.range.length - 2 - visibleLength
                    let hidden = NSRange(
                        location: token.contentRange.location,
                        length: max(0, hiddenEnd - token.contentRange.location)
                    )
                    conceal([hidden])
                }
            }

        case .markdownLink(let destination):
            storage.addAttribute(.foregroundColor, value: palette.link.platformColor, range: token.contentRange)
            storage.addAttribute(.inkstoneLinkDestination, value: destination, range: token.range)
            if !isBeingEdited { conceal(delimiters(of: token)) }

        case .tag(let name):
            storage.addAttributes([
                .foregroundColor: palette.tag.platformColor,
                .inkstoneTag: name,
            ], range: token.range)

        case .blockIdentifier:
            storage.addAttribute(.foregroundColor, value: palette.faintText.platformColor, range: token.range)

        case .callout(let type, _, _):
            storage.addAttributes([
                .foregroundColor: calloutColor(for: type).platformColor,
                .font: typography.editorFont.platformFont(size: typography.editorFontSize, weight: .semibold),
            ], range: token.range)

        case .comment:
            storage.addAttribute(.foregroundColor, value: palette.faintText.platformColor, range: token.range)

        case .table:
            // Monospaced, so the pipes in the source line up into columns. This
            // is what makes a Markdown table readable without a real table
            // layout, which TextKit cannot give us without rewriting the text.
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineHeightMultiple = typography.codeLineHeightMultiple
            paragraph.firstLineHeadIndent = 8
            paragraph.headIndent = 8
            paragraph.lineBreakMode = .byClipping
            storage.addAttributes([
                .font: typography.codeFont.platformFont(size: typography.codeFontSize),
                .backgroundColor: palette.codeBackground.platformColor,
                .foregroundColor: palette.text.platformColor,
                .paragraphStyle: paragraph,
            ], range: token.range)

        case .tableHeaderRow:
            setFont(
                typography.codeFont.platformFont(size: typography.codeFontSize, weight: .semibold),
                range: token.range
            )

        case .tableDelimiterRow:
            // Pure scaffolding. Dimmed while editing so the row can still be
            // corrected, collapsed entirely once the caret leaves it.
            if isBeingEdited {
                storage.addAttribute(
                    .foregroundColor, value: palette.faintText.platformColor, range: token.range
                )
            } else {
                conceal([token.range])
            }

        case .task(let checked):
            // The marker is coloured like an accent so a task list scans as a
            // list of checkboxes, and completed items recede.
            let markerLength = min(3, max(0, token.range.length))
            let markerStart = max(token.range.location, token.contentRange.location - markerLength)
            let marker = NSRange(location: markerStart, length: markerLength)
            if marker.location + marker.length <= fullText.length {
                storage.addAttribute(
                    .foregroundColor,
                    value: (checked ? palette.accent : palette.secondaryText).platformColor,
                    range: marker
                )
            }
            if checked {
                storage.addAttributes([
                    .foregroundColor: palette.faintText.platformColor,
                    .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                ], range: token.contentRange)
            }

        case .horizontalRule:
            storage.addAttribute(.foregroundColor, value: palette.divider.platformColor, range: token.range)

        case .blockquote, .listMarker:
            storage.addAttribute(.foregroundColor, value: palette.secondaryText.platformColor, range: token.range)
        }
    }

    private func styleDelimiters(
        _ ranges: [NSRange],
        in storage: NSTextStorage,
        isBeingEdited: Bool,
        conceal: ([NSRange]) -> Void
    ) {
        if isBeingEdited {
            for range in ranges where range.length > 0 {
                storage.addAttribute(.foregroundColor, value: style.palette.faintText.platformColor, range: range)
            }
        } else {
            conceal(ranges)
        }
    }

    private func italicVariant(of base: PlatformFont) -> PlatformFont {
        #if os(macOS)
        return NSFontManager.shared.convert(base, toHaveTrait: .italicFontMask)
        #else
        guard let descriptor = base.fontDescriptor.withSymbolicTraits(.traitItalic) else { return base }
        return UIFont(descriptor: descriptor, size: base.pointSize)
        #endif
    }

    private func calloutColor(for type: String) -> ThemeColor {
        switch type {
        case "warning", "caution", "attention": return ThemeColor("#D98E4A")
        case "danger", "error", "bug", "failure", "fail", "missing": return ThemeColor("#D95C5C")
        case "success", "check", "done", "tip", "hint", "important": return ThemeColor("#5FA86B")
        case "question", "help", "faq": return ThemeColor("#D9C24A")
        case "quote", "cite": return style.palette.secondaryText
        case "example": return ThemeColor("#8A6BC4")
        default: return style.palette.accent
        }
    }

    // MARK: - Table alignment

    /// Pads a table's columns visually so they line up, without touching the file.
    ///
    /// A monospaced font alone is not enough: it only guarantees that columns line
    /// up if the *source* is already padded, and most hand-written Markdown is
    /// not. Rather than rewriting the user's file to insert spaces — which would
    /// dirty the document and fight sync — the extra width is added as kerning on
    /// the last character of each cell. Same trick as the CJK spacing below:
    /// rendering-time only, the bytes on disk never change.
    ///
    /// Known limitation: cell width is measured from the raw characters, so a cell
    /// whose `**markers**` get concealed measures slightly wide and its column can
    /// sit a fraction off. Plain-text cells — nearly all of them — are exact.
    private func alignTableColumns(_ tableRange: NSRange, in storage: NSTextStorage, text: NSString) {
        let font = style.typography.codeFont.platformFont(size: style.typography.codeFontSize)

        /// Measures a cell as it will actually be drawn.
        ///
        /// Counting characters and assuming "one Han character is two Latin ones"
        /// is wrong in practice: a monospaced Latin font has no CJK glyphs, so
        /// those fall back to a different family whose advance is not exactly
        /// double. Measuring sidesteps the whole question.
        func width(of range: NSRange) -> CGFloat {
            (text.substring(with: range) as NSString)
                .size(withAttributes: [.font: font])
                .width
        }

        // Cells per row, as ranges between the pipes. Delimiter rows are skipped:
        // they are concealed anyway, and their dashes would distort the widths.
        var rows: [[NSRange]] = []
        var lineStart = tableRange.location
        let tableEnd = tableRange.location + tableRange.length

        while lineStart < tableEnd {
            let line = text.lineRange(for: NSRange(location: lineStart, length: 0))
            let end = min(line.location + line.length, tableEnd)
            let content = NSRange(location: line.location, length: end - line.location)
            defer { lineStart = line.location + line.length }

            guard content.length > 0 else { continue }
            let raw = text.substring(with: content)
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("|") else { continue }
            // A delimiter row is only pipes, dashes, colons and spaces.
            if trimmed.allSatisfy({ "|-: \t".contains($0) }) { continue }

            var pipes: [Int] = []
            for offset in 0..<content.length where text.character(at: content.location + offset) == 0x7C {
                pipes.append(content.location + offset)
            }
            guard pipes.count >= 2 else { continue }

            var cells: [NSRange] = []
            for index in 0..<(pipes.count - 1) {
                let start = pipes[index] + 1
                let length = pipes[index + 1] - start
                if length > 0 { cells.append(NSRange(location: start, length: length)) }
            }
            if !cells.isEmpty { rows.append(cells) }
        }

        guard rows.count > 1 else { return }

        let columnCount = rows.map(\.count).max() ?? 0
        var widths = [CGFloat](repeating: 0, count: columnCount)
        for row in rows {
            for (column, cell) in row.enumerated() {
                widths[column] = max(widths[column], width(of: cell))
            }
        }

        for row in rows {
            for (column, cell) in row.enumerated() {
                let deficit = widths[column] - width(of: cell)
                // Sub-point deficits are invisible and only add attribute churn.
                guard deficit > 0.5, cell.length > 0 else { continue }
                // Kerning applies *after* the glyph, so it goes on the final
                // character of the cell and pushes the closing pipe rightwards.
                let last = NSRange(location: cell.location + cell.length - 1, length: 1)
                storage.addAttribute(.kern, value: deficit, range: last)
            }
        }
    }

    // MARK: - CJK typography

    /// Inserts a small amount of kerning between Han characters and adjacent
    /// Latin letters or digits — the "盘古之白" convention — without touching the
    /// underlying text. Purely visual, so the file on disk stays clean.
    private func applyCJKLatinSpacing(to storage: NSTextStorage, text: NSString) {
        let string = storage.string
        let characters = Array(string.unicodeScalars)
        guard characters.count > 1 else { return }

        var utf16Offset = 0
        var previousScalar: Unicode.Scalar?
        let spacing = style.typography.editorFontSize * 0.14

        for scalar in characters {
            defer {
                utf16Offset += UTF16.width(scalar)
                previousScalar = scalar
            }
            guard let previous = previousScalar else { continue }
            let boundary = (isHan(previous) && isLatinOrDigit(scalar))
                || (isLatinOrDigit(previous) && isHan(scalar))
            guard boundary, utf16Offset > 0, utf16Offset < text.length else { continue }
            storage.addAttribute(.kern, value: spacing, range: NSRange(location: utf16Offset - 1, length: 1))
        }
    }

    private func isHan(_ scalar: Unicode.Scalar) -> Bool {
        (0x4E00...0x9FFF).contains(scalar.value)
            || (0x3400...0x4DBF).contains(scalar.value)
            || (0xF900...0xFAFF).contains(scalar.value)
    }

    private func isLatinOrDigit(_ scalar: Unicode.Scalar) -> Bool {
        (scalar.value >= 0x30 && scalar.value <= 0x39)
            || (scalar.value >= 0x41 && scalar.value <= 0x5A)
            || (scalar.value >= 0x61 && scalar.value <= 0x7A)
    }
}

extension NSAttributedString.Key {
    /// Attached to `[[wikilink]]` runs so a click can resolve the target.
    static let inkstoneWikiLink = NSAttributedString.Key("inkstoneWikiLink")
    /// Attached to `[text](destination)` runs.
    static let inkstoneLinkDestination = NSAttributedString.Key("inkstoneLinkDestination")
    /// Attached to `#tag` runs.
    static let inkstoneTag = NSAttributedString.Key("inkstoneTag")
}
