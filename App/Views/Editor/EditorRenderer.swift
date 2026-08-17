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

    /// Draws every hand-painted element that intersects `rect`.
    ///
    /// Order matters where things overlap: fills sit behind their text, rules
    /// behind glyphs, and the checkbox after the bullet so a task in a bulleted
    /// list is not drawn twice.
    func draw(in rect: CGRect) {
        drawBlockFills(in: rect)
        drawInlineFills(in: rect)
        drawBullets(in: rect)
        drawQuoteRules(in: rect)
        drawCheckboxes(in: rect)
        drawHeadingRules(in: rect)
        drawInlineMath(in: rect)
    }


    /// Paints one continuous panel behind a code fence or a table.
    ///
    /// `.backgroundColor` fills per glyph run, so a blank line inside a fence —
    /// which has no glyphs — got no fill, and neither did the space between
    /// paragraphs. A fenced block of prose came out as a stack of separate grey
    /// stripes instead of one panel, which is not what any Markdown renderer
    /// shows.
    func drawBlockFills(in rect: CGRect) {
        style.palette.codeBackground.platformColor.setFill()

        storage.enumerateAttribute(
            .inkstoneBlockFill,
            in: NSRange(location: 0, length: storage.length)
        ) { value, range, _ in
            guard value != nil else { return }
            let glyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)

            // The union of the block's line fragments, which covers the blank
            // lines and the leading between them; the bounding rect of the
            // glyphs alone would not.
            var panel = CGRect.null
            layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) { fragment, _, _, _, _ in
                panel = panel.isNull ? fragment : panel.union(fragment)
            }
            guard !panel.isNull else { return }

            panel = panel.offsetBy(dx: origin.x, dy: origin.y)
            // Full width regardless of how far the text runs, so a short line
            // does not narrow the panel.
            panel.origin.x = origin.x
            panel.size.width = container.size.width - container.lineFragmentPadding * 2
            guard panel.intersects(rect) else { return }

            PlatformBezierPath(roundedRect: panel, cornerRadius: 4).fill()
        }
    }

    /// Draws inline formulas into the space their kerning reserved.
    ///
    /// Sat on the baseline rather than centred in the line box: an inline formula
    /// has to sit on the same line as the words around it, and a line box with a
    /// line-height multiple is much taller than the text.
    func drawInlineMath(in rect: CGRect) {
        storage.enumerateAttribute(
            .inkstoneInlineMath,
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
    func drawCheckboxes(in rect: CGRect) {

        storage.enumerateAttribute(
            .inkstoneCheckbox,
            in: NSRange(location: 0, length: storage.length)
        ) { value, range, _ in
            guard let checked = value as? Bool else { return }
            let glyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            let markerRect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: container)
                .offsetBy(dx: origin.x, dy: origin.y)
            guard markerRect.intersects(rect) else { return }

            // The font of the *task text*, not of the marker.
            //
            // The marker was collapsed to 0.01pt to hide it, so reading the font
            // at `range.location` returns that hair-thin font and an x-height of
            // effectively zero — which put the box half a line below the words it
            // belongs to. The first character after the marker is the text the
            // checkbox has to line up with.
            let textLocation = min(range.location + range.length, storage.length - 1)
            let font = storage.attribute(.font, at: max(0, textLocation), effectiveRange: nil) as? PlatformFont
            let side: CGFloat = 12
            let baseline = markerRect.minY + layoutManager.location(forGlyphAt: glyphRange.location).y
            // Centred on the x-height rather than the baseline: a box centred on
            // the baseline sits visibly low, because letters extend upward from
            // it. Same gutter centre as a bullet, so bullets and checkboxes in
            // one list share a vertical axis.
            let box = CGRect(
                x: markerRect.minX - MarkdownHighlighter.markerGutter - side / 2,
                y: baseline - (font?.xHeight ?? 8) / 2 - side / 2,
                width: side,
                height: side
            )

            let path = PlatformBezierPath(roundedRect: box, cornerRadius: 3)
            if checked {
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
            } else {
                style.palette.faintText.platformColor.setStroke()
                path.lineWidth = 1.2
                path.stroke()
            }
        }
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
