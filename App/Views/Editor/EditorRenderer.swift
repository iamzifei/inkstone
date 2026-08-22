import Foundation

#if os(macOS)
import AppKit
#else
import UIKit
#endif

import InkstoneCore

/// Paints everything in the editor that is not text.
///
/// Bullets, checkboxes, quote rules, heading rules, inline fills, inline images
/// and typeset formulas are all drawn by hand into space the highlighter
/// reserved, rather than inserted into the text — the buffer always holds
/// exactly what is on disk.
///
/// Deliberately knows nothing about the view it draws into. `NSLayoutManager`
/// and `NSTextContainer` exist on both platforms, so the geometry is identical;
/// separating it from `NSTextView` is what lets iOS draw the same things instead
/// of silently dropping them. Before this, a task on iOS rendered as its text
/// with no checkbox at all.
@MainActor
struct EditorRenderer {
    let storage: NSTextStorage
    let layoutManager: NSLayoutManager
    let container: NSTextContainer
    /// Where the text container starts inside the view.
    let origin: CGPoint
    let style: Style

    /// The copy button the pointer is over, if any. A control with no hover
    /// state reads as decoration: there was nothing to tell you the corner of a
    /// code block could be clicked at all.
    var hoveredCopyBlock: NSRange?
    /// The block whose copy button was just pressed. Drawn as a tick for a
    /// moment afterwards, because a copy that gives no acknowledgement leaves
    /// you wondering whether it happened.
    var copiedCopyBlock: NSRange?

    /// Draws every hand-painted element that intersects `rect`.
    ///
    /// Order matters where things overlap: fills sit behind their text, rules
    /// behind glyphs, and the checkbox after the bullet so a task in a bulleted
    /// list is not drawn twice.
    func draw(in rect: CGRect) {
        drawBlockFills(in: rect)
        drawHorizontalRules(in: rect)
        drawInlineImages(in: rect)
        drawInlineFills(in: rect)
        drawBullets(in: rect)
        drawQuoteRules(in: rect)
        drawCheckboxes(in: rect)
        drawHeadingRules(in: rect)
        drawInlineMath(in: rect)
        drawCalloutDisclosures(in: rect)
    }

    /// Where a callout's disclosure triangle is drawn, and where a click on it
    /// counts. Shared, so the two can never disagree.
    func calloutDisclosureRect(for range: NSRange) -> CGRect? {
        let glyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        guard glyphRange.location < layoutManager.numberOfGlyphs else { return nil }
        let fragment = layoutManager.lineFragmentRect(forGlyphAt: glyphRange.location, effectiveRange: nil)
            .offsetBy(dx: origin.x, dy: origin.y)
        let side: CGFloat = 12
        // In the gutter the quote rule already reserves, so it takes no width
        // from the title.
        return CGRect(
            x: origin.x + 4,
            y: fragment.midY - side / 2,
            width: side,
            height: side
        )
    }

    /// A chevron on a callout header: down when open, right when folded.
    private func drawCalloutDisclosures(in rect: CGRect) {
        storage.enumerateAttribute(
            .inkstoneCalloutFold,
            in: NSRange(location: 0, length: storage.length)
        ) { value, range, _ in
            guard let folded = value as? Bool,
                  let box = calloutDisclosureRect(for: range), box.intersects(rect)
            else { return }

            let path = PlatformBezierPath()
            let inset: CGFloat = 3
            if folded {
                path.move(to: CGPoint(x: box.minX + inset + 1, y: box.minY + inset - 1))
                path.addLine(to: CGPoint(x: box.maxX - inset - 1, y: box.midY))
                path.addLine(to: CGPoint(x: box.minX + inset + 1, y: box.maxY - inset + 1))
            } else {
                path.move(to: CGPoint(x: box.minX + inset - 1, y: box.minY + inset + 1))
                path.addLine(to: CGPoint(x: box.midX, y: box.maxY - inset - 1))
                path.addLine(to: CGPoint(x: box.maxX - inset + 1, y: box.minY + inset + 1))
            }
            path.lineWidth = 1.6
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            style.palette.faintText.platformColor.setStroke()
            path.stroke()
        }
    }

    /// The callout header whose disclosure is under `point`.
    func calloutDisclosureHit(at point: CGPoint) -> NSRange? {
        var hit: NSRange?
        storage.enumerateAttribute(
            .inkstoneCalloutFold,
            in: NSRange(location: 0, length: storage.length)
        ) { value, range, stop in
            guard value != nil, let box = calloutDisclosureRect(for: range) else { return }
            // Grown for touch, as the checkbox and the copy button are.
            let target = box.insetBy(dx: -(44 - box.width) / 2, dy: -(44 - box.height) / 2)
            if target.contains(point) {
                hit = range
                stop.pointee = true
            }
        }
        return hit
    }


    /// Paints one continuous panel behind a code fence or a table.
    ///
    /// `.backgroundColor` fills per glyph run, so a blank line inside a fence —
    /// which has no glyphs — got no fill, and neither did the space between
    /// paragraphs. A fenced block of prose came out as a stack of separate grey
    /// stripes instead of one panel, which is not what any Markdown renderer
    /// shows.
    func drawBlockFills(in rect: CGRect) {
        storage.enumerateAttribute(
            .inkstoneBlockFill,
            in: NSRange(location: 0, length: storage.length)
        ) { value, range, _ in
            guard value != nil else { return }
            // The union of the block's line fragments, which covers the blank
            // lines and the leading between them; the bounding rect of the
            // glyphs alone would not.
            guard let panel = blockPanel(for: range), panel.intersects(rect) else { return }

            if storage.attribute(.inkstoneTableBlock, at: range.location, effectiveRange: nil) != nil {
                drawTableChrome(for: range, panel: panel)
            } else {
                // Same ink-based geometry as a table. Drawn from the line
                // fragments, the panel inherited the block's outer margin at the
                // top and almost nothing at the bottom, so the first line of code
                // sat further from the edge than the last.
                let inked = blockInkPanel(for: range, outer: panel, padding: Self.blockPadding)
                    ?? panel
                style.palette.codeBackground.platformColor.setFill()
                PlatformBezierPath(roundedRect: inked, cornerRadius: 6).fill()
            }
            drawCopyButton(for: range)
        }
    }

    /// Where a table's rows and its panel actually are.
    ///
    /// Two earlier attempts got this wrong by using a rect that looked like the
    /// right one. The line *fragment* carries the block's outer margin — 9.6pt of
    /// it — inside the first and last rows. The *used* rect drops that margin but
    /// is still the line box, and with an explicit `maximumLineHeight` TextKit
    /// puts all the extra leading above the text and sits the glyphs on the
    /// bottom edge: measured on screen, 18px of empty band above the header text
    /// and 5px below it.
    ///
    /// So the geometry is built from the baseline and the font's own ascender and
    /// descender, which is the only pair of numbers that says where the glyphs
    /// are. Shared with `copyButtonRect` so the button sits in the corner of the
    /// border that is actually drawn, rather than the one the fragments imply.
    struct TableRow { let top: CGFloat; let bottom: CGFloat }

    /// Breathing room between a code block's text and its panel.
    static let blockPadding: CGFloat = 10

    /// The ink box of every visible line in a block, one entry per *source* line.
    ///
    /// Shared by tables and code blocks, and the reason both are drawn from it is
    /// the same: a line fragment carries the block's outer margin in its first
    /// and last rows, and the used rect is the line box with all its leading
    /// above the glyphs. Neither says where the text is.
    func blockRows(for range: NSRange) -> [TableRow] {
        let glyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        var rows: [TableRow] = []
        // The source line each row belongs to. A row wider than the measure wraps
        // onto a second line fragment, and drawing a separator between the two
        // halves would cut a single row in two.
        var lastSourceLine = NSRange(location: NSNotFound, length: 0)
        let source = storage.string as NSString

        layoutManager.enumerateLineFragments(
            forGlyphRange: glyphRange
        ) { fragment, used, _, lineGlyphs, _ in
            guard used.height >= 1 else { return }
            let characters = self.layoutManager.characterRange(
                forGlyphRange: lineGlyphs, actualGlyphRange: nil
            )
            // Measured at the first *visible* character: a row starts with a
            // concealed `|` collapsed to 0.01pt, whose metrics say nothing.
            var probe = characters.location
            var font: PlatformFont?
            while probe < NSMaxRange(characters) {
                if let candidate = self.storage.attribute(.font, at: probe, effectiveRange: nil)
                    as? PlatformFont, candidate.pointSize >= 1 {
                    font = candidate
                    break
                }
                probe += 1
            }
            guard let font else { return }

            let glyph = self.layoutManager.glyphIndexForCharacter(at: probe)
            guard glyph < self.layoutManager.numberOfGlyphs else { return }
            let baseline = fragment.minY + self.layoutManager.location(forGlyphAt: glyph).y + self.origin.y
            let top = baseline - font.ascender
            let bottom = baseline - font.descender

            let sourceLine = source.lineRange(for: NSRange(location: characters.location, length: 0))
            if NSEqualRanges(sourceLine, lastSourceLine), let previous = rows.last {
                // A continuation of the row above: extend it rather than start one.
                rows[rows.count - 1] = TableRow(top: previous.top, bottom: bottom)
            } else {
                rows.append(TableRow(top: top, bottom: bottom))
                lastSourceLine = sourceLine
            }
        }
        return rows
    }

    /// A panel that sits evenly around a block's text.
    func blockInkPanel(for range: NSRange, outer: CGRect, padding: CGFloat) -> CGRect? {
        let rows = blockRows(for: range)
        guard let first = rows.first, let last = rows.last else { return nil }
        let panel = CGRect(
            x: outer.minX,
            y: first.top - padding,
            width: outer.width,
            height: (last.bottom + padding) - (first.top - padding)
        )
        return panel.height > 0 ? panel : nil
    }

    func tableGeometry(
        for range: NSRange, outer: CGRect
    ) -> (panel: CGRect, rows: [TableRow], halfGap: CGFloat)? {
        let rows = blockRows(for: range)
        guard let header = rows.first, let last = rows.last else { return nil }

        // Half the gap between one row's ink and the next's: the padding that
        // makes every row's text sit centred between its separators. Applied on
        // every edge with nothing added on top of it — an earlier version added
        // 4pt at the panel's top only, which put 4pt more space above the header
        // text than below it, measured as 23px against 15px on screen.
        let halfGap: CGFloat = rows.count > 1
            ? max(1, (rows[1].top - rows[0].bottom) / 2)
            : 4
        let panel = CGRect(
            x: outer.minX,
            y: header.top - halfGap,
            width: outer.width,
            height: (last.bottom + halfGap) - (header.top - halfGap)
        )
        guard panel.height > 0 else { return nil }
        return (panel, rows, halfGap)
    }

    /// Draws a table as a grid rather than as a shaded panel.
    ///
    /// The text is still the source text — the cells are ordinary runs whose
    /// columns are positioned by kerning, and the `|` characters are concealed
    /// rather than removed. What was missing was everything that makes a reader
    /// see a table instead of a listing: a header band, a rule under it,
    /// hairlines between the rows, and a border round the whole thing.
    ///
    /// Geometry comes from the **used** rects, not the line fragments. A block's
    /// outer margin lives inside the first and last fragments of that block —
    /// measured at 9.6pt on each — so bands drawn from fragments put that margin
    /// inside the header's tint and pushed the separator hard against the header
    /// text, which is exactly what "the text and the background do not line up"
    /// looked like. The used rect is the glyphs' own box and has no margin in it.
    private func drawTableChrome(for range: NSRange, panel outer: CGRect) {
        guard let geometry = tableGeometry(for: range, outer: outer) else { return }
        let panel = geometry.panel
        let rows = geometry.rows
        let halfGap = geometry.halfGap
        guard let header = rows.first else { return }

        // The header band, tinted rather than ruled off on its own: it is the one
        // row a reader looks for first. Clipped to the panel's rounded rectangle
        // so its top corners follow the border instead of poking through it —
        // neither `NSBezierPath` nor the shared wrapper has a per-corner radius.
        let headerBottom = rows.count > 1 ? (header.bottom + halfGap) : panel.maxY
        if let context = currentDrawingContext {
            context.saveGState()
            PlatformBezierPath(roundedRect: panel, cornerRadius: 6).addClip()
            style.palette.codeBackground.platformColor.setFill()
            CGRect(x: panel.minX, y: panel.minY, width: panel.width, height: headerBottom - panel.minY)
                .fillPlatform()
            context.restoreGState()
        }

        style.palette.divider.platformColor.setFill()
        // A hairline midway between each pair of rows, header included.
        for index in 0..<max(0, rows.count - 1) {
            let y = (rows[index].bottom + rows[index + 1].top) / 2
            CGRect(x: panel.minX, y: y - 0.5, width: panel.width, height: 1).fillPlatform()
        }

        drawColumnSeparators(for: range, panel: panel, rows: rows)

        style.palette.divider.platformColor.setStroke()
        let border = PlatformBezierPath(roundedRect: panel.insetBy(dx: 0.5, dy: 0.5), cornerRadius: 6)
        border.lineWidth = 1
        border.stroke()
    }

    /// A hairline where each concealed cell-separating pipe was.
    ///
    /// Without these, a table whose columns cannot be aligned — which is what
    /// happens whenever its content is wider than the measure, and so most of the
    /// time on a phone — has no visible cell boundaries at all: its header reads
    /// as a run of words rather than as column names. Drawn at the pipe's own
    /// position, so they mark the boundary whether the columns line up or not.
    private func drawColumnSeparators(for range: NSRange, panel: CGRect, rows: [TableRow]) {
        style.palette.divider.platformColor.setFill()
        storage.enumerateAttribute(.inkstoneTableSeparator, in: range) { value, pipe, _ in
            guard value != nil else { return }
            let glyphRange = layoutManager.glyphRange(forCharacterRange: pipe, actualCharacterRange: nil)
            guard glyphRange.location < layoutManager.numberOfGlyphs else { return }
            // The glyph's own box, the same way the checkbox hit test finds one.
            // Computing an x from the fragment plus the glyph's offset was tried
            // and put the rules above the table: the fragment had already been
            // moved into view coordinates and the offset added the origin again.
            let box = layoutManager.boundingRect(forGlyphRange: glyphRange, in: container)
                .offsetBy(dx: origin.x, dy: origin.y)
            let x = box.minX
            guard x > panel.minX + 2, x < panel.maxX - 2 else { return }

            // The row gives the vertical extent, the pipe's own line fragment
            // clips it. The row alone would run a rule from a wrapped line's
            // boundary straight up through the line above it, where that
            // boundary is somewhere else entirely; the fragment alone would
            // include the block's outer margin on the first and last rows.
            guard let row = rows.first(where: { box.midY >= $0.top - 2 && box.midY <= $0.bottom + 2 })
            else { return }
            let fragment = layoutManager
                .lineFragmentRect(forGlyphAt: glyphRange.location, effectiveRange: nil)
                .offsetBy(dx: origin.x, dy: origin.y)
            let top = max(row.top, fragment.minY)
            let bottom = min(row.bottom, fragment.maxY)
            guard bottom > top else { return }
            CGRect(x: x.rounded() - 0.5, y: top, width: 1, height: bottom - top).fillPlatform()
        }
    }

    /// Paints inline attachment images into the space the highlighter reserved.
    ///
    /// See `MarkdownHighlighter.inlineImage` for why this is drawn by hand
    /// rather than using a text attachment. This lived in the AppKit text view
    /// until the rest of the drawing moved out, which left iOS silently painting
    /// nothing for every embedded image and every rendered Mermaid diagram: the
    /// source was concealed and its replacement never arrived.
    func drawInlineImages(in rect: CGRect) {
        storage.enumerateAttribute(
            .inkstoneInlineImage,
            in: NSRange(location: 0, length: storage.length)
        ) { value, range, _ in
            guard let image = value as? PlatformImage else { return }
            let glyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            let lineRect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: container)
                .offsetBy(dx: origin.x, dy: origin.y)
            guard lineRect.intersects(rect) else { return }

            let size = image.size
            // The paragraph is centred, but the glyphs it contains are collapsed
            // to nothing, so the line rect carries no useful x. Centre against
            // the text container instead.
            let centred = (storage.attribute(.inkstoneImageCentred, at: range.location, effectiveRange: nil)
                as? Bool) ?? true
            let available = container.size.width - container.lineFragmentPadding * 2
            let x = centred ? origin.x + max(0, (available - size.width) / 2) : origin.x
            let target = CGRect(
                x: x,
                y: lineRect.minY + MarkdownHighlighter.inlineImagePadding,
                width: size.width,
                height: size.height
            )

            // A text view uses flipped coordinates, so drawing an NSImage
            // straight into it lands the picture upside down. Flip the CTM about
            // the target rect and draw the CGImage into the corrected space.
            #if os(macOS)
            // A flipped text view draws a CGImage upside down, so the CTM is
            // flipped about the target rect first.
            guard let context = currentDrawingContext, let cgImage = image.platformCGImage
            else { return }
            context.saveGState()
            context.translateBy(x: 0, y: target.maxY)
            context.scaleBy(x: 1, y: -1)
            context.draw(
                cgImage,
                in: CGRect(x: target.minX, y: 0, width: target.width, height: target.height)
            )
            context.restoreGState()
            #else
            // UIKit's own draw already accounts for the orientation, and unlike
            // the CGImage path it works whatever backing the image has — a
            // WKWebView snapshot does not always carry a usable `cgImage`.
            image.draw(in: target)
            #endif
        }
    }

    /// Draws a thematic break across the text width.
    func drawHorizontalRules(in rect: CGRect) {
        style.palette.divider.platformColor.setFill()
        let width = container.size.width - container.lineFragmentPadding * 2

        storage.enumerateAttribute(
            .inkstoneHorizontalRule,
            in: NSRange(location: 0, length: storage.length)
        ) { value, range, _ in
            guard value != nil else { return }
            let glyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            guard glyphRange.location < layoutManager.numberOfGlyphs else { return }
            let box = layoutManager.lineFragmentRect(forGlyphAt: glyphRange.location, effectiveRange: nil)
                .offsetBy(dx: origin.x, dy: origin.y)
            guard box.intersects(rect) else { return }

            CGRect(x: origin.x, y: box.midY, width: width, height: 1).fillPlatform()
        }
    }

    /// Where the copy button for a code block is drawn, in the panel's corner.
    func copyButtonRect(for range: NSRange) -> CGRect? {
        guard var panel = blockPanel(for: range) else { return nil }
        // A table's border is drawn from its baselines, not from the line
        // fragments, so the button has to be placed against the same rectangle or
        // it floats outside the corner it is meant to sit in — and, because this
        // is also the hit test, becomes unclickable where it appears.
        if storage.length > range.location {
            if storage.attribute(.inkstoneTableBlock, at: range.location, effectiveRange: nil) != nil {
                if let geometry = tableGeometry(for: range, outer: panel) { panel = geometry.panel }
            } else if let inked = blockInkPanel(for: range, outer: panel, padding: Self.blockPadding) {
                panel = inked
            }
        }
        let side: CGFloat = 22
        let inset: CGFloat = 8
        return CGRect(
            x: panel.maxX - side - inset,
            y: panel.minY + inset,
            width: side,
            height: side
        )
    }

    /// The block whose copy button was tapped at `point`, with the range of its
    /// contents, if any.
    func copyButtonHit(at point: CGPoint) -> NSRange? {
        var hit: NSRange?
        storage.enumerateAttribute(
            .inkstoneBlockFill,
            in: NSRange(location: 0, length: storage.length)
        ) { value, range, stop in
            guard value != nil, let button = copyButtonRect(for: range) else { return }
            // Grown for touch, as with checkboxes: 22pt is a comfortable glyph
            // and an uncomfortable target.
            let target = button.insetBy(dx: -(44 - button.width) / 2, dy: -(44 - button.height) / 2)
            if target.contains(point) {
                hit = range
                stop.pointee = true
            }
        }
        return hit
    }

    /// The panel a block is painted into: the union of its line fragments.
    private func blockPanel(for range: NSRange) -> CGRect? {
        let glyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        guard glyphRange.location < layoutManager.numberOfGlyphs else { return nil }

        var panel = CGRect.null
        layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) { fragment, _, _, _, _ in
            panel = panel.isNull ? fragment : panel.union(fragment)
        }
        guard !panel.isNull else { return nil }

        panel = panel.offsetBy(dx: origin.x, dy: origin.y)
        panel.origin.x = origin.x
        panel.size.width = container.size.width - container.lineFragmentPadding * 2
        return panel
    }

    /// A copy affordance in the corner of a code block or table.
    private func drawCopyButton(for range: NSRange) {
        guard let button = copyButtonRect(for: range) else { return }

        let isCopied = copiedCopyBlock.map { NSEqualRanges($0, range) } ?? false
        let isHovered = hoveredCopyBlock.map { NSEqualRanges($0, range) } ?? false

        // Three states, because a button that looks identical whatever you do to
        // it is indistinguishable from an icon.
        let colour = isCopied
            ? style.palette.accent.platformColor
            : (isHovered ? style.palette.text.platformColor : style.palette.faintText.platformColor)

        // A solid ground first: the first line is kept clear of the button, but
        // a wrapped line or a wide table can still reach under it.
        if isHovered || isCopied {
            style.palette.divider.platformColor.setFill()
        } else {
            style.palette.codeBackground.platformColor.setFill()
        }
        PlatformBezierPath(roundedRect: button, cornerRadius: 5).fill()

        if isCopied {
            // A tick, drawn rather than set from a font so it matches the mark it
            // replaces at any text size.
            let path = PlatformBezierPath()
            path.move(to: CGPoint(x: button.minX + 5, y: button.midY))
            path.addLine(to: CGPoint(x: button.minX + 9, y: button.midY + 4.5))
            path.addLine(to: CGPoint(x: button.maxX - 5, y: button.midY - 5))
            path.lineWidth = 2
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            colour.setStroke()
            path.stroke()
            return
        }

        // Two offset rounded rectangles: the universal "copy" mark, drawn rather
        // than set from a font so it matches the panel at any text size.
        colour.setStroke()
        let back = CGRect(x: button.minX + 5, y: button.minY + 2, width: 11, height: 13)
        let front = CGRect(x: button.minX + 2, y: button.minY + 6, width: 11, height: 13)

        let backPath = PlatformBezierPath(roundedRect: back, cornerRadius: 2)
        backPath.lineWidth = 1.2
        backPath.stroke()

        // Punch the ground through behind the front sheet so the two read as
        // overlapping rather than as a grid.
        if isHovered {
            style.palette.divider.platformColor.setFill()
        } else {
            style.palette.codeBackground.platformColor.setFill()
        }
        PlatformBezierPath(roundedRect: front.insetBy(dx: -1, dy: -1), cornerRadius: 3).fill()

        colour.setStroke()
        let frontPath = PlatformBezierPath(roundedRect: front, cornerRadius: 2)
        frontPath.lineWidth = 1.2
        frontPath.stroke()
    }


    /// Draws inline formulas into the space their kerning reserved.
    ///
    /// Sat on the baseline rather than centred in the line box: an inline formula
    /// has to sit on the same line as the words around it, and a line box with a
    /// line-height multiple is much taller than the text.
    func drawInlineMath(in rect: CGRect) {
        // Two keys, one behaviour: a typeset formula and a thumbnail of an
        // embedded picture both have to sit on the baseline among the words.
        drawOnBaseline(.inkstoneInlineMath, in: rect)
        drawOnBaseline(.inkstoneInlineThumbnail, in: rect)
        drawInlineText(in: rect)
    }

    /// Draws the character an entity stands for, where its source was concealed.
    private func drawInlineText(in rect: CGRect) {
        storage.enumerateAttribute(
            .inkstoneInlineText,
            in: NSRange(location: 0, length: storage.length)
        ) { value, range, _ in
            guard let replacement = value as? String else { return }
            let glyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            let box = layoutManager.boundingRect(forGlyphRange: glyphRange, in: container)
                .offsetBy(dx: origin.x, dy: origin.y)
            guard box.intersects(rect) else { return }

            let baseline = box.minY + layoutManager.location(forGlyphAt: glyphRange.location).y
            // The face of the text it replaces, so an entity in a heading is
            // drawn at heading size rather than at body size.
            var font = style.typography.editorFont.platformFont(size: style.typography.editorFontSize)
            let after = min(NSMaxRange(range), storage.length - 1)
            if after >= 0, after < storage.length,
               let neighbour = storage.attribute(.font, at: after, effectiveRange: nil) as? PlatformFont,
               neighbour.pointSize >= 1 {
                font = neighbour
            }
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: (storage.attribute(.foregroundColor, at: after, effectiveRange: nil)
                    as? PlatformColor) ?? style.palette.text.platformColor,
            ]
            (replacement as NSString).draw(
                at: CGPoint(x: box.minX, y: baseline - font.ascender),
                withAttributes: attributes
            )
        }
    }

    private func drawOnBaseline(_ key: NSAttributedString.Key, in rect: CGRect) {
        storage.enumerateAttribute(
            key,
            in: NSRange(location: 0, length: storage.length)
        ) { value, range, _ in
            guard let image = value as? PlatformImage else { return }
            let glyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            let box = layoutManager.boundingRect(forGlyphRange: glyphRange, in: container)
                .offsetBy(dx: origin.x, dy: origin.y)
            guard box.intersects(rect) else { return }

            let baseline = box.minY + layoutManager.location(forGlyphAt: glyphRange.location).y
            let size = image.size
            // Roughly centre the formula on the x-height, which is where a
            // reader expects an inline expression to sit.
            let target = CGRect(
                x: box.minX,
                y: baseline - size.height * 0.72,
                width: size.width,
                height: size.height
            )

            guard let context = currentDrawingContext, let cgImage = image.platformCGImage
            else { return }
            context.saveGState()
            context.translateBy(x: 0, y: target.maxY)
            context.scaleBy(x: 1, y: -1)
            context.draw(cgImage, in: CGRect(x: target.minX, y: 0, width: target.width, height: target.height))
            context.restoreGState()
        }
    }

    /// Rules off h1 and h2, the way Typora's default theme does.
    func drawHeadingRules(in rect: CGRect) {
        let colour = style.palette.divider.platformColor
        let width = container.size.width - container.lineFragmentPadding * 2

        storage.enumerateAttribute(
            .inkstoneHeadingRule,
            in: NSRange(location: 0, length: storage.length)
        ) { value, range, _ in
            guard value != nil else { return }
            let glyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            let box = layoutManager.boundingRect(forGlyphRange: glyphRange, in: container)
                .offsetBy(dx: origin.x, dy: origin.y)
            guard box.intersects(rect) else { return }

            colour.setFill()
            // Below the line box, not inside it.
            //
            // `box.maxY - 1` looked right only because it was checked against
            // Latin headings, whose lowercase letters stop well short of the
            // descender line. A heading's line box is barely taller than its
            // glyphs — 45.0 against 42.4 — so the rule was landing at 44.0 with
            // the text reaching 44.6: on top of the letters, which Chinese
            // headings show immediately since their glyphs fill the em box.
            //
            // The room is in the paragraph's trailing space, which is what a
            // heading's margin is for. Scaled by the heading's own size so an h1
            // is not given an h6's gap.
            let padding = (headingFont(at: range)?.pointSize ?? 16) * 0.22
            CGRect(x: origin.x, y: box.maxY + padding, width: width, height: 1).fillPlatform()
        }
    }

    /// The font of the heading's own text, skipping the collapsed `#` marker
    /// whose 0.01pt size describes nothing on screen.
    private func headingFont(at range: NSRange) -> PlatformFont? {
        let text = storage.string as NSString
        let line = text.lineRange(for: NSRange(location: range.location, length: 0))
        var probe = line.location
        while probe < NSMaxRange(line), probe < storage.length {
            if let font = storage.attribute(.font, at: probe, effectiveRange: nil) as? PlatformFont,
               font.pointSize >= 1 {
                return font
            }
            probe += 1
        }
        return nil
    }

    /// Paints rounded fills behind inline code and attachment chips.
    ///
    /// `NSAttributedString.backgroundColor` fills the entire line fragment, which
    /// at a 1.75 line-height multiple is roughly twice the height of the glyphs —
    /// the tint ends up looming above the text instead of hugging it. Drawing it
    /// here allows a box sized to the font and rounded like a chip.
    func drawInlineFills(in rect: CGRect) {
        storage.enumerateAttribute(
            .inkstoneInlineFill,
            in: NSRange(location: 0, length: storage.length)
        ) { value, range, _ in
            guard let colour = value as? PlatformColor, range.length > 0 else { return }
            let font = storage.attribute(.font, at: range.location, effectiveRange: nil) as? PlatformFont
            let glyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)

            // A run can wrap, so each line fragment gets its own chip.
            layoutManager.enumerateEnclosingRects(
                forGlyphRange: glyphRange,
                withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                in: container
            ) { fragment, _ in
                let box = fragment.offsetBy(dx: origin.x, dy: origin.y)
                guard box.intersects(rect) else { return }

                // Positioned from the baseline, not the fragment's centre: with a
                // line-height multiple the fragment is far taller than the text
                // and sits above it, so centring on it floats the chip clear of
                // the words.
                let ascender = font?.ascender ?? 12
                let descender = font?.descender ?? -3
                let baseline = box.minY + layoutManager.location(forGlyphAt: glyphRange.location).y
                let chip = CGRect(
                    x: box.minX - 3,
                    y: baseline - ascender - 2,
                    width: box.width + 6,
                    height: (ascender - descender) + 4
                )
                colour.setFill()
                PlatformBezierPath(roundedRect: chip, cornerRadius: 4).fill()
            }
        }
    }

    /// Draws a checkbox where a `- [ ]` marker was concealed.
    ///
    /// Same reasoning as the bullets: the brackets cannot be swapped for a real
    /// checkbox glyph without editing the note, so the marker is hidden and the
    /// box is painted into the space it left.
    /// How a task's state character is drawn, and whether its text reads as done.
    ///
    /// GFM has two states; Obsidian lets any single character sit between the
    /// brackets and communities have settled on a handful of meanings. Every
    /// non-blank state used to render as a ticked box with the text struck
    /// through, so "in progress" and "cancelled" and "deferred" were all
    /// indistinguishable from "finished" — the one thing a task list exists to
    /// tell you apart.
    enum TaskState {
        case open
        case done
        case cancelled
        /// Any other character Obsidian allows: drawn as itself inside the box,
        /// which is honest about carrying a state we have no icon for.
        case other(String)

        init(_ marker: String) {
            switch marker {
            case " ", "": self = .open
            case "x", "X", "✓", "✔": self = .done
            case "-", "~": self = .cancelled
            default: self = .other(marker)
            }
        }

        /// Whether the item's text should read as finished with.
        var isFinished: Bool {
            switch self {
            case .done, .cancelled: return true
            case .open, .other: return false
            }
        }
    }

    func drawCheckboxes(in rect: CGRect) {
        storage.enumerateAttribute(
            .inkstoneCheckbox,
            in: NSRange(location: 0, length: storage.length)
        ) { value, range, _ in
            // A `String` now, not a `Bool`: the box has to show *which* state.
            guard let marker = value as? String else { return }
            let state = TaskState(marker)
            let glyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            let markerRect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: container)
                .offsetBy(dx: origin.x, dy: origin.y)
            guard markerRect.intersects(rect) else { return }

            guard let box = checkboxBox(for: range) else { return }
            let side = box.width
            let path = PlatformBezierPath(roundedRect: box, cornerRadius: 3)

            switch state {
            case .open:
                style.palette.faintText.platformColor.setStroke()
                path.lineWidth = 1.2
                path.stroke()

            case .done:
                style.palette.accent.platformColor.setFill()
                path.fill()
                // A tick, drawn rather than set in a font so it scales with the box.
                let tick = PlatformBezierPath()
                tick.move(to: CGPoint(x: box.minX + side * 0.24, y: box.midY + side * 0.02))
                tick.addLine(to: CGPoint(x: box.minX + side * 0.43, y: box.maxY - side * 0.26))
                tick.addLine(to: CGPoint(x: box.maxX - side * 0.22, y: box.minY + side * 0.28))
                tick.lineWidth = 1.8
                tick.lineCapStyle = .round
                tick.lineJoinStyle = .round
                style.palette.background.platformColor.setStroke()
                tick.stroke()

            case .cancelled:
                // An outlined box with a bar through it: struck out, not ticked.
                style.palette.faintText.platformColor.setStroke()
                path.lineWidth = 1.2
                path.stroke()
                let bar = PlatformBezierPath()
                bar.move(to: CGPoint(x: box.minX + side * 0.24, y: box.midY))
                bar.addLine(to: CGPoint(x: box.maxX - side * 0.24, y: box.midY))
                bar.lineWidth = 1.8
                bar.lineCapStyle = .round
                style.palette.faintText.platformColor.setStroke()
                bar.stroke()

            case .other(let marker):
                style.palette.accent.platformColor.setStroke()
                path.lineWidth = 1.2
                path.stroke()
                // The character itself, centred. Sized to the box rather than to
                // the text so `/` and `>` and `?` all sit the same.
                let font = PlatformFont.systemFont(ofSize: side * 0.68, weight: .semibold)
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: font,
                    .foregroundColor: style.palette.accent.platformColor,
                ]
                let glyph = marker as NSString
                let size = glyph.size(withAttributes: attributes)
                glyph.draw(
                    at: CGPoint(x: box.midX - size.width / 2, y: box.midY - size.height / 2),
                    withAttributes: attributes
                )
            }
        }
    }

    /// Where the checkbox for a task marker is painted.
    ///
    /// Shared by the drawing and the hit test, so a tap can never land somewhere
    /// other than the box the user is looking at.
    func checkboxBox(for range: NSRange) -> CGRect? {
        let glyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        guard glyphRange.location < layoutManager.numberOfGlyphs else { return nil }
        let markerRect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: container)
            .offsetBy(dx: origin.x, dy: origin.y)

        // The font of the *task text*, not of the marker. The marker is
        // collapsed to 0.01pt, whose x-height is effectively zero — measuring it
        // put the box half a line below the words it belongs to.
        let textLocation = min(range.location + range.length, storage.length - 1)
        let font = storage.attribute(.font, at: max(0, textLocation), effectiveRange: nil) as? PlatformFont
        let side: CGFloat = 12
        let baseline = markerRect.minY + layoutManager.location(forGlyphAt: glyphRange.location).y

        // Centred on the x-height rather than the baseline: a box centred on the
        // baseline sits visibly low, because letters extend upward from it. Same
        // gutter centre as a bullet, so bullets and checkboxes in one list share
        // a vertical axis.
        return CGRect(
            x: markerRect.minX - MarkdownHighlighter.markerGutter - side / 2,
            y: baseline - (font?.xHeight ?? 8) / 2 - side / 2,
            width: side,
            height: side
        )
    }

    /// The task marker whose checkbox was tapped at `point`, if any.
    ///
    /// The target is grown to 44pt — Apple's minimum — around a box that is
    /// drawn at 12. A 12pt tap target is roughly a third of a fingertip, and on
    /// iOS this is the only way to tick a box at all.
    func checkboxHit(at point: CGPoint) -> NSRange? {
        var hit: NSRange?
        storage.enumerateAttribute(
            .inkstoneCheckbox,
            in: NSRange(location: 0, length: storage.length)
        ) { value, range, stop in
            guard value != nil, let box = checkboxBox(for: range) else { return }
            let target = box.insetBy(dx: -(44 - box.width) / 2, dy: -(44 - box.height) / 2)
            if target.contains(point) {
                hit = range
                stop.pointee = true
            }
        }
        return hit
    }

    /// Paints a real bullet where the `-` of a list item was concealed.
    ///
    /// The marker cannot simply be swapped for "•" — that would edit the note.
    /// Hiding it and drawing a dot in the space it occupied gives the rendered
    /// look without touching a byte of the file.
    func drawBullets(in rect: CGRect) {
        let colour = style.palette.faintText.platformColor

        storage.enumerateAttribute(
            .inkstoneBullet,
            in: NSRange(location: 0, length: storage.length)
        ) { value, range, _ in
            guard let level = value as? Int else { return }
            let glyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            let markerRect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: container)
                .offsetBy(dx: origin.x, dy: origin.y)
            guard markerRect.intersects(rect) else { return }

            // Nested levels get a smaller, hollow dot, the way outliners do.
            let diameter: CGFloat = level == 0 ? 5 : 4
            // Centre of the gutter the paragraph indent reserved. Checkboxes use
            // the same centre, so a mixed list lines up down one axis.
            let gutterCentre = markerRect.minX - MarkdownHighlighter.markerGutter
            // Sit the dot on the text's optical centre, not the line box's. With
            // a line-height multiple above 1 the box is much taller than the
            // glyphs, so centring on it floats the bullet above the words.
            //
            // Measured on the text after the marker, not the marker: the marker
            // is collapsed to 0.01pt, whose x-height is effectively zero and
            // would drop the dot to the baseline. Checkboxes measure the same
            // way, which is what keeps a mixed list on one axis.
            let textLocation = min(range.location + range.length, storage.length - 1)
            let font = storage.attribute(.font, at: max(0, textLocation), effectiveRange: nil) as? PlatformFont
            let baseline = markerRect.minY
                + layoutManager.location(forGlyphAt: glyphRange.location).y
            let centre = baseline - (font?.xHeight ?? 8) / 2
            let dot = CGRect(
                x: gutterCentre - diameter / 2,
                y: centre - diameter / 2,
                width: diameter,
                height: diameter
            )
            colour.setFill()
            let path = PlatformBezierPath(ovalIn: dot)
            if level == 0 {
                path.fill()
            } else {
                colour.setStroke()
                path.lineWidth = 1
                path.stroke()
            }
        }
    }

    /// Draws the vertical rule down the left edge of quoted lines.
    func drawQuoteRules(in rect: CGRect) {
        let colour = style.palette.divider.platformColor

        storage.enumerateAttribute(
            .inkstoneQuoteDepth,
            in: NSRange(location: 0, length: storage.length)
        ) { value, range, _ in
            guard let depth = value as? Int else { return }
            let glyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            let lineRect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: container)
                .offsetBy(dx: origin.x, dy: origin.y)
            guard lineRect.intersects(rect) else { return }

            colour.setFill()
            for level in 0..<depth {
                // 4pt, matching Typora's `border-left: 4px`.
                let x = origin.x + CGFloat(level) * MarkdownHighlighter.quoteIndent + 2
                CGRect(x: x, y: lineRect.minY, width: 4, height: lineRect.height).fillPlatform()
            }
        }
    }
}
