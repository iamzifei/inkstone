import SwiftUI
import InkstoneCore

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Actions the editor hands back to the app when the user interacts with
/// something that isn't plain text.
struct EditorActions {
    var followWikiLink: (WikiLink) -> Void = { _ in }
    var followTag: (String) -> Void = { _ in }
    var openExternal: (URL) -> Void = { _ in }
    /// Resolves an embed target to a file in the vault, for inline previews.
    var resolveAttachment: (String) -> URL? = { _ in nil }
    /// Copies a dropped or pasted file into the vault and returns the markup to
    /// insert for it. Returns nil when the import fails.
    var importAttachment: (URL) -> String? = { _ in nil }
    /// Same, for raw data such as an image on the pasteboard.
    var importAttachmentData: (Data, String) -> String? = { _, _ in nil }
    /// Opens an attachment with the system handler.
    var openAttachment: (URL) -> Void = { _ in }
}

/// The Markdown editor.
///
/// Wraps the platform text view rather than SwiftUI's `TextEditor` because we
/// need attributed-run access, caret position, click targets on links, and
/// TextKit-level control over paragraph metrics — none of which `TextEditor`
/// exposes.
struct MarkdownEditorView: View {
    @Binding var text: String
    let style: Style
    let mode: EditorMode
    let actions: EditorActions
    var spellCheck: Bool = false

    var body: some View {
        TextViewRepresentable(
            text: $text, style: style, mode: mode, actions: actions, spellCheck: spellCheck
        )
        .background(style.background)
    }
}

// MARK: - Shared coordinator

/// Platform-agnostic editing logic, shared by the AppKit and UIKit wrappers.
@MainActor
class EditorCoordinator: NSObject {
    var text: Binding<String>
    var style: Style
    var mode: EditorMode
    var actions: EditorActions
    /// Whether the system spell checker runs. Read from settings rather than
    /// hard-coded — the preference existed but nothing consulted it.
    var spellCheck: Bool
    /// Guards against the re-entrant highlight → didChange → highlight loop.
    var isApplyingAttributes = false

    init(text: Binding<String>, style: Style, mode: EditorMode, actions: EditorActions, spellCheck: Bool) {
        self.text = text
        self.style = style
        self.mode = mode
        self.actions = actions
        self.spellCheck = spellCheck
    }

    var highlighter: MarkdownHighlighter {
        var highlighter = MarkdownHighlighter(style: style, mode: mode)
        highlighter.resolveAttachment = actions.resolveAttachment
        highlighter.availableWidth = inlineImageWidth
        return highlighter
    }

    /// Width inline images are scaled to. Tracks the text measure so an embedded
    /// screenshot fits the column instead of overflowing it.
    var inlineImageWidth: CGFloat = 680

    #if os(macOS)
    /// Imports whatever the pasteboard holds into the vault and returns the
    /// Markdown to insert, or nil if there is nothing importable.
    ///
    /// File URLs win over image data: dropping a PNG offers both, and copying the
    /// original file preserves its name and its bytes exactly, where the image
    /// representation would be re-encoded and lose the filename.
    func attachmentMarkup(from pasteboard: NSPasteboard) -> String? {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL], !urls.isEmpty {
            let markup = urls.compactMap { actions.importAttachment($0) }
            guard !markup.isEmpty else { return nil }
            return markup.joined(separator: "\n")
        }

        // A screenshot or an image copied out of another app arrives as raw data.
        for (type, ext) in [(NSPasteboard.PasteboardType.png, "png"),
                            (NSPasteboard.PasteboardType.tiff, "tiff")] {
            guard let data = pasteboard.data(forType: type) else { continue }
            return actions.importAttachmentData(data, "Pasted image.\(ext)")
        }
        return nil
    }
    #endif

    /// Paragraph range containing the caret, so live preview can reveal syntax
    /// on the line being edited.
    func caretLineRange(in string: NSString, selection: NSRange) -> NSRange? {
        guard mode == .livePreview else { return nil }
        guard selection.location <= string.length else { return nil }
        return string.paragraphRange(for: NSRange(location: selection.location, length: 0))
    }

    /// Handles a click/tap at a character index; returns true when the editor
    /// should suppress its default caret placement.
    func handleActivation(at index: Int, in storage: NSTextStorage) -> Bool {
        guard index >= 0, index < storage.length else { return false }
        let attributes = storage.attributes(at: index, effectiveRange: nil)

        // Attachments are checked before wikilinks: an `![[clip.mp4]]` carries
        // both attributes, and clicking it should play the file rather than try
        // to open a note that does not exist.
        if let attachment = attributes[.inkstoneAttachment] as? URL {
            actions.openAttachment(attachment)
            return true
        }
        // A footnote marker jumps to its counterpart — reference to definition,
        // and back again — which is the whole point of numbering them.
        if let id = attributes[.inkstoneFootnote] as? String {
            jumpToFootnote(id: id, from: index, in: storage)
            return true
        }
        if let link = attributes[.inkstoneWikiLink] as? WikiLink {
            actions.followWikiLink(link)
            return true
        }
        if let tag = attributes[.inkstoneTag] as? String {
            actions.followTag(tag)
            return true
        }
        if let destination = attributes[.inkstoneLinkDestination] as? String {
            if destination.contains("://"), let url = URL(string: destination) {
                actions.openExternal(url)
            } else {
                actions.followWikiLink(WikiLink(target: destination))
            }
            return true
        }
        return false
    }

    /// Scrolls to the other end of a footnote pair.
    func jumpToFootnote(id: String, from index: Int, in storage: NSTextStorage) {
        var destination: NSRange?
        storage.enumerateAttribute(
            .inkstoneFootnote,
            in: NSRange(location: 0, length: storage.length)
        ) { value, range, stop in
            guard value as? String == id, !NSLocationInRange(index, range) else { return }
            destination = range
            stop.pointee = true
        }
        guard let destination else { return }
        #if os(macOS)
        textViewForScrolling?.scrollRangeToVisible(destination)
        textViewForScrolling?.setSelectedRange(NSRange(location: destination.location, length: 0))
        #endif
    }

    #if os(macOS)
    /// Set by the AppKit coordinator; nil elsewhere.
    var textViewForScrolling: NSTextView? { nil }
    #endif

    /// Continues Markdown lists on Return: `- item` → `- `, `1. item` → `2. `,
    /// `- [ ] task` → `- [ ] `. Pressing Return on an empty list item ends the
    /// list instead of adding another bullet.
    /// - Returns: the replacement string to insert, or nil to use the default.
    func listContinuation(for line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        // Empty list item: swallow the marker and end the list.
        if ["-", "*", "+", "- [ ]", "* [ ]", "+ [ ]"].contains(trimmed) { return "" }

        let indent = String(line.prefix { $0 == " " || $0 == "\t" })
        let body = line.dropFirst(indent.count)

        // Task item: `- [x] something` continues as an unchecked task.
        if let marker = body.first, "-*+".contains(marker) {
            let afterMarker = body.dropFirst().drop(while: { $0 == " " || $0 == "\t" })
            if afterMarker.hasPrefix("[") ,
               afterMarker.dropFirst().dropFirst().hasPrefix("]"),
               !afterMarker.dropFirst(3).trimmingCharacters(in: .whitespaces).isEmpty {
                return "\n\(indent)\(marker) [ ] "
            }
            if !afterMarker.isEmpty {
                return "\n\(indent)\(marker) "
            }
        }

        // Ordered item: `3. something` continues as `4. `.
        let digits = body.prefix(while: \.isNumber)
        if !digits.isEmpty {
            let rest = body.dropFirst(digits.count)
            if let separator = rest.first, separator == "." || separator == ")",
               !rest.dropFirst().trimmingCharacters(in: .whitespaces).isEmpty {
                let next = (Int(digits) ?? 1) + 1
                return "\n\(indent)\(next)\(separator) "
            }
        }

        if body.hasPrefix(">") {
            return "\n\(indent)> "
        }
        return nil
    }

    /// Characters that auto-close. `[` also powers `[[` wikilink completion.
    static let pairs: [String: String] = [
        "(": ")", "[": "]", "{": "}", "\"": "\"", "`": "`",
        "“": "”", "（": "）", "「": "」", "《": "》",
    ]
}

// MARK: - macOS

#if os(macOS)

/// `NSTextView` subclass that routes clicks on links to the coordinator before
/// AppKit moves the caret.
final class InkstoneTextView: NSTextView {
    weak var coordinator: EditorCoordinator?

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let index = characterIndexForInsertion(at: point)
        // Modifier-free clicks follow links; ⌥-click places the caret instead,
        // giving the user a way to edit link text in live preview.
        if !event.modifierFlags.contains(.option),
           let storage = textStorage,
           let coordinator,
           MainActor.assumeIsolated({ coordinator.handleActivation(at: index, in: storage) }) {
            return
        }
        super.mouseDown(with: event)
    }

    /// Draws the caret at the height of the line rather than of the font.
    ///
    /// AppKit sizes the insertion point to the font's own line height. Once a
    /// paragraph carries an explicit line height — 1.6x the font size here, for
    /// CSS-like leading — the caret is markedly shorter than the line it sits
    /// in, and reads as belonging to some other, smaller document.
    ///
    /// The caret is also nudged right by a hair. It is drawn flush against the
    /// preceding glyph, which at this size and weight looks stuck to the last
    /// letter; a fraction of a point restores the gap without moving it far
    /// enough to misrepresent where text will be inserted.
    override func drawInsertionPoint(in rect: NSRect, color: NSColor, turnedOn flag: Bool) {
        var rect = rect
        if let height = lineHeightAtCaret(), height > rect.height {
            // Keep it centred on the glyphs, so the extra height is shared
            // between ascender and descender instead of hanging below.
            rect.origin.y -= (height - rect.height) / 2
            rect.size.height = height
        }
        rect.origin.x += Self.caretInset
        super.drawInsertionPoint(in: rect, color: color, turnedOn: flag)
    }

    /// AppKit invalidates the area of the caret it *would* have drawn, which is
    /// shorter than the one actually drawn — without widening it, a moving caret
    /// leaves fragments of itself behind.
    override func setNeedsDisplay(_ invalidRect: NSRect, avoidAdditionalLayout flag: Bool) {
        var rect = invalidRect
        rect.origin.y -= Self.caretOvershoot
        rect.size.height += Self.caretOvershoot * 2
        rect.size.width += Self.caretInset + 1
        super.setNeedsDisplay(rect, avoidAdditionalLayout: flag)
    }

    private static let caretInset: CGFloat = 0.75
    /// Half the largest gap between a line height and the font's own height —
    /// 6.8pt on body text, less on headings, so 4pt each way covers it. This
    /// widens *every* invalidation, not just the caret's, so it is kept to what
    /// is actually needed rather than a comfortable overestimate.
    private static let caretOvershoot: CGFloat = 4

    /// The height of the line fragment the caret currently sits in.
    private func lineHeightAtCaret() -> CGFloat? {
        guard let storage = textStorage, storage.length > 0 else { return nil }
        let location = min(selectedRange().location, storage.length - 1)

        // The paragraph's own line height, not the line fragment's. A fragment
        // that ends a paragraph also carries `paragraphSpacing` — 4pt on a list
        // item — and sizing the caret from it would overshoot the text by that
        // much on exactly the lines where the caret is most often placed.
        if let style = storage.attribute(.paragraphStyle, at: location, effectiveRange: nil)
            as? NSParagraphStyle, style.maximumLineHeight > 0 {
            return style.maximumLineHeight
        }

        guard let layoutManager else { return nil }
        let glyph = layoutManager.glyphIndexForCharacter(at: location)
        guard glyph < layoutManager.numberOfGlyphs else { return nil }
        let fragment = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        return fragment.height > 0 ? fragment.height : nil
    }

    /// Paints inline attachment images into the space the highlighter reserved.
    ///
    /// See `MarkdownHighlighter.inlineImage` for why this is drawn by hand rather
    /// than with `NSTextAttachment`: the layout manager only renders attachments
    /// for the U+FFFC character, and adding one to the note's text would change
    /// the file on disk.
    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard let storage = textStorage, let layoutManager, let container = textContainer else { return }

        // Fills go down first so text and images sit on top of them.
        drawInlineFills(in: rect, storage: storage, layoutManager: layoutManager, container: container)

        let origin = textContainerOrigin
        storage.enumerateAttribute(
            .inkstoneInlineImage,
            in: NSRange(location: 0, length: storage.length)
        ) { value, range, _ in
            guard let image = value as? NSImage else { return }
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
            let target = NSRect(
                x: x,
                y: lineRect.minY + MarkdownHighlighter.inlineImagePadding,
                width: size.width,
                height: size.height
            )

            // A text view uses flipped coordinates, so drawing an NSImage
            // straight into it lands the picture upside down. Flip the CTM about
            // the target rect and draw the CGImage into the corrected space.
            guard let context = NSGraphicsContext.current?.cgContext,
                  let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
            else { return }

            context.saveGState()
            context.translateBy(x: 0, y: target.maxY)
            context.scaleBy(x: 1, y: -1)
            context.draw(
                cgImage,
                in: CGRect(x: target.minX, y: 0, width: target.width, height: target.height)
            )
            context.restoreGState()
        }

        drawBullets(in: rect, storage: storage, layoutManager: layoutManager, container: container)
        drawQuoteRules(in: rect, storage: storage, layoutManager: layoutManager, container: container)
        drawCheckboxes(in: rect, storage: storage, layoutManager: layoutManager, container: container)
        drawHeadingRules(in: rect, storage: storage, layoutManager: layoutManager, container: container)
        drawInlineMath(in: rect, storage: storage, layoutManager: layoutManager, container: container)
    }

    /// Draws inline formulas into the space their kerning reserved.
    ///
    /// Sat on the baseline rather than centred in the line box: an inline formula
    /// has to sit on the same line as the words around it, and a line box with a
    /// line-height multiple is much taller than the text.
    private func drawInlineMath(
        in rect: NSRect,
        storage: NSTextStorage,
        layoutManager: NSLayoutManager,
        container: NSTextContainer
    ) {
        let origin = textContainerOrigin
        storage.enumerateAttribute(
            .inkstoneInlineMath,
            in: NSRange(location: 0, length: storage.length)
        ) { value, range, _ in
            guard let image = value as? NSImage else { return }
            let glyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            let box = layoutManager.boundingRect(forGlyphRange: glyphRange, in: container)
                .offsetBy(dx: origin.x, dy: origin.y)
            guard box.intersects(rect) else { return }

            let baseline = box.minY + layoutManager.location(forGlyphAt: glyphRange.location).y
            let size = image.size
            // Roughly centre the formula on the x-height, which is where a
            // reader expects an inline expression to sit.
            let target = NSRect(
                x: box.minX,
                y: baseline - size.height * 0.72,
                width: size.width,
                height: size.height
            )

            guard let context = NSGraphicsContext.current?.cgContext,
                  let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
            else { return }
            context.saveGState()
            context.translateBy(x: 0, y: target.maxY)
            context.scaleBy(x: 1, y: -1)
            context.draw(cgImage, in: CGRect(x: target.minX, y: 0, width: target.width, height: target.height))
            context.restoreGState()
        }
    }

    /// Rules off h1 and h2, the way Typora's default theme does.
    private func drawHeadingRules(
        in rect: NSRect,
        storage: NSTextStorage,
        layoutManager: NSLayoutManager,
        container: NSTextContainer
    ) {
        guard let coordinator else { return }
        let colour = MainActor.assumeIsolated { coordinator.style.palette.divider.platformColor }
        let origin = textContainerOrigin
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
            // Sits just under the text, not at the bottom of the paragraph's
            // trailing space, which would leave it floating.
            NSRect(x: origin.x, y: box.maxY - 1, width: width, height: 1).fill()
        }
    }

    /// Paints rounded fills behind inline code and attachment chips.
    ///
    /// `NSAttributedString.backgroundColor` fills the entire line fragment, which
    /// at a 1.75 line-height multiple is roughly twice the height of the glyphs —
    /// the tint ends up looming above the text instead of hugging it. Drawing it
    /// here allows a box sized to the font and rounded like a chip.
    private func drawInlineFills(
        in rect: NSRect,
        storage: NSTextStorage,
        layoutManager: NSLayoutManager,
        container: NSTextContainer
    ) {
        let origin = textContainerOrigin
        storage.enumerateAttribute(
            .inkstoneInlineFill,
            in: NSRange(location: 0, length: storage.length)
        ) { value, range, _ in
            guard let colour = value as? NSColor, range.length > 0 else { return }
            let font = storage.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont
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
                let chip = NSRect(
                    x: box.minX - 3,
                    y: baseline - ascender - 2,
                    width: box.width + 6,
                    height: (ascender - descender) + 4
                )
                colour.setFill()
                NSBezierPath(roundedRect: chip, xRadius: 4, yRadius: 4).fill()
            }
        }
    }

    /// Draws a checkbox where a `- [ ]` marker was concealed.
    ///
    /// Same reasoning as the bullets: the brackets cannot be swapped for a real
    /// checkbox glyph without editing the note, so the marker is hidden and the
    /// box is painted into the space it left.
    private func drawCheckboxes(
        in rect: NSRect,
        storage: NSTextStorage,
        layoutManager: NSLayoutManager,
        container: NSTextContainer
    ) {
        guard let coordinator else { return }
        let palette = MainActor.assumeIsolated { coordinator.style.palette }
        let origin = textContainerOrigin

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
            let font = storage.attribute(.font, at: max(0, textLocation), effectiveRange: nil) as? NSFont
            let side: CGFloat = 12
            let baseline = markerRect.minY + layoutManager.location(forGlyphAt: glyphRange.location).y
            // Centred on the x-height rather than the baseline: a box centred on
            // the baseline sits visibly low, because letters extend upward from
            // it. Same gutter centre as a bullet, so bullets and checkboxes in
            // one list share a vertical axis.
            let box = NSRect(
                x: markerRect.minX - MarkdownHighlighter.markerGutter - side / 2,
                y: baseline - (font?.xHeight ?? 8) / 2 - side / 2,
                width: side,
                height: side
            )

            let path = NSBezierPath(roundedRect: box, xRadius: 3, yRadius: 3)
            if checked {
                palette.accent.platformColor.setFill()
                path.fill()
                // A tick, drawn rather than set in a font so it scales with the box.
                let tick = NSBezierPath()
                tick.move(to: NSPoint(x: box.minX + side * 0.24, y: box.midY + side * 0.02))
                tick.line(to: NSPoint(x: box.minX + side * 0.43, y: box.maxY - side * 0.26))
                tick.line(to: NSPoint(x: box.maxX - side * 0.22, y: box.minY + side * 0.28))
                tick.lineWidth = 1.8
                tick.lineCapStyle = .round
                tick.lineJoinStyle = .round
                palette.background.platformColor.setStroke()
                tick.stroke()
            } else {
                palette.faintText.platformColor.setStroke()
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
    private func drawBullets(
        in rect: NSRect,
        storage: NSTextStorage,
        layoutManager: NSLayoutManager,
        container: NSTextContainer
    ) {
        guard let coordinator else { return }
        let colour = MainActor.assumeIsolated { coordinator.style.palette.faintText.platformColor }
        let origin = textContainerOrigin

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
            let font = storage.attribute(.font, at: max(0, textLocation), effectiveRange: nil) as? NSFont
            let baseline = markerRect.minY
                + layoutManager.location(forGlyphAt: glyphRange.location).y
            let centre = baseline - (font?.xHeight ?? 8) / 2
            let dot = NSRect(
                x: gutterCentre - diameter / 2,
                y: centre - diameter / 2,
                width: diameter,
                height: diameter
            )
            colour.setFill()
            let path = NSBezierPath(ovalIn: dot)
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
    private func drawQuoteRules(
        in rect: NSRect,
        storage: NSTextStorage,
        layoutManager: NSLayoutManager,
        container: NSTextContainer
    ) {
        guard let coordinator else { return }
        let colour = MainActor.assumeIsolated { coordinator.style.palette.divider.platformColor }
        let origin = textContainerOrigin

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
                NSRect(x: x, y: lineRect.minY, width: 4, height: lineRect.height).fill()
            }
        }
    }

    /// Single entry point for both drag-and-drop and paste — AppKit routes both
    /// through here — so a file dropped on the editor and one pasted into it are
    /// imported identically.
    override func readSelection(from pasteboard: NSPasteboard) -> Bool {
        if let coordinator,
           let markup = MainActor.assumeIsolated({ coordinator.attachmentMarkup(from: pasteboard) }) {
            insertText(markup, replacementRange: selectedRange())
            return true
        }
        return super.readSelection(from: pasteboard)
    }

    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
        [.fileURL, .png, .tiff] + super.readablePasteboardTypes
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        // Pointing hand over links, so they read as interactive.
        guard let storage = textStorage, let layoutManager, let container = textContainer else { return }
        storage.enumerateAttribute(
            .inkstoneWikiLink,
            in: NSRange(location: 0, length: storage.length)
        ) { value, range, _ in
            guard value != nil else { return }
            let glyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            let rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: container)
                .offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
            addCursorRect(rect, cursor: .pointingHand)
        }
    }
}

private struct TextViewRepresentable: NSViewRepresentable {
    @Binding var text: String
    let style: Style
    let mode: EditorMode
    let actions: EditorActions
    let spellCheck: Bool

    func makeCoordinator() -> MacCoordinator {
        MacCoordinator(text: $text, style: style, mode: mode, actions: actions, spellCheck: spellCheck)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.autohidesScrollers = true

        let textView = InkstoneTextView()
        textView.coordinator = context.coordinator
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        // Left to applyStyle(), which consults the setting. Hard-coding it here
        // meant the "Check spelling" preference had no effect on a freshly
        // opened note — it only ever took hold after some other style change.
        textView.isContinuousSpellCheckingEnabled = spellCheck
        textView.isGrammarCheckingEnabled = false
        textView.drawsBackground = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.string = text

        scrollView.documentView = textView
        context.coordinator.textView = textView

        // The readable-measure inset depends on the scroll view's width, so it
        // has to be recomputed whenever that width changes. Without this it was
        // only ever calculated on the first layout — when the width is often
        // still zero — and the text column then ran the full width of the window
        // no matter how wide the user dragged it.
        // Re-style as the reader scrolls into text that has not been styled yet.
        scrollView.contentView.postsBoundsChangedNotifications = true
        context.coordinator.scrollObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scrollView.contentView,
            queue: .main
        ) { [weak coordinator = context.coordinator] _ in
            MainActor.assumeIsolated { coordinator?.rehighlightForScrollIfNeeded() }
        }

        scrollView.postsFrameChangedNotifications = true
        context.coordinator.frameObserver = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification,
            object: scrollView,
            queue: .main
        ) { [weak coordinator = context.coordinator] _ in
            MainActor.assumeIsolated { coordinator?.updateInsets() }
        }

        // A Mermaid diagram renders asynchronously; when one lands, run again so
        // it replaces its source. Guarded by the renderer's cache, so this
        // settles rather than looping.
        MermaidRenderer.shared.onRendered = { [weak coordinator = context.coordinator] in
            MainActor.assumeIsolated { coordinator?.rehighlight() }
        }

        context.coordinator.applyStyle()
        context.coordinator.rehighlight()
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.text = $text
        coordinator.actions = actions

        guard let textView = coordinator.textView else { return }
        if textView.string != text {
            let selection = textView.selectedRange()
            textView.string = text
            textView.setSelectedRange(NSRange(
                location: min(selection.location, (text as NSString).length),
                length: 0
            ))
            coordinator.rehighlight()
        }

        if coordinator.style.typography != style.typography
            || coordinator.style.isDark != style.isDark
            || coordinator.mode != mode
            || coordinator.spellCheck != spellCheck {
            coordinator.style = style
            coordinator.mode = mode
            coordinator.spellCheck = spellCheck
            coordinator.applyStyle()
            coordinator.rehighlight()
        }
    }

    @MainActor
    final class MacCoordinator: EditorCoordinator, NSTextViewDelegate {
        weak var textView: InkstoneTextView?
        override var textViewForScrolling: NSTextView? { textView }
        /// Token for the scroll view's frame-change observation; removed on
        /// deinit so a closed tab does not keep re-laying-out a dead editor.
        ///
        /// `nonisolated(unsafe)` because `deinit` runs outside the main actor and
        /// cannot touch an isolated property. Safe in practice: it is only ever
        /// written once during `makeNSView` on the main actor, and only read
        /// again when the coordinator is being torn down.
        nonisolated(unsafe) var frameObserver: (any NSObjectProtocol)?
        nonisolated(unsafe) var scrollObserver: (any NSObjectProtocol)?

        deinit {
            if let frameObserver { NotificationCenter.default.removeObserver(frameObserver) }
            if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }
        }

        func applyStyle() {
            guard let textView else { return }
            textView.insertionPointColor = style.palette.accent.platformColor
            textView.selectedTextAttributes = [
                .backgroundColor: style.palette.selection.platformColor
            ]
            textView.isContinuousSpellCheckingEnabled = spellCheck && mode != .reading

            // Reading mode was previously indistinguishable from live preview:
            // it hid the syntax but the document stayed fully editable, so the
            // mode picker offered something that did not exist. Making it
            // read-only is what the name promises — text stays selectable so it
            // can still be copied.
            textView.isEditable = mode != .reading
            textView.isSelectable = true
            updateInsets()
        }

        /// Centres the text column and caps its measure, which is the single
        /// biggest readability win in a full-width window.
        func updateInsets() {
            guard let textView, let scrollView = textView.enclosingScrollView else { return }
            let available = scrollView.contentSize.width
            let measure = style.typography.isReadableLineWidthEnabled
                ? min(available - 48, style.typography.readableLineWidth)
                : available - 48
            let horizontal = max(24, (available - measure) / 2)
            textView.textContainerInset = NSSize(width: horizontal, height: 32)

            // Inline images are scaled to the measure. Only re-highlight when the
            // width has moved enough to matter — the image cache buckets by 32pt,
            // so re-running on every pixel of a live resize would be wasted work.
            if abs(inlineImageWidth - measure) >= 32 {
                inlineImageWidth = measure
                rehighlight()
            }
        }

        /// Documents below this size are always styled whole: the pass is already
        /// inside a frame, and doing it in one go avoids any chance of a seam
        /// between styled and unstyled text.
        static let viewportThreshold = 40_000

        /// Character range last styled, so scrolling only re-runs when the reader
        /// approaches the edge of it.
        var styledRange: NSRange?

        /// The slice worth styling: what is on screen, plus a screenful either
        /// side so scrolling has somewhere to go before it needs more.
        func viewportScope() -> NSRange? {
            guard let textView, let storage = textView.textStorage,
                  storage.length > Self.viewportThreshold,
                  let layoutManager = textView.layoutManager,
                  let container = textView.textContainer
            else { return nil }

            let glyphRange = layoutManager.glyphRange(forBoundingRect: textView.visibleRect, in: container)
            let visible = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
            guard visible.length > 0 else { return nil }

            let padding = max(visible.length, 2_000)
            let start = max(0, visible.location - padding)
            let end = min(storage.length, visible.location + visible.length + padding)
            return NSRange(location: start, length: end - start)
        }

        /// Re-styles after scrolling, but only once the viewport nears the edge of
        /// what is already styled — otherwise every scroll event would re-run the
        /// whole pass.
        func rehighlightForScrollIfNeeded() {
            guard let scope = viewportScope() else { return }
            if let styled = styledRange,
               scope.location >= styled.location,
               scope.location + scope.length <= styled.location + styled.length {
                return
            }
            rehighlight()
        }

        func rehighlight() {
            guard let textView, let storage = textView.textStorage else { return }
            #if DEBUG
            let started = DispatchTime.now().uptimeNanoseconds
            defer {
                let ms = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
                if ms > 8 {
                    FileHandle.standardError.write(Data(
                        "[inkstone] highlight \(storage.length) chars in \(String(format: "%.1f", ms)) ms\n".utf8
                    ))
                    let url = (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                        ?? URL(fileURLWithPath: NSTemporaryDirectory())).appending(path: "inkstone-debug.log")
                    let line = "[perf] highlight \(storage.length) chars \(String(format: "%.1f", ms)) ms\n"
                    if let handle = try? FileHandle(forWritingTo: url) {
                        handle.seekToEndOfFile(); handle.write(Data(line.utf8)); try? handle.close()
                    } else { try? Data(line.utf8).write(to: url) }
                }
            }
            #endif
            isApplyingAttributes = true
            defer { isApplyingAttributes = false }
            let caretRange = caretLineRange(in: storage.string as NSString, selection: textView.selectedRange())
            let scope = viewportScope()
            styledRange = scope
            highlighter.highlight(storage, caretLineRange: caretRange, visibleRange: scope)
        }

        func textDidChange(_ notification: Notification) {
            guard !isApplyingAttributes, let textView else { return }
            text.wrappedValue = textView.string
            rehighlight()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard !isApplyingAttributes else { return }
            // Live preview needs a re-run whenever the caret moves to a new line.
            rehighlight()
        }

        func textView(
            _ textView: NSTextView,
            shouldChangeTextIn affectedCharRange: NSRange,
            replacementString: String?
        ) -> Bool {
            guard let replacementString else { return true }

            if replacementString == "\n" {
                let string = textView.string as NSString
                let lineRange = string.paragraphRange(for: NSRange(location: affectedCharRange.location, length: 0))
                let line = string.substring(with: lineRange).trimmingCharacters(in: .newlines)
                if let continuation = listContinuation(for: line) {
                    if continuation.isEmpty {
                        // Ending a list: clear the empty marker line.
                        textView.insertText("\n", replacementRange: NSRange(
                            location: lineRange.location,
                            length: lineRange.length - (string.substring(with: lineRange).hasSuffix("\n") ? 1 : 0)
                        ))
                    } else {
                        textView.insertText(continuation, replacementRange: affectedCharRange)
                    }
                    return false
                }
            }

            if let closing = EditorCoordinator.pairs[replacementString], affectedCharRange.length == 0 {
                textView.insertText(replacementString + closing, replacementRange: affectedCharRange)
                textView.setSelectedRange(NSRange(location: affectedCharRange.location + 1, length: 0))
                return false
            }

            // Wrap the selection instead of replacing it: select text, press `*`,
            // get `*text*`. Small thing, used constantly.
            if let closing = EditorCoordinator.pairs[replacementString], affectedCharRange.length > 0 {
                let selected = (textView.string as NSString).substring(with: affectedCharRange)
                textView.insertText(replacementString + selected + closing, replacementRange: affectedCharRange)
                return false
            }

            return true
        }
    }
}

#else

// MARK: - iOS

private struct TextViewRepresentable: UIViewRepresentable {
    @Binding var text: String
    let style: Style
    let mode: EditorMode
    let actions: EditorActions
    let spellCheck: Bool

    func makeCoordinator() -> PhoneCoordinator {
        PhoneCoordinator(text: $text, style: style, mode: mode, actions: actions, spellCheck: spellCheck)
    }

    func makeUIView(context: Context) -> UITextView {
        // TextKit 1 deliberately: we need `layoutManager.characterIndex(for:)`
        // to hit-test link taps, which has no direct TextKit 2 equivalent that
        // works as cleanly inside a `UITextView`.
        let textView = UITextView(usingTextLayoutManager: false)
        textView.delegate = context.coordinator
        textView.backgroundColor = .clear
        textView.alwaysBounceVertical = true
        textView.autocorrectionType = .default
        textView.autocapitalizationType = .sentences
        textView.smartQuotesType = .no
        textView.smartDashesType = .no
        textView.keyboardDismissMode = .interactive
        textView.text = text

        let tap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(PhoneCoordinator.handleTap(_:))
        )
        // Run alongside the text view's own gestures so the caret still moves
        // when the tap isn't on a link.
        tap.cancelsTouchesInView = false
        textView.addGestureRecognizer(tap)

        context.coordinator.textView = textView
        context.coordinator.applyStyle()
        context.coordinator.rehighlight()
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        let coordinator = context.coordinator
        coordinator.text = $text
        coordinator.actions = actions

        if textView.text != text {
            let selection = textView.selectedRange
            textView.text = text
            textView.selectedRange = NSRange(
                location: min(selection.location, (text as NSString).length),
                length: 0
            )
            coordinator.rehighlight()
        }

        if coordinator.style.typography != style.typography
            || coordinator.style.isDark != style.isDark
            || coordinator.mode != mode
            || coordinator.spellCheck != spellCheck {
            coordinator.style = style
            coordinator.mode = mode
            coordinator.spellCheck = spellCheck
            coordinator.applyStyle()
            coordinator.rehighlight()
        }
    }

    @MainActor
    final class PhoneCoordinator: EditorCoordinator, UITextViewDelegate {
        weak var textView: UITextView?

        func applyStyle() {
            guard let textView else { return }
            textView.tintColor = style.palette.accent.platformColor
            // See the macOS coordinator: reading mode is read-only, not just
            // "live preview with the syntax hidden".
            textView.isEditable = mode != .reading
            textView.isSelectable = true
            updateInsets()
        }

        func updateInsets() {
            guard let textView else { return }
            let available = textView.bounds.width
            let measure = style.typography.isReadableLineWidthEnabled
                ? min(available - 32, style.typography.readableLineWidth)
                : available - 32
            let horizontal = max(16, (available - measure) / 2)
            textView.textContainerInset = UIEdgeInsets(top: 20, left: horizontal, bottom: 240, right: horizontal)
            textView.textContainer.lineFragmentPadding = 0
        }

        func rehighlight() {
            guard let textView else { return }
            let storage = textView.textStorage
            isApplyingAttributes = true
            defer { isApplyingAttributes = false }
            let caretRange = caretLineRange(in: storage.string as NSString, selection: textView.selectedRange)
            highlighter.highlight(storage, caretLineRange: caretRange)
        }

        func textViewDidChange(_ textView: UITextView) {
            guard !isApplyingAttributes else { return }
            text.wrappedValue = textView.text
            rehighlight()
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            guard !isApplyingAttributes else { return }
            rehighlight()
        }

        func textView(
            _ textView: UITextView,
            shouldChangeTextIn range: NSRange,
            replacementText replacementString: String
        ) -> Bool {
            if replacementString == "\n" {
                let string = textView.text as NSString
                let lineRange = string.paragraphRange(for: NSRange(location: range.location, length: 0))
                let line = string.substring(with: lineRange).trimmingCharacters(in: .newlines)
                if let continuation = listContinuation(for: line), !continuation.isEmpty {
                    textView.replace(textRange(textView, range), withText: continuation)
                    return false
                }
            }
            if let closing = EditorCoordinator.pairs[replacementString], range.length == 0 {
                textView.replace(textRange(textView, range), withText: replacementString + closing)
                textView.selectedRange = NSRange(location: range.location + 1, length: 0)
                return false
            }
            return true
        }

        @objc func handleTap(_ recognizer: UITapGestureRecognizer) {
            guard let textView else { return }
            let storage = textView.textStorage
            var point = recognizer.location(in: textView)
            point.x -= textView.textContainerInset.left
            point.y -= textView.textContainerInset.top
            let index = textView.layoutManager.characterIndex(
                for: point,
                in: textView.textContainer,
                fractionOfDistanceBetweenInsertionPoints: nil
            )
            _ = handleActivation(at: index, in: storage)
        }

        private func textRange(_ textView: UITextView, _ range: NSRange) -> UITextRange {
            let start = textView.position(from: textView.beginningOfDocument, offset: range.location)!
            let end = textView.position(from: start, offset: range.length)!
            return textView.textRange(from: start, to: end)!
        }
    }
}

#endif
