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
/// Main-actor bound: it reads the shared image cache for inline attachments, and
/// its only caller is the editor coordinator, which is already on the main actor.
@MainActor
struct MarkdownHighlighter {
    let style: Style
    let mode: EditorMode
    let scanner = SyntaxScanner()

    /// Resolves an embed target to a file in the vault. Injected rather than
    /// reached for directly so the highlighter stays free of app state and can be
    /// exercised without a vault.
    var resolveAttachment: ((String) -> URL?)?
    /// Text width available for inline images, so a photo is scaled to the
    /// measure rather than overflowing the column.
    var availableWidth: CGFloat = 680

    /// Font size used to visually collapse syntax markers. Zero is rejected by
    /// TextKit, so we use the smallest size that still lays out.
    private static let concealedFontSize: CGFloat = 0.01

    /// Applies attributes to `storage` in place.
    ///
    /// - Parameters:
    ///   - caretLineRange: the paragraph containing the caret, which is never
    ///     concealed. Pass `nil` to conceal everything (reading mode).
    ///   - visibleRange: when given, only text intersecting this range is styled.
    ///     Parsing still covers the whole document — a fenced block or table has
    ///     to be recognised even when it starts off-screen, or the text inside it
    ///     would be mistaken for ordinary Markdown. It is applying the attributes
    ///     that costs, and that is what this skips.
    func highlight(_ storage: NSTextStorage, caretLineRange: NSRange?, visibleRange: NSRange? = nil) {
        let text = storage.string
        let full = NSRange(location: 0, length: (text as NSString).length)
        guard full.length > 0 else { return }

        let scope = visibleRange.map { NSIntersectionRange($0, full) } ?? full
        guard scope.length > 0 else { return }

        storage.beginEditing()
        defer { storage.endEditing() }

        applyBaseAttributes(to: storage, range: scope)

        let tokens = scanner.scan(text)
        // Table cells are laid out with a monospaced font so columns line up.
        // Inline runs inside a cell have to use the same metrics or a single bold
        // word would knock the whole column out of alignment, so the ranges are
        // collected up front and consulted when styling those runs.
        let tableRanges = tokens.compactMap { token -> NSRange? in
            if case .table = token.kind { return token.range }
            return nil
        }
        // As an IndexSet, not an array. The "is this run inside a table?" check
        // runs once per token, and scanning every table range each time made the
        // pass quadratic — on a note with 200 tables that was the single largest
        // cost in highlighting.
        var tableIndices = IndexSet()
        for range in tableRanges where range.length > 0 {
            tableIndices.insert(integersIn: range.location..<(range.location + range.length))
        }

        // Headings are collected up front: a [TOC] anywhere in the document has
        // to list all of them, including ones that appear after it.
        let headings: [(level: Int, title: String)] = tokens.compactMap { token in
            guard case .heading(let level) = token.kind else { return nil }
            let title = (text as NSString).substring(with: token.contentRange)
                .trimmingCharacters(in: .whitespaces)
            return title.isEmpty ? nil : (level, title)
        }

        for token in tokens {
            // Tokens wholly outside the styled scope cost nothing to skip.
            guard NSIntersectionRange(token.range, scope).length > 0
                    || NSLocationInRange(scope.location, token.range)
            else { continue }
            apply(
                token,
                to: storage,
                caretLineRange: caretLineRange,
                fullText: text as NSString,
                tableIndices: tableIndices,
                headings: headings
            )
        }

        compressBlankLines(in: storage, text: text as NSString, within: scope)

        if style.typography.cjkLatinSpacing {
            applyCJKLatinSpacing(to: storage, text: text as NSString, within: scope)
        }

        // Last, because column alignment and CJK spacing both write `.kern` and
        // the alignment values have to be the ones that survive — otherwise a
        // cell ending on a Han/Latin boundary silently loses its padding.
        if mode != .source {
            for range in tableRanges
            where NSIntersectionRange(range, scope).length > 0 {
                alignTableColumns(range, in: storage, text: text as NSString)
            }
        }
    }

    // MARK: - Base

    /// Whether the line above `line` is also quoted.
    private func isQuoted(lineBefore line: NSRange, in text: NSString) -> Bool {
        guard line.location > 0 else { return false }
        let previous = text.paragraphRange(for: NSRange(location: line.location - 1, length: 0))
        return isQuotedLine(previous, in: text)
    }

    /// Whether the line below `line` is also quoted.
    private func isQuoted(lineAfter line: NSRange, in text: NSString) -> Bool {
        let next = NSMaxRange(line)
        guard next < text.length else { return false }
        return isQuotedLine(text.paragraphRange(for: NSRange(location: next, length: 0)), in: text)
    }

    private func isQuotedLine(_ range: NSRange, in text: NSString) -> Bool {
        let line = text.substring(with: range).trimmingCharacters(in: .whitespaces)
        return line.hasPrefix(">")
    }

    /// Applies a paragraph style across a multi-line block, keeping the block's
    /// outer spacing on its first and last lines only.
    ///
    /// A paragraph style's spacing applies to *every* paragraph it covers, and
    /// each line of a table or a code fence is its own paragraph. Setting it once
    /// for the whole block therefore inserted the block's margin between every
    /// pair of rows: table rows measured 39.5pt apart where the line height is
    /// 20.3.
    private func applyBlockStyle(
        _ base: NSMutableParagraphStyle,
        spacing: CGFloat,
        to range: NSRange,
        in storage: NSTextStorage,
        text: NSString
    ) {
        var lines: [NSRange] = []
        var location = range.location
        while location < NSMaxRange(range), location < text.length {
            let line = text.lineRange(for: NSRange(location: location, length: 0))
            lines.append(NSRange(
                location: line.location,
                length: min(line.length, NSMaxRange(range) - line.location)
            ))
            location = NSMaxRange(line)
        }
        guard !lines.isEmpty else { return }

        for (index, line) in lines.enumerated() where line.length > 0 {
            let style = base.mutableCopy() as? NSMutableParagraphStyle ?? base
            style.paragraphSpacingBefore = index == 0 ? spacing : 0
            style.paragraphSpacing = index == lines.count - 1 ? spacing : 0
            // Every line keeps clear of the copy button, not just the first.
            // Applying it to line 0 alone missed: in a fenced block line 0 is the
            // collapsed ``` and the first *visible* line is the next one. Doing
            // the whole block is simpler than tracking which line that is, and
            // gives the panel an even right margin.
            style.tailIndent = -Self.copyButtonClearance
            storage.addAttribute(.paragraphStyle, value: style, range: line)
        }
    }

    /// Builds a paragraph style whose line height is a multiple of the *font
    /// size*, the way CSS `line-height` works.
    ///
    /// `NSParagraphStyle.lineHeightMultiple` multiplies the font's own default
    /// line height, which already includes leading — for the 16pt system font
    /// that is about 19pt, so a "1.6 multiple" rendered at 30.4pt, nearly twice
    /// the font size. Typora's 1.6 means 25.6pt. Setting the minimum and maximum
    /// explicitly is the only way to express the CSS meaning.
    func paragraph(lineHeight multiple: Double, size: Double) -> NSMutableParagraphStyle {
        let style = NSMutableParagraphStyle()
        let height = size * multiple
        style.minimumLineHeight = height
        style.maximumLineHeight = height
        style.lineBreakStrategy = [.pushOut]
        return style
    }

    private func applyBaseAttributes(to storage: NSTextStorage, range: NSRange) {
        let typography = style.typography
        // Break CJK text by character; there are no spaces to break on.
        // No paragraph spacing. In a plain-text editor every newline is its own
        // paragraph, so spacing after each one would apply to soft line breaks
        // *within* a Markdown paragraph too — doubling the leading everywhere.
        // The blank line between paragraphs supplies the gap instead; see
        // `compressBlankLines`, which sizes it to match Typora's 1rem.
        let paragraph = paragraph(
            lineHeight: typography.lineHeightMultiple, size: typography.editorFontSize
        )

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
        tableIndices: IndexSet,
        headings: [(level: Int, title: String)]
    ) {
        let typography = style.typography
        let palette = style.palette
        // Editing the line the caret is on always shows raw syntax.
        let isBeingEdited = mode == .source
            || (caretLineRange.map { NSIntersectionRange($0, token.range).length > 0 } ?? false)

        let isInTable = token.range.length > 0
            && tableIndices.intersects(
                integersIn: token.range.location..<(token.range.location + token.range.length)
            )

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

        /// Hides text regardless of where the caret is.
        ///
        /// Only for markers that are replaced by something interactive, where
        /// revealing the source would take the control away from under the
        /// pointer. Everything else should use `conceal`.
        func hide(_ ranges: [NSRange]) {
            guard mode != .source else { return }
            let tiny = PlatformFont.systemFont(ofSize: Self.concealedFontSize)
            for range in ranges where range.length > 0 {
                storage.addAttribute(.font, value: tiny, range: range)
                storage.addAttribute(.foregroundColor, value: PlatformColor.clear, range: range)
                // Collapsed text must not be spell-checked. The squiggle is drawn
                // at the run's width, and on a 0.01pt run that collapses to a
                // single red dot floating under the rendered content.
                #if os(macOS)
                // AppKit only; UIKit has no equivalent attribute, and does not
                // draw a misspelling underline on a zero-width run either.
                storage.addAttribute(.spellingState, value: 0, range: range)
                #endif
            }
        }

        func conceal(_ ranges: [NSRange]) {
            guard !isBeingEdited else { return }
            hide(ranges)
        }

        /// Collapses whole lines: hides the text *and* removes the height the
        /// line would otherwise still occupy.
        ///
        /// Concealing sets a 0.01pt font, which used to be enough because line
        /// height followed the font. Now that paragraphs carry an explicit
        /// `minimumLineHeight` (to get CSS line-height semantics), a hidden line
        /// still reserves a full line — four lines of invisible frontmatter at
        /// the top of every note, and a gap inside every table and code block.
        func concealLines(_ range: NSRange) {
            guard !isBeingEdited, mode != .source, range.length > 0 else { return }
            conceal([range])
            let collapsed = NSMutableParagraphStyle()
            collapsed.minimumLineHeight = 0.01
            collapsed.maximumLineHeight = 0.01
            collapsed.paragraphSpacing = 0
            collapsed.paragraphSpacingBefore = 0
            storage.addAttribute(.paragraphStyle, value: collapsed, range: range)
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
                concealLines(token.range)
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

            // Typora's default theme rules off h1 and h2, which is what gives a
            // long document its sense of chapters. Drawn by the view: paragraph
            // styles have no border of their own.
            if level <= 2 {
                storage.addAttribute(.inkstoneHeadingRule, value: level, range: token.range)
            }

            // Headings set their own metrics; the body line-height multiple is
            // far too loose at 36pt and leaves a chasm above every title.
            let headingParagraph = paragraph(
                lineHeight: level <= 2 ? 1.25 : 1.35, size: size
            )
            headingParagraph.paragraphSpacingBefore = typography.paragraphSpacing * 1.5
            headingParagraph.paragraphSpacing = typography.paragraphSpacing * (level <= 2 ? 0.75 : 0.5)
            storage.addAttribute(
                .paragraphStyle, value: headingParagraph, range: fullText.paragraphRange(for: token.range)
            )

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
            storage.addAttribute(.foregroundColor, value: palette.accent.platformColor, range: token.contentRange)
            // The tinted background is what marks this as code, so the backticks
            // themselves can go — and the background has to shrink with them or
            // it leaves a stub hanging off each end.
            // Drawn by the text view rather than set as `.backgroundColor`: that
            // attribute fills the whole line fragment, and with a line-height
            // multiple of 1.75 the tint towers over the words it is meant to hug.
            storage.addAttribute(
                .inkstoneInlineFill,
                value: palette.codeBackground.platformColor,
                range: isBeingEdited ? token.range : token.contentRange
            )
            if !isBeingEdited { conceal(delimiters(of: token)) }

        case .codeBlock(let language) where language?.lowercased() == "mermaid" && !isBeingEdited:
            // A diagram renders asynchronously, so the first pass sees nothing
            // and shows the source as an ordinary code block. When the image
            // lands the renderer asks the editor to run again and it appears.
            let body = mermaidBody(of: token.range, in: fullText)
            let mermaidImage = MermaidRenderer.shared.image(for: body, isDark: style.isDark)
            if let image = mermaidImage {
                inlineImage(image, to: storage, in: token.range, fullText: fullText)
            } else {
                applyCodeBlockStyle(to: storage, token: token, fullText: fullText, conceal: conceal, isBeingEdited: isBeingEdited)
                // Same fence handling as an ordinary block, so a diagram waiting
                // to render looks like code rather than like raw source.
                for line in fenceLines(of: token.range, in: fullText) { concealLines(line) }
            }

        case .codeBlock:
            // Shared with the Mermaid path above, which falls back to this while
            // a diagram renders. Duplicating it here is how the fenced block
            // kept its per-line paragraph spacing after the table lost it.
            applyCodeBlockStyle(
                to: storage, token: token, fullText: fullText,
                conceal: conceal, isBeingEdited: isBeingEdited
            )

            // Collapse the ``` fences themselves: the shaded block already says
            // "this is code", so the backticks are pure noise once you stop
            // editing them.
            if !isBeingEdited {
                for line in fenceLines(of: token.range, in: fullText) { concealLines(line) }
            }

        case .mathInline, .mathBlock:
            let isDisplay: Bool
            if case .mathBlock = token.kind { isDisplay = true } else { isDisplay = false }
            let latex = fullText.substring(with: token.contentRange)

            // Source stays visible while the caret is on it, so the formula can
            // be edited; it becomes the typeset result as soon as focus leaves.
            if isBeingEdited {
                setFont(typography.codeFont.platformFont(size: typography.codeFontSize), range: token.range)
                storage.addAttribute(.foregroundColor, value: palette.accent.platformColor, range: token.range)
                break
            }

            let renderer = MathRenderer.shared
            guard let image = renderer.image(
                latex: latex,
                fontSize: typography.editorFontSize * (isDisplay ? 1.15 : 1.0),
                isDisplay: isDisplay,
                colour: palette.text.platformColor
            ) else {
                // Invalid LaTeX shows its source in the unresolved colour rather
                // than vanishing — a formula that silently disappears is worse
                // than one that visibly did not parse.
                setFont(typography.codeFont.platformFont(size: typography.codeFontSize), range: token.range)
                storage.addAttribute(
                    .foregroundColor, value: palette.unresolvedLink.platformColor, range: token.range
                )
                break
            }

            if isDisplay {
                // A block formula gets its own line, like an inline image.
                inlineImage(image, to: storage, in: token.range, fullText: fullText)
            } else {
                inlineMath(image, to: storage, in: token.range)
            }

        case .embed(let link):
            // An embed of an image is replaced by the image itself; anything else
            // (video, PDF, a note transclusion) keeps its link styling so it is
            // still visible and clickable rather than silently disappearing.
            let resolved = resolveAttachment?(link.target)
            if let resolved, AttachmentKind(url: resolved) == .image, !isBeingEdited,
               let image = AttachmentImageCache.shared.image(for: resolved, maxWidth: availableWidth) {
                inlineImage(image, to: storage, in: token.range, fullText: fullText)
                storage.addAttribute(.inkstoneAttachment, value: resolved, range: token.range)
                break
            }

            storage.addAttribute(.foregroundColor, value: palette.link.platformColor, range: token.range)
            if let resolved {
                storage.addAttribute(.inkstoneAttachment, value: resolved, range: token.range)
                // A video or PDF gets a tinted chip so it reads as a file you can
                // open, not as a link to another note.
                if AttachmentKind(url: resolved) != .image {
                    // Only the visible filename gets the chip. Covering the whole
                    // token would tint the collapsed `![[` and `]]` too, and those
                    // sit on a 0.01pt line, which drags the highlight off-centre.
                    storage.addAttribute(
                        .inkstoneInlineFill,
                        value: palette.codeBackground.platformColor,
                        range: isBeingEdited ? token.range : token.contentRange
                    )
                }
            } else {
                storage.addAttribute(
                    .foregroundColor, value: palette.unresolvedLink.platformColor, range: token.range
                )
            }
            storage.addAttribute(.inkstoneWikiLink, value: link, range: token.range)
            if !isBeingEdited { conceal(delimiters(of: token)) }

        case .wikiLink(let link):
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
            // `![alt](path.png)` is the image form. It matters because notes
            // pasted in from other editors use this rather than `![[...]]`, and
            // without it those images stayed as raw link text.
            let isImage = token.range.location < fullText.length
                && fullText.character(at: token.range.location) == 0x21  // "!"
            if isImage, !isBeingEdited, !destination.contains("://"),
               let resolved = resolveAttachment?(destination),
               AttachmentKind(url: resolved) == .image,
               let image = AttachmentImageCache.shared.image(for: resolved, maxWidth: availableWidth) {
                inlineImage(image, to: storage, in: token.range, fullText: fullText)
                storage.addAttribute(.inkstoneAttachment, value: resolved, range: token.range)
                break
            }

            storage.addAttribute(.foregroundColor, value: palette.link.platformColor, range: token.contentRange)
            storage.addAttribute(.inkstoneLinkDestination, value: destination, range: token.range)
            if !isBeingEdited { conceal(delimiters(of: token)) }

        case .tag(let name):
            storage.addAttributes([
                .foregroundColor: palette.tag.platformColor,
                .inkstoneTag: name,
            ], range: token.range)

        case .footnoteReference(let id):
            // Rendered as a raised marker, the way a typeset footnote looks. The
            // brackets and caret are scaffolding and collapse; the identifier is
            // what a reader needs.
            let raised = typography.editorFont.platformFont(size: typography.editorFontSize * 0.72)
            storage.addAttributes([
                .font: raised,
                .foregroundColor: palette.accent.platformColor,
                .baselineOffset: typography.editorFontSize * 0.32,
                .inkstoneFootnote: id,
            ], range: token.contentRange)
            if !isBeingEdited { conceal(delimiters(of: token)) }

        case .footnoteDefinition(let id):
            // The definition line reads as an aside: smaller, quieter, indented.
            let line = fullText.paragraphRange(for: token.range)
            let paragraph = paragraph(
                lineHeight: typography.lineHeightMultiple, size: typography.editorFontSize * 0.88
            )
            paragraph.firstLineHeadIndent = Self.listIndent
            paragraph.headIndent = Self.listIndent
            paragraph.paragraphSpacing = typography.paragraphSpacing * 0.25
            storage.addAttributes([
                .paragraphStyle: paragraph,
                .font: typography.editorFont.platformFont(size: typography.editorFontSize * 0.88),
                .foregroundColor: palette.secondaryText.platformColor,
            ], range: line)
            storage.addAttributes([
                .foregroundColor: palette.accent.platformColor,
                .inkstoneFootnote: id,
            ], range: token.contentRange)
            if !isBeingEdited {
                // Collapse `[^` and `]:` but keep the identifier visible so the
                // reader can match it to the reference.
                conceal(delimiters(of: token))
                // Collapsing `]: ` takes the separating space with it, which ran
                // the identifier straight into the text ("1Knuth"). Put the gap
                // back as kerning on the identifier's last character.
                if token.contentRange.length > 0 {
                    let last = NSRange(
                        location: token.contentRange.location + token.contentRange.length - 1,
                        length: 1
                    )
                    storage.addAttribute(.kern, value: typography.editorFontSize * 0.4, range: last)
                }
            }

        case .tableOfContents:
            guard !isBeingEdited, !headings.isEmpty,
                  let image = tableOfContentsImage(headings)
            else {
                storage.addAttributes([
                    .font: typography.codeFont.platformFont(size: typography.codeFontSize),
                    .foregroundColor: palette.faintText.platformColor,
                ], range: token.range)
                break
            }
            inlineImage(image, to: storage, in: token.range, fullText: fullText, centred: false)

        case .superscript:
            storage.addAttributes([
                .font: typography.editorFont.platformFont(size: typography.editorFontSize * 0.72),
                .baselineOffset: typography.editorFontSize * 0.32,
            ], range: token.contentRange)
            if !isBeingEdited { conceal(delimiters(of: token)) }

        case .subscript:
            storage.addAttributes([
                .font: typography.editorFont.platformFont(size: typography.editorFontSize * 0.72),
                .baselineOffset: -typography.editorFontSize * 0.16,
            ], range: token.contentRange)
            if !isBeingEdited { conceal(delimiters(of: token)) }

        case .blockIdentifier:
            storage.addAttribute(.foregroundColor, value: palette.faintText.platformColor, range: token.range)

        case .callout(let type, _, _):
            storage.addAttributes([
                .foregroundColor: calloutColor(for: type).platformColor,
                .font: typography.editorFont.platformFont(size: typography.editorFontSize, weight: .semibold),
            ], range: token.range)
            // Collapse the `> [!warning]` scaffolding, keeping the title. The
            // colour already communicates the type, so the literal marker is
            // noise once the caret leaves the line.
            if !isBeingEdited, token.contentRange.location > token.range.location {
                conceal([NSRange(
                    location: token.range.location,
                    length: token.contentRange.location - token.range.location
                )])
            }

        case .comment:
            storage.addAttribute(.foregroundColor, value: palette.faintText.platformColor, range: token.range)

        case .table:
            // Monospaced, so the pipes in the source line up into columns. This
            // is what makes a Markdown table readable without a real table
            // layout, which TextKit cannot give us without rewriting the text.
            let paragraph = paragraph(
                lineHeight: typography.codeLineHeightMultiple, size: typography.codeFontSize
            )
            paragraph.firstLineHeadIndent = 8
            paragraph.headIndent = 8
            paragraph.lineBreakMode = .byClipping
            storage.addAttributes([
                .font: typography.codeFont.platformFont(size: typography.codeFontSize),
                .foregroundColor: palette.text.platformColor,
                .inkstoneBlockFill: true,
            ], range: token.range)
            // Typora sets `margin: 0.8em 0` on tables — around the table, not
            // around each row.
            applyBlockStyle(
                paragraph, spacing: typography.paragraphSpacing * 0.6,
                to: token.range, in: storage, text: fullText
            )

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
                concealLines(token.range)
            }

        case .task(let checked, let level):
            // Indent the item the way a bullet list is indented, so tasks and
            // bullets in the same list line up.
            let paragraph = paragraph(
                lineHeight: typography.lineHeightMultiple, size: typography.editorFontSize
            )
            // Both indents, not just `headIndent`: the marker is collapsed to
            // zero width, so without indenting the *first* line too the text
            // starts at the margin and the checkbox is painted on top of it.
            // Scaled by nesting depth, exactly as a bullet is, so a nested task
            // lines up with the nested bullets beside it.
            let taskIndent = Self.listIndent * CGFloat(level + 1)
            paragraph.firstLineHeadIndent = taskIndent
            paragraph.headIndent = taskIndent
            paragraph.paragraphSpacing = typography.paragraphSpacing * 0.25
            storage.addAttribute(
                .paragraphStyle, value: paragraph, range: fullText.paragraphRange(for: token.range)
            )

            // Collapse the whole `- [x] ` marker and let the text view draw a
            // real checkbox where it was.
            //
            // Deliberately not gated on `isBeingEdited`, unlike every other
            // marker. Revealing the source on the caret's line is right for
            // syntax you might want to edit, but a checkbox is a control: hiding
            // it the moment the caret lands on its line means you have to move
            // the caret away before you can tick the box you are looking at.
            hide([token.range])
            storage.addAttribute(.inkstoneCheckbox, value: checked, range: token.range)

            if checked {
                // Strike through the task text, not the marker.
                let line = fullText.paragraphRange(for: token.range)
                let bodyStart = token.range.location + token.range.length
                let body = NSRange(location: bodyStart, length: max(0, line.location + line.length - bodyStart))
                if body.length > 0 {
                    storage.addAttributes([
                        .foregroundColor: palette.faintText.platformColor,
                        .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                        .strikethroughColor: palette.faintText.platformColor,
                    ], range: body)
                }
            }

        case .horizontalRule:
            // Previously this only tinted the `---`, which left the source
            // showing in preview: a thematic break rendered as three grey
            // hyphens rather than as a line across the page.
            if isBeingEdited {
                storage.addAttribute(
                    .foregroundColor, value: palette.divider.platformColor, range: token.range
                )
            } else {
                let line = fullText.paragraphRange(for: token.range)
                hide([line])
                // The line itself is painted by the text view, in the space this
                // paragraph keeps.
                let paragraph = paragraph(
                    lineHeight: typography.lineHeightMultiple, size: typography.editorFontSize
                )
                paragraph.paragraphSpacingBefore = typography.paragraphSpacing * 0.5
                paragraph.paragraphSpacing = typography.paragraphSpacing * 0.5
                storage.addAttribute(.paragraphStyle, value: paragraph, range: line)
                storage.addAttribute(.inkstoneHorizontalRule, value: true, range: line)
            }

        case .listMarker(let level, let ordered):
            let indent = Self.listIndent * CGFloat(level + 1)
            let paragraph = paragraph(
                lineHeight: typography.lineHeightMultiple, size: typography.editorFontSize
            )
            // A bulleted item indents its first line to the same place as its
            // wrapped lines, exactly like a task item, and the whole `- ` marker
            // is collapsed so it occupies no width. Previously the marker kept
            // its character width and only the first line was outdented, so
            // bullets and checkboxes in the same list started their text at
            // different x positions.
            //
            // An ordered item is the exception: the number carries meaning and
            // stays visible, so it keeps a classic hanging indent.
            paragraph.firstLineHeadIndent = ordered ? indent - Self.listIndent : indent
            paragraph.headIndent = indent
            // List items are one list, not a run of separate paragraphs; full
            // paragraph spacing between them makes a short list look shattered.
            paragraph.paragraphSpacing = typography.paragraphSpacing * 0.25
            storage.addAttribute(.paragraphStyle, value: paragraph, range: fullText.paragraphRange(for: token.range))

            if ordered {
                // The number carries meaning, so it stays visible, just quieter.
                storage.addAttribute(
                    .foregroundColor, value: palette.faintText.platformColor, range: token.contentRange
                )
            } else if isBeingEdited {
                storage.addAttribute(
                    .foregroundColor, value: palette.faintText.platformColor, range: token.contentRange
                )
            } else {
                // Collapse the marker *and* the space after it, so the text
                // starts precisely at the paragraph indent. The bullet is then
                // painted into the reserved gutter; see InkstoneTextView.
                conceal([token.range])
                storage.addAttribute(.inkstoneBullet, value: level, range: token.range)
            }

        case .blockquote(let depth):
            let indent = Self.quoteIndent * CGFloat(depth)
            let paragraph = paragraph(
                lineHeight: typography.lineHeightMultiple, size: typography.editorFontSize
            )
            paragraph.firstLineHeadIndent = indent
            paragraph.headIndent = indent

            let line = fullText.paragraphRange(for: token.range)

            // Typora gives a blockquote `margin: 1rem 0` — around the *block*,
            // not around each of its lines. Every quoted line is a paragraph as
            // far as the text system is concerned, so applying the margin to all
            // of them put a full blank line between consecutive quoted lines:
            // 41.6pt apart where the line height is 25.6. Only the first and
            // last line of a run of quoted lines get it.
            let spacing = typography.paragraphSpacing * 0.5
            paragraph.paragraphSpacingBefore = isQuoted(lineBefore: line, in: fullText) ? 0 : spacing
            paragraph.paragraphSpacing = isQuoted(lineAfter: line, in: fullText) ? 0 : spacing
            storage.addAttribute(.paragraphStyle, value: paragraph, range: line)
            storage.addAttribute(.foregroundColor, value: palette.secondaryText.platformColor, range: line)
            // The rule down the left edge is drawn by the text view.
            storage.addAttribute(.inkstoneQuoteDepth, value: depth, range: line)

            if isBeingEdited {
                storage.addAttribute(
                    .foregroundColor, value: palette.faintText.platformColor, range: token.contentRange
                )
            } else {
                conceal([token.contentRange])
            }
        }
    }

    /// The text between a fenced block's ``` lines — the diagram source.
    private func mermaidBody(of block: NSRange, in text: NSString) -> String {
        let lines = fenceLines(of: block, in: text)
        guard let opener = lines.first else { return "" }
        let start = opener.location + opener.length
        let end = lines.count > 1 ? lines[1].location : block.location + block.length
        guard end > start else { return "" }
        return text.substring(with: NSRange(location: start, length: end - start))
    }

    /// Styles a fenced block as code. Extracted so an unrendered Mermaid diagram
    /// can fall back to exactly the same presentation.
    private func applyCodeBlockStyle(
        to storage: NSTextStorage,
        token: SyntaxToken,
        fullText: NSString,
        conceal: ([NSRange]) -> Void,
        isBeingEdited: Bool
    ) {
        let typography = style.typography
        let paragraph = paragraph(
            lineHeight: typography.codeLineHeightMultiple, size: typography.codeFontSize
        )
        paragraph.firstLineHeadIndent = 8
        paragraph.headIndent = 8
        storage.addAttributes([
            .font: typography.codeFont.platformFont(size: typography.codeFontSize),
            .foregroundColor: style.palette.text.platformColor,
            .inkstoneBlockFill: true,
        ], range: token.range)
        applyBlockStyle(
            paragraph, spacing: typography.paragraphSpacing * 0.6,
            to: token.range, in: storage, text: fullText
        )
    }

    /// The opening and closing ``` lines of a fenced block, including the
    /// trailing newline of the opener so the collapsed line takes no height.
    private func fenceLines(of block: NSRange, in text: NSString) -> [NSRange] {
        // Scans for the fence lines rather than deducing them from the block's
        // bounds. Deriving the closer from the last character assumed the match
        // ended exactly on it; when the pattern took a trailing newline with it,
        // the closing ``` was left visible in the middle of a rendered block.
        var lines: [NSRange] = []
        var location = block.location
        while location < NSMaxRange(block), location < text.length {
            let line = text.lineRange(for: NSRange(location: location, length: 0))
            let content = text.substring(with: line).trimmingCharacters(in: .whitespaces)
            if content.hasPrefix("```") || content.hasPrefix("~~~") {
                lines.append(NSRange(
                    location: line.location,
                    length: min(line.length, NSMaxRange(block) - line.location)
                ))
            }
            location = NSMaxRange(line)
        }
        return lines.filter { $0.length > 0 }
    }

    /// Draws a document's headings into an image to stand in for `[TOC]`.
    ///
    /// An image, because the placeholder is four characters wide and the table
    /// of contents is many lines tall — and the text on disk must not gain the
    /// lines it displays. The same reservation trick as an inline image: hide
    /// the marker, raise the line height, paint into the space.
    private func tableOfContentsImage(_ headings: [(level: Int, title: String)]) -> PlatformImage? {
        let body = NSMutableAttributedString()
        let size = style.typography.editorFontSize

        for heading in headings {
            let indent = CGFloat(min(heading.level, 6) - 1) * 18
            let paragraph = NSMutableParagraphStyle()
            paragraph.firstLineHeadIndent = indent
            paragraph.headIndent = indent
            paragraph.lineSpacing = 3

            body.append(NSAttributedString(
                string: heading.title + "\n",
                attributes: [
                    .font: style.typography.editorFont.platformFont(
                        size: heading.level <= 1 ? size * 0.95 : size * 0.88,
                        weight: heading.level <= 1 ? .semibold : .regular
                    ),
                    .foregroundColor: (heading.level <= 2 ? style.palette.text : style.palette.secondaryText)
                        .platformColor,
                    .paragraphStyle: paragraph,
                ]
            ))
        }
        guard body.length > 0 else { return nil }

        let bounds = body.boundingRect(
            with: CGSize(width: availableWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin],
            context: nil
        )
        let canvas = CGSize(width: ceil(bounds.width) + 2, height: ceil(bounds.height) + 2)
        guard canvas.width > 1, canvas.height > 1 else { return nil }

        #if os(macOS)
        let image = NSImage(size: canvas)
        image.lockFocus()
        body.draw(with: CGRect(origin: .zero, size: canvas), options: [.usesLineFragmentOrigin])
        image.unlockFocus()
        return image
        #else
        return UIGraphicsImageRenderer(size: canvas).image { _ in
            body.draw(
                with: CGRect(origin: .zero, size: canvas),
                options: [.usesLineFragmentOrigin],
                context: nil
            )
        }
        #endif
    }

    /// Reserves horizontal space for an inline formula and tags it for drawing.
    ///
    /// Unlike a block formula, this has to sit *within* a line of prose, so it
    /// cannot take the whole paragraph. The source is collapsed and the width the
    /// formula needs is added as kerning on its last character, pushing the
    /// following words along — the same rendering-only trick the table column
    /// alignment uses. Nothing is written to the file.
    private func inlineMath(_ image: PlatformImage, to storage: NSTextStorage, in range: NSRange) {
        guard range.length > 0 else { return }

        let tiny = PlatformFont.systemFont(ofSize: Self.concealedFontSize)
        storage.addAttribute(.font, value: tiny, range: range)
        storage.addAttribute(.foregroundColor, value: PlatformColor.clear, range: range)

        let last = NSRange(location: range.location + range.length - 1, length: 1)
        storage.addAttribute(.kern, value: image.size.width + 4, range: last)
        storage.addAttribute(.inkstoneInlineMath, value: image, range: range)
    }

    /// Makes room for an inline image and tags the run so the text view can draw it.
    ///
    /// `NSTextAttachment` is deliberately not used. TextKit 1's layout manager only
    /// produces an attachment glyph for the attachment character U+FFFC, and adding
    /// an `.attachment` attribute to ordinary characters is silently ignored — the
    /// image simply never appears. Inserting U+FFFC is not an option either,
    /// because the text storage is the note, and the file on disk must not gain
    /// characters the user did not type.
    ///
    /// So instead: collapse the `![[...]]` markup, reserve the image's height by
    /// raising the line height of that paragraph, and let `InkstoneTextView` paint
    /// the picture into the space that opens up.
    private func inlineImage(
        _ image: PlatformImage,
        to storage: NSTextStorage,
        in range: NSRange,
        fullText: NSString,
        centred: Bool = true
    ) {
        guard range.length > 0 else { return }

        let tiny = PlatformFont.systemFont(ofSize: Self.concealedFontSize)
        storage.addAttribute(.font, value: tiny, range: range)
        storage.addAttribute(.foregroundColor, value: PlatformColor.clear, range: range)

        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = image.size.height + Self.inlineImagePadding * 2
        paragraph.maximumLineHeight = image.size.height + Self.inlineImagePadding * 2
        paragraph.paragraphSpacing = style.typography.paragraphSpacing
        // Typora centres block images and display formulas; so does every
        // Markdown renderer worth copying. A table of contents is prose, though,
        // and belongs on the left margin.
        paragraph.alignment = centred ? .center : .natural

        // Only the *first* line carries the image's height. A fenced Mermaid
        // block or a multi-line `$$…$$` spans several lines, and leaving the
        // rest at body height left a column of invisible blank lines that
        // pushed everything after the diagram off the screen.
        let firstLine = fullText.lineRange(for: NSRange(location: range.location, length: 0))
        storage.addAttribute(.paragraphStyle, value: paragraph, range: firstLine)

        let flattened = NSMutableParagraphStyle()
        flattened.minimumLineHeight = 0.01
        flattened.maximumLineHeight = 0.01
        var location = firstLine.location + firstLine.length
        let end = range.location + range.length
        while location < end {
            let line = fullText.lineRange(for: NSRange(location: location, length: 0))
            let clipped = NSRange(
                location: line.location,
                length: min(line.length, end - line.location)
            )
            if clipped.length > 0 {
                storage.addAttribute(.paragraphStyle, value: flattened, range: clipped)
            }
            location = max(line.location + line.length, location + 1)
        }

        storage.addAttribute(.inkstoneInlineImage, value: image, range: range)
        storage.addAttribute(.inkstoneImageCentred, value: centred, range: range)
    }

    /// Breathing room above and below an inline image.
    static let inlineImagePadding: CGFloat = 8

    /// Cached text measurements for table cells, keyed by the cell's text.
    /// Bounded so a pathological document cannot grow it without limit.
    private nonisolated(unsafe) static var cellWidthCache: [String: CGFloat] = [:]
    /// Indent applied per list nesting level.
    /// Room reserved at the right of a block's first line for its copy button.
    static let copyButtonClearance: CGFloat = 38

    static let listIndent: CGFloat = 22
    /// Distance from the text's left edge to the centre of its list marker.
    /// Bullets and checkboxes share it so a mixed list lines up.
    static let markerGutter: CGFloat = 11
    /// Indent applied per level of `>` quoting.
    static let quoteIndent: CGFloat = 20

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

    /// Shrinks empty lines to the height of one paragraph gap.
    ///
    /// A blank line in the source is a real line in a text editor and takes a
    /// full line height — with body leading that is a much bigger gap than the
    /// 1rem Typora puts between paragraphs. Compressing it lands in the same
    /// place visually while keeping the line editable and selectable.
    private func compressBlankLines(in storage: NSTextStorage, text: NSString, within scope: NSRange) {
        guard mode != .source else { return }
        let gap = style.typography.paragraphSpacing
        guard gap > 0 else { return }

        var location = scope.location
        let end = scope.location + scope.length
        while location < end {
            let line = text.lineRange(for: NSRange(location: location, length: 0))
            defer { location = max(line.location + line.length, location + 1) }

            // Content excluding the newline itself.
            var contentLength = line.length
            while contentLength > 0,
                  let scalar = Unicode.Scalar(text.character(at: line.location + contentLength - 1)),
                  CharacterSet.newlines.contains(scalar) {
                contentLength -= 1
            }
            guard contentLength == 0, line.length > 0 else { continue }

            // Never touch a blank line inside a fenced block or a table, where it
            // is content rather than a separator.
            let existing = storage.attribute(.paragraphStyle, at: line.location, effectiveRange: nil)
            if let style = existing as? NSParagraphStyle, style.lineBreakMode == .byClipping { continue }

            let blank = NSMutableParagraphStyle()
            blank.minimumLineHeight = gap
            blank.maximumLineHeight = gap
            storage.addAttribute(.paragraphStyle, value: blank, range: line)
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
        ///
        /// Text measurement lays out glyphs and is by far the most expensive part
        /// of highlighting a document full of tables — it accounted for more than
        /// half the time on a 56KB note. Results are cached per (string, font):
        /// table cells repeat heavily, so the hit rate is high.
        func width(of range: NSRange) -> CGFloat {
            let key = text.substring(with: range)
            if let cached = Self.cellWidthCache[key] { return cached }
            let measured = (key as NSString).size(withAttributes: [.font: font]).width
            if Self.cellWidthCache.count < 4096 { Self.cellWidthCache[key] = measured }
            return measured
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
        // Measure once and keep it; the second pass used to re-measure every cell.
        var measured: [[CGFloat]] = rows.map { row in row.map { width(of: $0) } }
        for (rowIndex, row) in rows.enumerated() {
            for column in row.indices {
                widths[column] = max(widths[column], measured[rowIndex][column])
            }
        }

        for (rowIndex, row) in rows.enumerated() {
            for (column, cell) in row.enumerated() {
                let deficit = widths[column] - measured[rowIndex][column]
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
    private func applyCJKLatinSpacing(to storage: NSTextStorage, text: NSString, within scope: NSRange) {
        // Only the scoped substring is walked. On a large document this loop
        // visits every character, so restricting it matters as much as skipping
        // the tokens does.
        let string = text.substring(with: scope)
        let characters = Array(string.unicodeScalars)
        guard characters.count > 1 else { return }

        var utf16Offset = scope.location
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
            guard boundary, utf16Offset > scope.location, utf16Offset < text.length else { continue }
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
    /// Attached to `![[embed]]` runs that resolve to a file in the vault, so a
    /// click can open or preview it.
    static let inkstoneAttachment = NSAttributedString.Key("inkstoneAttachment")
    /// Carries the decoded image for an embed the text view should paint itself.
    static let inkstoneInlineImage = NSAttributedString.Key("inkstoneInlineImage")
    /// Marks a concealed list marker so a bullet can be drawn in its place.
    static let inkstoneBullet = NSAttributedString.Key("inkstoneBullet")
    /// Marks a quoted line so its left rule can be drawn.
    static let inkstoneQuoteDepth = NSAttributedString.Key("inkstoneQuoteDepth")
    /// Marks a concealed task marker so a checkbox can be drawn there. Bool.
    static let inkstoneCheckbox = NSAttributedString.Key("inkstoneCheckbox")
    /// A rounded fill hugging the text, drawn by the view. Value is a colour.
    static let inkstoneInlineFill = NSAttributedString.Key("inkstoneInlineFill")

    /// A thematic break, drawn as a line across the text width.
    static let inkstoneHorizontalRule = NSAttributedString.Key("inkstoneHorizontalRule")

    /// A fenced code block or table, drawn as one continuous panel.
    ///
    /// `.backgroundColor` cannot do this: it paints per glyph run, so a blank
    /// line inside a fence gets no fill at all and the gaps between paragraphs
    /// stay unpainted. A block of prose with blank lines between paragraphs came
    /// out as a stack of separate grey stripes rather than one panel.
    static let inkstoneBlockFill = NSAttributedString.Key("inkstoneBlockFill")
    /// A typeset formula to be drawn within a line of prose. Value is an image.
    static let inkstoneInlineMath = NSAttributedString.Key("inkstoneInlineMath")
    /// Attached to a footnote marker so clicking it can jump to its definition.
    static let inkstoneFootnote = NSAttributedString.Key("inkstoneFootnote")
    /// Whether a block image is centred. Value is a Bool.
    static let inkstoneImageCentred = NSAttributedString.Key("inkstoneImageCentred")
    /// Marks an h1/h2 so a rule can be drawn beneath it. Value is the level.
    static let inkstoneHeadingRule = NSAttributedString.Key("inkstoneHeadingRule")
}
