import Foundation
import InkstoneCore

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Holds the editor's one cached scan.
///
/// The caching itself is `InkstoneCore.CachingScanner`, where it is tested. This
/// is the main-actor home for it, plus the debug switches: the highlighter is a
/// value recreated on every pass, so the cache cannot live inside it.
@MainActor
final class ScanCache {
    static let shared = ScanCache()

    /// `INKSTONE_SCANNER=legacy` runs the original regex scanner instead of the
    /// parser, so the two can be compared through the *highlighter* — on the
    /// attributes that reach the screen — and not only on the token stream,
    /// which is what `EngineDiffTests` already covers. A token diff cannot tell
    /// you that a paragraph ended up indented differently.
    private var scanner: CachingScanner = {
        #if DEBUG
        if ProcessInfo.processInfo.environment["INKSTONE_SCANNER"] == "legacy" {
            return CachingScanner(engine: .legacy)
        }
        #endif
        return CachingScanner()
    }()

    /// Scans performed, for the benchmark hooks to report. Counts the bypass
    /// path too — a diagnostic that under-reports is worse than none.
    var scanCount: Int { scanner.scanCount + bypassScans }
    private var bypassScans = 0

    func tokens(for text: String) -> [SyntaxToken] {
        #if DEBUG
        // Reproduces the pre-cache behaviour in the same binary, so the two can
        // be measured against each other without reverting anything.
        if ProcessInfo.processInfo.environment["INKSTONE_NO_SCAN_CACHE"] != nil {
            var uncached = CachingScanner()
            bypassScans += 1
            return uncached.tokens(for: text)
        }
        #endif
        return scanner.tokens(for: text)
    }
}

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

    /// Resolves an embed target to a file in the vault. Injected rather than
    /// reached for directly so the highlighter stays free of app state and can be
    /// exercised without a vault.
    var resolveAttachment: ((String) -> URL?)?
    /// Supplies the text an `![[Note]]` should show. Left nil when rendering an
    /// embed's own content, which is what keeps one note embedding another from
    /// recursing.
    var resolveNoteEmbed: ((WikiLink) -> String?)?
    /// Text width available for inline images, so a photo is scaled to the
    /// measure rather than overflowing the column.
    var availableWidth: CGFloat = 680
    /// Draw the frontmatter as a properties table rather than hiding it.
    /// Mirrors `SettingsData.showFrontmatterAsProperties`, injected rather than
    /// read directly so the highlighter stays free of app state.
    var showProperties = true

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

        let tokens = ScanCache.shared.tokens(for: text)
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

        // Inline HTML spans, paired before the loop because a tag on its own
        // says nothing: it is `<b>` *and* its `</b>` that mean bold, and the two
        // are separate tokens.
        let html = Self.htmlSpans(in: tokens)

        // The body lines of every folded callout, collected before the loop and
        // collapsed after it. Doing it while the callout's own token was being
        // applied did not work: those lines carry `.blockquote` tokens of their
        // own, they sort *after* the header, and their paragraph style replaced
        // the collapsed one — so a folded callout hid its text and kept its
        // height, leaving a quote rule down an empty column.
        let foldedBodies: [NSRange] = tokens.compactMap { token in
            guard case .callout(_, true, _) = token.kind else { return nil }
            if let caretLineRange,
               NSIntersectionRange(caretLineRange, token.range).length > 0 { return nil }
            return calloutBody(after: token.range, in: text as NSString)
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

        // Attributes first, then the tags are collapsed — in that order, because
        // a span covers the tags nested inside it and setting a font across them
        // would give back the width they had been collapsed out of.
        if mode != .source {
            for body in foldedBodies where NSIntersectionRange(body, scope).length > 0 {
                collapseLines(body, in: storage)
            }
        }

        for span in html.spans where NSIntersectionRange(span.content, scope).length > 0 {
            applyHTML(span, to: storage, fullText: text as NSString)
        }
        if mode != .source {
            let tiny = PlatformFont.systemFont(ofSize: Self.concealedFontSize)
            for tag in html.tags where NSIntersectionRange(tag, scope).length > 0 {
                let line = (text as NSString).paragraphRange(for: tag)
                if let caretLineRange, NSIntersectionRange(caretLineRange, line).length > 0 { continue }
                storage.addAttribute(.font, value: tiny, range: tag)
                storage.addAttribute(.foregroundColor, value: PlatformColor.clear, range: tag)
                #if os(macOS)
                storage.addAttribute(.spellingState, value: 0, range: tag)
                #endif
            }
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
                alignTableColumns(
                    range, in: storage, text: text as NSString, caretLineRange: caretLineRange
                )
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

        /// The face an inline run should use.
        ///
        /// Tables used to be laid out in the code font — the only way to get
        /// columns to line up when the pipes were still on screen — and every
        /// inline run inside a cell had to match or it knocked the column out.
        /// Columns are now positioned by measured kerning instead, so a cell is
        /// ordinary prose and `isInTable` no longer changes the face.
        func runFont(weight: PlatformFont.Weight? = nil) -> PlatformFont {
            let size = typography.editorFontSize
            if let weight { return typography.editorFont.platformFont(size: size, weight: weight) }
            return typography.editorFont.platformFont(size: size)
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
            // Editing it shows the YAML, the same as any other syntax the caret
            // is sitting in.
            if isBeingEdited {
                storage.addAttribute(
                    .foregroundColor, value: palette.faintText.platformColor, range: token.range
                )
                setFont(typography.codeFont.platformFont(size: typography.codeFontSize), range: token.range)
            } else if showProperties,
                      let block = propertiesBlock(for: token.range, in: fullText) {
                // Otherwise it becomes a properties table, as in Obsidian. It
                // used to be concealed outright on the grounds that the
                // inspector already showed the properties — which is only true
                // when the inspector happens to be open, and left a note's tags
                // and status invisible the rest of the time.
                reserveBlock(block, to: storage, in: token.range, fullText: fullText)
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

            // A setext heading — `Title` on one line over `=====` on the next —
            // carries its underline inside the token, and the underline is
            // syntax. Left alone it is drawn as part of the title, at title size:
            // a row of giant equals signs under every such heading.
            //
            // Nothing needed doing here before the parser landed, because the old
            // scanner's heading pattern was ATX-only and never saw these at all.
            // The `---` form was matched as a horizontal rule instead, which
            // happened to look right — so this is a regression the parser
            // introduced, and it only became visible on a document that used the
            // syntax. Applied last: it has to overwrite the paragraph style set
            // just above.
            if fullText.character(at: token.range.location) != 0x23 {  // not `#`
                let underline = fullText.lineRange(
                    for: NSRange(location: max(token.range.location, NSMaxRange(token.range) - 1), length: 0)
                )
                if underline.location > token.range.location { concealLines(underline) }
            } else {
                // A closed ATX heading — `## Title ##` — puts its trailing run of
                // hashes *outside* the node cmark reports, so without this they
                // are left behind as body text after the title.
                let line = fullText.lineRange(for: token.range)
                var tail = NSRange(
                    location: NSMaxRange(token.range),
                    length: max(0, NSMaxRange(line) - NSMaxRange(token.range))
                )
                while tail.length > 0,
                      let scalar = Unicode.Scalar(fullText.character(at: NSMaxRange(tail) - 1)),
                      CharacterSet.newlines.contains(scalar) {
                    tail.length -= 1
                }
                if tail.length > 0,
                   fullText.substring(with: tail).allSatisfy({ $0 == "#" || $0 == " " || $0 == "\t" }) {
                    conceal([tail])
                }
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
            // A PDF joins the image path: its first page is a picture, and a
            // document embedded into a note is embedded to be looked at.
            let previewable: Set<AttachmentKind> = [.image, .pdf]
            if let resolved, previewable.contains(AttachmentKind(url: resolved)), !isBeingEdited,
               let image = sizedEmbed(resolved, hint: link.embedSize) {
                if isAloneOnItsLine(token.range, in: fullText) {
                    inlineImage(image, to: storage, in: token.range, fullText: fullText)
                } else if !inlineThumbnail(image, to: storage, in: token.range) {
                    inlineImage(image, to: storage, in: token.range, fullText: fullText)
                }
                storage.addAttribute(.inkstoneAttachment, value: resolved, range: token.range)
                break
            }

            // A note, whose *content* the embed stands for. Rendered into a
            // picture and placed where the markup was, since the buffer is this
            // file and cannot hold another one's text.
            //
            // Tested on "is it Markdown", not on "did the attachment resolver
            // fail": the vault resolver finds notes too, so keying on failure
            // sent every `![[Note]]` down the attachment path and rendered it as
            // a link. It looked right offscreen only because the benchmark hook's
            // resolver does not append `.md`.
            let isNoteTarget = resolved.map { $0.pathExtension.lowercased() == "md" } ?? true
            if isNoteTarget, !isBeingEdited, isAloneOnItsLine(token.range, in: fullText),
               let embedded = resolveNoteEmbed?(link),
               let picture = TransclusionRenderer.shared.image(
                   for: embedded, style: style, width: availableWidth
               ) {
                inlineImage(picture, to: storage, in: token.range, fullText: fullText, centred: false)
                storage.addAttribute(.inkstoneWikiLink, value: link, range: token.range)
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
                if isAloneOnItsLine(token.range, in: fullText) {
                    inlineImage(image, to: storage, in: token.range, fullText: fullText)
                } else if !inlineThumbnail(image, to: storage, in: token.range) {
                    inlineImage(image, to: storage, in: token.range, fullText: fullText)
                }
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

        case .callout(let type, let folded, _):
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

            // The disclosure the renderer draws, and what a click on it does.
            // Marked on the header even when expanded: a callout you cannot fold
            // is a callout whose `-` does nothing, which is how this arrived —
            // the flag was parsed and read by nobody.
            storage.addAttribute(.inkstoneCalloutFold, value: folded, range: token.range)



        case .htmlTag(let name, _):
            // A tag we cannot express — `<span style=…>`, `<img>`, `<br>` — stays
            // on screen, quietened. Hiding it would drop what the author wrote
            // and put nothing in its place. The ones we *can* express are
            // collapsed after the loop, once their pairs are known: an unclosed
            // `<b>` styles nothing and so must not vanish either.
            if Self.htmlAttribute(for: name) == nil {
                storage.addAttribute(
                    .foregroundColor, value: palette.faintText.platformColor, range: token.range
                )
            }

        case .escape:
            // Only the backslash goes. `\*` is written to get a literal `*`, and
            // the `*` is ordinary text sitting right after this range.
            conceal([token.range])

        case .entity(let replacement):
            // The source stays in the file — it is the file — so the entity is
            // concealed and its character drawn in the gap it leaves, the same
            // reservation trick an inline formula uses.
            if isBeingEdited {
                storage.addAttribute(
                    .foregroundColor, value: palette.secondaryText.platformColor, range: token.range
                )
            } else {
                inlineText(replacement, to: storage, in: token.range)
            }

        case .comment:
            // `%%…%%` is a note to yourself, and the point of it is that it is
            // not part of the note. Dimming it left it on screen taking up the
            // space it was written to stay out of; it now collapses like every
            // other piece of syntax, and comes back on the caret's line.
            if isBeingEdited {
                storage.addAttribute(
                    .foregroundColor, value: palette.faintText.platformColor, range: token.range
                )
            } else if isAloneOnItsLine(token.range, in: fullText) {
                // A block comment takes whole lines, so its lines go too —
                // otherwise it leaves a run of blank ones behind.
                concealLines(fullText.paragraphRange(for: token.range))
            } else {
                conceal([token.range])
            }

        case .table:
            // A table is prose in a grid, not code.
            //
            // It used to be drawn in the code font on the code background with
            // the `|` characters left visible, because that was the only way to
            // make columns line up: monospaced glyphs and the pipes themselves
            // as the column rules. It worked, and it read as a code block —
            // which is what it looked like, because it was styled as one.
            //
            // Now the pipes are concealed like any other syntax and the columns
            // are positioned by measured kerning, so the cells can use the body
            // face and the block can be drawn with table chrome instead of a
            // panel.
            //
            // Rows wrap rather than clip. `.byClipping` looks tidy until a table
            // is wider than the column: the row is then cut off at the container
            // edge — which is *outside* the border, since the panel is inset from
            // it — so the text both escaped the box and lost its end. Wrapping
            // costs the column alignment on that one row and keeps everything
            // inside the frame, which is the better trade.
            //
            // By word, not by character. Chinese still breaks between characters
            // — standard line breaking gives an opportunity at every one, no
            // space required — while `1621` and `Claude` stay whole. Character
            // wrapping was tried and split a four-digit number across two lines.
            let paragraph = paragraph(
                lineHeight: typography.lineHeightMultiple * 1.25, size: typography.editorFontSize
            )
            paragraph.firstLineHeadIndent = Self.tableCellPadding
            paragraph.headIndent = Self.tableCellPadding
            paragraph.lineBreakMode = .byWordWrapping
            storage.addAttributes([
                .font: typography.editorFont.platformFont(size: typography.editorFontSize),
                .foregroundColor: palette.text.platformColor,
                // Kept so the copy button and its hit test keep working; the
                // renderer consults `.inkstoneTableBlock` to decide which of the
                // two presentations to paint.
                .inkstoneBlockFill: true,
                .inkstoneTableBlock: true,
            ], range: token.range)
            // Typora sets `margin: 0.8em 0` on tables — around the table, not
            // around each row.
            applyBlockStyle(
                paragraph, spacing: typography.paragraphSpacing * 0.6,
                to: token.range, in: storage, text: fullText
            )

        case .tableHeaderRow:
            setFont(
                typography.editorFont.platformFont(size: typography.editorFontSize, weight: .semibold),
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
                + inheritedIndent(at: token.range.location, in: storage)
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
            // The state *character*, not a yes/no. `contentRange` is exactly the
            // one character between the brackets, so Obsidian's `[/]`, `[-]`,
            // `[>]` and the rest reach the renderer intact instead of collapsing
            // into "not blank, therefore finished".
            let marker = token.contentRange.length == 1
                ? fullText.substring(with: token.contentRange)
                : (checked ? "x" : " ")
            storage.addAttribute(.inkstoneCheckbox, value: marker, range: token.range)

            // Only finished states read as finished. An item in progress or
            // deferred is still work, and striking it through said otherwise.
            if EditorRenderer.TaskState(marker).isFinished {
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
                + inheritedIndent(at: token.range.location, in: storage)
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
        // The same inset a table cell gets, so a code block and a table sitting
        // next to each other do not start their text at different places.
        paragraph.firstLineHeadIndent = Self.tableCellPadding
        paragraph.headIndent = Self.tableCellPadding
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
            // Leading `>` dropped as well as whitespace: a fence inside a
            // blockquote reads `> ```swift`, and testing the raw line left the
            // fences of every quoted code block on screen.
            let content = text.substring(with: line)
                .drop { $0 == " " || $0 == "\t" || $0 == ">" }
                .trimmingCharacters(in: .whitespaces)
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

    /// Parses the frontmatter under `range` into a drawable properties table.
    private func propertiesBlock(for range: NSRange, in fullText: NSString) -> PropertiesBlock? {
        let source = fullText.substring(with: range)
        let (frontmatter, _) = FrontmatterParser.parse(source)
        return PropertiesBlock(frontmatter: frontmatter, source: source, style: style)
    }

    /// Collapses `range` and reserves `block.height` for the renderer to paint into.
    ///
    /// Same mechanism as `inlineImage`: the first line carries the whole height
    /// and every line after it is flattened, so the reserved space is one gap
    /// rather than one gap plus a column of empty lines.
    private func reserveBlock(
        _ block: PropertiesBlock,
        to storage: NSTextStorage,
        in range: NSRange,
        fullText: NSString
    ) {
        guard range.length > 0 else { return }

        let tiny = PlatformFont.systemFont(ofSize: Self.concealedFontSize)
        storage.addAttribute(.font, value: tiny, range: range)
        storage.addAttribute(.foregroundColor, value: PlatformColor.clear, range: range)

        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = block.height
        paragraph.maximumLineHeight = block.height
        paragraph.paragraphSpacing = style.typography.paragraphSpacing

        let firstLine = fullText.lineRange(for: NSRange(location: range.location, length: 0))
        storage.addAttribute(.paragraphStyle, value: paragraph, range: firstLine)

        let flattened = NSMutableParagraphStyle()
        flattened.minimumLineHeight = 0.01
        flattened.maximumLineHeight = 0.01
        flattened.paragraphSpacing = 0
        flattened.paragraphSpacingBefore = 0
        var location = NSMaxRange(firstLine)
        let end = NSMaxRange(range)
        while location < end {
            let line = fullText.lineRange(for: NSRange(location: location, length: 0))
            let clipped = NSRange(location: line.location, length: min(line.length, end - line.location))
            guard clipped.length > 0 else { break }
            storage.addAttribute(.paragraphStyle, value: flattened, range: clipped)
            location = max(NSMaxRange(line), location + 1)
        }

        storage.addAttribute(.inkstoneProperties, value: block, range: range)
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

    /// Loads an embedded picture at the size its `|300` or `|300x200` hint asks
    /// for, or at the measure when there is no hint.
    ///
    /// The hint was parsed all along — `WikiLink` has carried it since the
    /// scanner was written — and then thrown away here, so `![[photo.png|160]]`
    /// rendered at exactly the same width as `![[photo.png]]`.
    ///
    /// Capped at the measure whatever the hint says: a note asking for 4000
    /// points should not push the column open.
    private func sizedEmbed(_ url: URL, hint: WikiLink.EmbedSize?) -> PlatformImage? {
        guard let hint else {
            return AttachmentImageCache.shared.image(for: url, maxWidth: availableWidth)
        }
        let width = min(CGFloat(hint.width), availableWidth)
        guard let image = AttachmentImageCache.shared.image(for: url, maxWidth: width) else {
            return nil
        }
        // The cache buckets by 32pt and never scales a picture up, so it answers
        // "no wider than this" rather than "this wide". A hint is a size, so the
        // result is resized to match it exactly.
        let height: CGFloat
        if let hinted = hint.height {
            height = CGFloat(hinted)
        } else if image.size.width > 0 {
            height = image.size.height * width / image.size.width
        } else {
            return image
        }
        guard width > 1, height > 1 else { return image }
        guard abs(image.size.width - width) > 0.5 || abs(image.size.height - height) > 0.5 else {
            return image
        }
        return image.resizedForInline(to: CGSize(width: width, height: height))
    }

    /// An inline HTML element: the tag name and the text between its tags.
    struct HTMLSpan {
        let name: String
        let content: NSRange
    }

    /// Pairs `<b>` with `</b>`, and reports which tags actually paired.
    ///
    /// A stack per name, so nesting works and an unclosed tag never produces a
    /// span. Its own range is not returned either, so it stays on screen: a tag
    /// that styles nothing must not also disappear, or the author's text is gone
    /// with nothing to show for it.
    ///
    /// Spans come back outermost first. `<b>bold <i>x</i></b>` closes the inner
    /// tag first, so the natural order is inside-out — and applying it that way
    /// let the outer span's font overwrite the inner one, losing the italic and
    /// un-collapsing the concealed tags into blank gaps.
    static func htmlSpans(in tokens: [SyntaxToken]) -> (spans: [HTMLSpan], tags: [NSRange]) {
        var open: [String: [NSRange]] = [:]
        var spans: [HTMLSpan] = []
        var tags: [NSRange] = []
        for token in tokens {
            guard case .htmlTag(let name, let isClosing) = token.kind,
                  htmlAttribute(for: name) != nil
            else { continue }
            if isClosing {
                guard let opener = open[name]?.popLast() else { continue }
                let start = NSMaxRange(opener)
                guard token.range.location > start else { continue }
                spans.append(HTMLSpan(
                    name: name,
                    content: NSRange(location: start, length: token.range.location - start)
                ))
                tags.append(opener)
                tags.append(token.range)
            } else {
                open[name, default: []].append(token.range)
            }
        }
        spans.sort {
            $0.content.location == $1.content.location
                ? $0.content.length > $1.content.length
                : $0.content.location < $1.content.location
        }
        return (spans, tags)
    }

    /// What a tag means, or nil for one we cannot express.
    ///
    /// A whitelist, and deliberately a short one: these are the tags with a
    /// direct equivalent in text attributes. Anything else — layout, colour,
    /// images — would need a renderer rather than an attribute, and is left as
    /// source, which at least shows the reader exactly what is in the file.
    static func htmlAttribute(for name: String) -> String? {
        switch name {
        case "b", "strong", "i", "em", "u", "s", "del", "strike",
             "mark", "code", "sub", "sup":
            return name
        default:
            return nil
        }
    }

    private func applyHTML(_ span: HTMLSpan, to storage: NSTextStorage, fullText: NSString) {
        guard span.content.length > 0, NSMaxRange(span.content) <= storage.length else { return }
        let typography = style.typography
        let size = typography.editorFontSize
        let existing = storage.attribute(.font, at: span.content.location, effectiveRange: nil)
            as? PlatformFont

        switch span.name {
        case "b", "strong":
            storage.addAttribute(
                .font, value: typography.editorFont.platformFont(
                    size: existing.map { Double($0.pointSize) } ?? size, weight: .bold
                ),
                range: span.content
            )
        case "i", "em":
            storage.addAttribute(
                .font, value: italicVariant(of: existing ?? typography.editorFont.platformFont(size: size)),
                range: span.content
            )
        case "u":
            storage.addAttribute(
                .underlineStyle, value: NSUnderlineStyle.single.rawValue, range: span.content
            )
        case "s", "del", "strike":
            storage.addAttribute(
                .strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: span.content
            )
            storage.addAttribute(
                .foregroundColor, value: style.palette.secondaryText.platformColor, range: span.content
            )
        case "mark":
            storage.addAttribute(
                .backgroundColor, value: style.palette.highlight.platformColor, range: span.content
            )
        case "code":
            storage.addAttributes([
                .font: typography.codeFont.platformFont(size: typography.codeFontSize),
                .foregroundColor: style.palette.accent.platformColor,
                .inkstoneInlineFill: style.palette.codeBackground.platformColor,
            ], range: span.content)
        case "sub", "sup":
            storage.addAttributes([
                .font: typography.editorFont.platformFont(size: size * 0.72),
                .baselineOffset: span.name == "sup" ? size * 0.32 : -size * 0.16,
            ], range: span.content)
        default:
            break
        }
    }

    /// Collapses `range` and reserves room for `replacement` to be drawn there.
    ///
    /// Used for HTML entities, where five characters of source stand for one
    /// character of text. Same mechanism as an inline formula: hide the source,
    /// add the replacement's width as kerning on the last character so the words
    /// after it move along, and let the view paint into the gap. The buffer keeps
    /// what the author typed.
    private func inlineText(_ replacement: String, to storage: NSTextStorage, in range: NSRange) {
        guard range.length > 0, !replacement.isEmpty else { return }
        let font = style.typography.editorFont.platformFont(size: style.typography.editorFontSize)
        let width = (replacement as NSString).size(withAttributes: [.font: font]).width
        guard width > 0 else { return }

        let tiny = PlatformFont.systemFont(ofSize: Self.concealedFontSize)
        storage.addAttribute(.font, value: tiny, range: range)
        storage.addAttribute(.foregroundColor, value: PlatformColor.clear, range: range)
        let last = NSRange(location: NSMaxRange(range) - 1, length: 1)
        storage.addAttribute(.kern, value: width, range: last)
        storage.addAttribute(.inkstoneInlineText, value: replacement, range: range)
    }

    /// The quoted lines under a callout header — its body.
    ///
    /// Walked rather than taken from a token: a callout token is one line, and
    /// the blockquote it heads is not.
    private func calloutBody(after header: NSRange, in text: NSString) -> NSRange? {
        var location = NSMaxRange(text.paragraphRange(for: header))
        let start = location
        while location < text.length {
            let line = text.paragraphRange(for: NSRange(location: location, length: 0))
            guard isQuotedLine(line, in: text) else { break }
            location = max(NSMaxRange(line), location + 1)
        }
        guard location > start else { return nil }
        return NSRange(location: start, length: location - start)
    }

    /// Hides a run of lines and takes away the height they would keep.
    private func collapseLines(_ range: NSRange, in storage: NSTextStorage) {
        guard range.length > 0, NSMaxRange(range) <= storage.length else { return }
        let tiny = PlatformFont.systemFont(ofSize: Self.concealedFontSize)
        storage.addAttribute(.font, value: tiny, range: range)
        storage.addAttribute(.foregroundColor, value: PlatformColor.clear, range: range)
        #if os(macOS)
        storage.addAttribute(.spellingState, value: 0, range: range)
        #endif
        let collapsed = NSMutableParagraphStyle()
        collapsed.minimumLineHeight = 0.01
        collapsed.maximumLineHeight = 0.01
        collapsed.paragraphSpacing = 0
        collapsed.paragraphSpacingBefore = 0
        storage.addAttribute(.paragraphStyle, value: collapsed, range: range)
        // The quote rule is drawn from this, and a folded body has no rule.
        storage.removeAttribute(.inkstoneQuoteDepth, range: range)
    }

    /// The head indent an enclosing block has already given this line.
    ///
    /// A list inside a blockquote used to *replace* the quote's indent rather
    /// than add to it, so its bullets sat outside the quote's rule instead of
    /// within it. Tokens are applied in source order and the quote's paragraph
    /// style lands first, so reading it back is enough — and `applyBaseAttributes`
    /// resets paragraph styles at the start of every pass, so this cannot
    /// accumulate across passes.
    private func inheritedIndent(at location: Int, in storage: NSTextStorage) -> CGFloat {
        guard location < storage.length,
              let paragraph = storage.attribute(.paragraphStyle, at: location, effectiveRange: nil)
                as? NSParagraphStyle
        else { return 0 }
        return paragraph.headIndent
    }

    /// Whether everything else on `range`'s line is whitespace.
    ///
    /// A block image takes the whole line's height and is painted centred in it;
    /// if there are words on that line they keep their baseline and the picture
    /// is drawn straight over them. So the two cases have to be told apart, and
    /// this is the test: an embed on a line of its own is a block, an embed
    /// among words is an inline thumbnail.
    private func isAloneOnItsLine(_ range: NSRange, in text: NSString) -> Bool {
        let line = text.lineRange(for: range)
        let before = NSRange(location: line.location, length: range.location - line.location)
        let after = NSRange(
            location: NSMaxRange(range),
            length: max(0, NSMaxRange(line) - NSMaxRange(range))
        )
        func isBlank(_ probe: NSRange) -> Bool {
            probe.length == 0 || text.substring(with: probe)
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return isBlank(before) && isBlank(after)
    }

    /// Draws an embedded picture at text size, among the words on its line.
    ///
    /// The same reservation trick as an inline formula: collapse the markup, add
    /// the picture's width as kerning on its last character so the following
    /// words move along, and let the view paint into the gap. Nothing is written
    /// to the file.
    private func inlineThumbnail(
        _ image: PlatformImage,
        to storage: NSTextStorage,
        in range: NSRange
    ) -> Bool {
        guard range.length > 0, image.size.height > 0 else { return false }
        let target = style.typography.editorFontSize * 1.4
        let scale = min(1, target / image.size.height)
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        guard size.width > 1 else { return false }

        let scaled = image.resizedForInline(to: size)

        let tiny = PlatformFont.systemFont(ofSize: Self.concealedFontSize)
        storage.addAttribute(.font, value: tiny, range: range)
        storage.addAttribute(.foregroundColor, value: PlatformColor.clear, range: range)
        let last = NSRange(location: NSMaxRange(range) - 1, length: 1)
        storage.addAttribute(.kern, value: size.width + 4, range: last)
        storage.addAttribute(.inkstoneInlineThumbnail, value: scaled, range: range)
        return true
    }

    /// Breathing room above and below an inline image.
    static let inlineImagePadding: CGFloat = 8

    /// Indent applied per list nesting level.
    /// Room reserved at the right of a block's first line for its copy button.
    static let copyButtonClearance: CGFloat = 38

    /// Cached widths for plain table cells, keyed by their text. Only used for
    /// cells that are a single run of the body face, so the font is implied.
    /// Bounded so a pathological document cannot grow it without limit.
    private nonisolated(unsafe) static var cellWidthCache: [String: CGFloat] = [:]

    /// Space between a table's cell text and its border, and between columns.
    static let tableCellPadding: CGFloat = 12

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
            //
            // Keyed on the block attribute rather than on `.byClipping`, which is
            // what this used to test. Only tables ever set that mode, so a blank
            // line inside a code fence was being compressed all along — and when
            // tables changed to wrapping, the test stopped matching anything at
            // all. The attribute is what actually means "this is a block".
            if storage.attribute(.inkstoneBlockFill, at: line.location, effectiveRange: nil) != nil {
                continue
            }

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
    private func alignTableColumns(
        _ tableRange: NSRange,
        in storage: NSTextStorage,
        text: NSString,
        caretLineRange: NSRange?
    ) {

        /// Measures a cell as it will actually be drawn.
        ///
        /// From the storage, not from the raw characters. This pass runs last —
        /// after every font, weight and concealment has been applied — so the
        /// attributed substring is literally what TextKit will lay out: a bold
        /// cell measures bold, an inline code span measures in the code face, and
        /// a `**` collapsed to 0.01pt measures as the nothing it draws as.
        ///
        /// Measuring the raw string in one font instead was the cause of the
        /// drift: a row containing `**bold**` measured too narrow where the bold
        /// draws wide and too wide where the markers vanish, and every cell after
        /// it in that row was pushed out of its column.
        ///
        /// Measuring the attributed substring is several times dearer than
        /// measuring a plain string, and on a document of 200 tables that showed
        /// up as 55ms a pass. Most cells carry no inline formatting at all, so a
        /// cell that is one run of the body face takes the old cached path and
        /// only the ones that actually differ pay for the accurate measurement.
        let bodyFont = style.typography.editorFont.platformFont(size: style.typography.editorFontSize)

        func width(of range: NSRange) -> CGFloat {
            guard range.length > 0, NSMaxRange(range) <= storage.length else { return 0 }

            var runRange = NSRange(location: 0, length: 0)
            let font = storage.attribute(.font, at: range.location, effectiveRange: &runRange)
                as? PlatformFont
            let isPlain = font == bodyFont && NSMaxRange(runRange) >= NSMaxRange(range)
            guard isPlain else {
                return storage.attributedSubstring(from: range).size().width
            }

            let key = text.substring(with: range)
            if let cached = Self.cellWidthCache[key] { return cached }
            let measured = (key as NSString).size(withAttributes: [.font: bodyFont]).width
            if Self.cellWidthCache.count < 4096 { Self.cellWidthCache[key] = measured }
            return measured
        }

        // Cells per row, as ranges between the pipes. Delimiter rows are skipped:
        // they are concealed anyway, and their dashes would distort the widths.
        var rows: [[NSRange]] = []
        // Every `|` in the table, so they can be concealed once the columns have
        // been measured. The pipes are syntax: they are what made a table look
        // like a code listing, and nothing else on screen needs them.
        var pipePositions: [Int] = []
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
            guard !trimmed.isEmpty else { continue }
            // A delimiter row is only pipes, dashes, colons and spaces.
            if trimmed.allSatisfy({ "|-: \t".contains($0) }) { continue }

            // Trailing newline excluded, so the last cell of a row does not
            // swallow the line break and measure wide by a space.
            var body = content
            while body.length > 0,
                  let scalar = Unicode.Scalar(text.character(at: NSMaxRange(body) - 1)),
                  CharacterSet.newlines.contains(scalar) {
                body.length -= 1
            }
            guard body.length > 0 else { continue }

            var pipes: [Int] = []
            for offset in 0..<body.length where text.character(at: body.location + offset) == 0x7C {
                pipes.append(body.location + offset)
            }
            guard !pipes.isEmpty else { continue }
            // Collected even for rows that yield no usable cells, so a malformed
            // row does not keep its pipes while its neighbours lose theirs.
            pipePositions.append(contentsOf: pipes)

            // Cells are the runs *between* the pipes, with the row's own edges
            // standing in for the outer ones. Written this way because GFM makes
            // the outer pipes optional: `A | B` is as valid a row as `| A | B |`,
            // and the previous version required the leading pipe and so skipped
            // the bare form entirely — leaving those tables unaligned with their
            // pipes still showing.
            let boundaries = [body.location - 1] + pipes + [NSMaxRange(body)]
            var cells: [NSRange] = []
            for index in 0..<(boundaries.count - 1) {
                let start = boundaries[index] + 1
                let length = boundaries[index + 1] - start
                if length > 0 { cells.append(NSRange(location: start, length: length)) }
            }
            if !cells.isEmpty { rows.append(cells) }
        }

        // The delimiter row's pipes are collected separately: that line is
        // concealed whole, so it never reaches the loop above.
        do {
            var location = tableRange.location
            while location < NSMaxRange(tableRange) {
                let line = text.lineRange(for: NSRange(location: location, length: 0))
                defer { location = max(NSMaxRange(line), location + 1) }
                let trimmed = text.substring(with: line).trimmingCharacters(in: .whitespacesAndNewlines)
                guard trimmed.contains("|"), trimmed.allSatisfy({ "|-: \t".contains($0) }) else { continue }
                for offset in 0..<line.length where text.character(at: line.location + offset) == 0x7C {
                    pipePositions.append(line.location + offset)
                }
            }
        }

        // Hide the pipes, except on the row the caret is on — the same rule every
        // other piece of syntax follows, so a table can still be edited as text.
        //
        // A pipe with text on both sides of it is a *boundary between cells*, and
        // it is marked as one so the renderer can draw a hairline where it was.
        // Concealing them and stopping there was tried and reported back: a table
        // whose columns cannot be aligned then has no cell boundaries at all, and
        // its header reads as a run of words rather than as four column names.
        let tiny = PlatformFont.systemFont(ofSize: Self.concealedFontSize)
        for pipe in pipePositions {
            let line = text.paragraphRange(for: NSRange(location: pipe, length: 0))
            if let caretLineRange, NSIntersectionRange(caretLineRange, line).length > 0 { continue }
            let range = NSRange(location: pipe, length: 1)
            storage.addAttribute(.font, value: tiny, range: range)
            storage.addAttribute(.foregroundColor, value: PlatformColor.clear, range: range)
            if isInteriorPipe(at: pipe, in: text) {
                storage.addAttribute(.inkstoneTableSeparator, value: true, range: range)
            }
        }

        guard rows.count > 1 else { return }

        let alignments = columnAlignments(in: tableRange, text: text)
        let columnCount = rows.map(\.count).max() ?? 0
        var widths = [CGFloat](repeating: 0, count: columnCount)
        // Measure once and keep it; the second pass used to re-measure every cell.
        var measured: [[CGFloat]] = rows.map { row in row.map { width(of: $0) } }
        for (rowIndex, row) in rows.enumerated() {
            for column in row.indices {
                widths[column] = max(widths[column], measured[rowIndex][column])
            }
        }
        // A gutter, because the pipes that used to separate the columns are now
        // invisible and the source's single spaces either side of them are not
        // enough to read as a column break.
        for column in widths.indices { widths[column] += Self.tableCellPadding }

        // Aligning columns makes every row as wide as the widest cell in each
        // column, which can push a table past the measure it has to fit in.
        let available = availableWidth - Self.tableCellPadding * 2 - Self.copyButtonClearance
        if widths.reduce(0, +) > available {
            for column in widths.indices { widths[column] -= Self.tableCellPadding }
        }

        // When no arrangement can fit, stop aligning.
        //
        // The test is the widest row's *natural* width — what it takes with no
        // padding at all. If even that is over the measure, columns cannot line
        // up however the padding is distributed, and adding it only eats the
        // width the row needs and forces more wrapping. That is the common case
        // on a phone, where the measure is about half the desktop's: a table of
        // four columns of prose has no fitting arrangement at 370pt, and padded
        // it wrapped into three lines a row.
        //
        // An earlier attempt tested the *aligned* width instead and was reverted
        // as worse. It fired on tables that merely needed one wrapped row —
        // 700pt, where the natural rows fit and only the padded ones did not —
        // and collapsed their columns into a run of words. Testing the natural
        // width tells the two situations apart.
        let widestNaturalRow = measured.map { $0.reduce(0, +) }.max() ?? 0
        guard widestNaturalRow <= available else {
            // Unaligned, but not unstructured: a fixed gap at every boundary so
            // the cells are visibly separate. A constant, unlike the alignment
            // padding, so it cannot grow a row by the width of the widest cell in
            // every column — which is what forced every row to wrap.
            for row in rows.dropLast(0) {
                for cell in row.dropLast() where cell.length > 0 {
                    let last = NSRange(location: NSMaxRange(cell) - 1, length: 1)
                    storage.addAttribute(.kern, value: Self.tableCellPadding, range: last)
                }
            }
            return
        }

        // Where a column's spare width goes, which is all that column alignment
        // is: kerning applies *after* a glyph, so padding placed on the previous
        // cell's last character pushes this one right.
        for (rowIndex, row) in rows.enumerated() {
            for (column, cell) in row.enumerated() {
                let deficit = widths[column] - measured[rowIndex][column]
                // Sub-point deficits are invisible and only add attribute churn.
                guard deficit > 0.5, cell.length > 0 else { continue }
                let alignment = column < alignments.count ? alignments[column] : .left
                let (before, after) = alignment.split(deficit)

                if after > 0.5 {
                    let last = NSRange(location: NSMaxRange(cell) - 1, length: 1)
                    storage.addAttribute(.kern, value: after, range: last)
                }
                // The padding that goes *before* a cell has to be hung on the
                // character before it — the concealed pipe — because there is
                // nothing else between the two cells to carry it.
                if before > 0.5, cell.location > tableRange.location {
                    let separator = NSRange(location: cell.location - 1, length: 1)
                    let existing = (storage.attribute(.kern, at: separator.location, effectiveRange: nil)
                        as? CGFloat) ?? 0
                    storage.addAttribute(.kern, value: existing + before, range: separator)
                }
            }
        }
    }

    /// Whether a pipe separates two cells rather than closing the row.
    ///
    /// GFM makes the outer pipes optional, so this is decided by what is on
    /// either side rather than by counting: a boundary has text both ways, an
    /// outer pipe has the row's edge on one of them.
    private func isInteriorPipe(at location: Int, in text: NSString) -> Bool {
        let line = text.lineRange(for: NSRange(location: location, length: 0))
        func hasInk(_ range: NSRange) -> Bool {
            guard range.length > 0 else { return false }
            return !text.substring(with: range)
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        let before = NSRange(location: line.location, length: location - line.location)
        let after = NSRange(location: location + 1, length: max(0, NSMaxRange(line) - location - 1))
        return hasInk(before) && hasInk(after)
    }

    /// Which way a column's contents sit in it, from the `|:--:|` row.
    enum ColumnAlignment {
        case left, centre, right

        /// Splits a cell's spare width into what goes before it and after it.
        func split(_ deficit: CGFloat) -> (before: CGFloat, after: CGFloat) {
            switch self {
            case .left: return (0, deficit)
            case .right: return (deficit, 0)
            case .centre: return (deficit / 2, deficit / 2)
            }
        }
    }

    /// Reads `|:---|:---:|---:|` — the row cmark consumes and reports nowhere.
    ///
    /// Parsed from the delimiter row's own token range rather than re-detecting
    /// anything: the parser found the table and marked which line this is, and
    /// this reads a value out of the line it identified. cmark does hold the
    /// alignments on its `Table` node, but putting them on `TokenKind.table`
    /// would make every table a difference in the engine diff harness — the
    /// legacy scanner has no alignments to report — and that harness is worth
    /// more than avoiding this.
    private func columnAlignments(in tableRange: NSRange, text: NSString) -> [ColumnAlignment] {
        var location = tableRange.location
        while location < NSMaxRange(tableRange) {
            let line = text.lineRange(for: NSRange(location: location, length: 0))
            defer { location = max(NSMaxRange(line), location + 1) }
            let trimmed = text.substring(with: line).trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.contains("-"), trimmed.allSatisfy({ "|-: \t".contains($0) }) else { continue }

            return trimmed
                .split(separator: "|", omittingEmptySubsequences: true)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { $0.contains("-") }
                .map { spec in
                    switch (spec.hasPrefix(":"), spec.hasSuffix(":")) {
                    case (true, true): return .centre
                    case (false, true): return .right
                    default: return .left
                    }
                }
        }
        return []
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

    /// The properties table standing in for a note's YAML frontmatter.
    static let inkstoneProperties = NSAttributedString.Key("inkstoneProperties")
    /// Marks a callout header so its disclosure can be drawn and clicked.
    /// Value is a Bool: whether the callout is currently folded.
    static let inkstoneCalloutFold = NSAttributedString.Key("inkstoneCalloutFold")

    /// Marks a concealed pipe that separates two cells, so a rule can be drawn
    /// where it was. Value is a Bool.
    static let inkstoneTableSeparator = NSAttributedString.Key("inkstoneTableSeparator")

    /// Marks a concealed list marker so a bullet can be drawn in its place.
    static let inkstoneBullet = NSAttributedString.Key("inkstoneBullet")
    /// Marks a quoted line so its left rule can be drawn.
    static let inkstoneQuoteDepth = NSAttributedString.Key("inkstoneQuoteDepth")
    /// Marks a concealed task marker so a checkbox can be drawn there.
    ///
    /// Value is the state *character* — `" "`, `"x"`, `"/"`, `"-"`, `">"` — not a
    /// Bool. Obsidian allows any single character and the box has to show which
    /// one it is; a Bool could only say "not blank", which drew everything from
    /// "in progress" to "cancelled" as finished.
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

    /// Marks a block that carries `.inkstoneBlockFill` as a *table*, so the
    /// renderer draws a grid rather than a code panel. Both are set: the copy
    /// button and its hit test key off the fill, and only the presentation
    /// differs.
    static let inkstoneTableBlock = NSAttributedString.Key("inkstoneTableBlock")
    /// A typeset formula to be drawn within a line of prose. Value is an image.
    static let inkstoneInlineMath = NSAttributedString.Key("inkstoneInlineMath")

    /// A picture small enough to sit among words, for an embed that shares its
    /// line with other text. Value is an image, already scaled.
    static let inkstoneInlineThumbnail = NSAttributedString.Key("inkstoneInlineThumbnail")

    /// Text to draw in place of concealed source — the `©` an `&copy;` stands
    /// for. Value is the replacement string.
    static let inkstoneInlineText = NSAttributedString.Key("inkstoneInlineText")
    /// Attached to a footnote marker so clicking it can jump to its definition.
    static let inkstoneFootnote = NSAttributedString.Key("inkstoneFootnote")
    /// Whether a block image is centred. Value is a Bool.
    static let inkstoneImageCentred = NSAttributedString.Key("inkstoneImageCentred")
    /// Marks an h1/h2 so a rule can be drawn beneath it. Value is the level.
    static let inkstoneHeadingRule = NSAttributedString.Key("inkstoneHeadingRule")
}
