import SwiftUI
import InkstoneCore

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Reading mode: the note with its Markdown syntax gone.
///
/// A separate view from the editor, and it has to be. The editor's text storage
/// *is* the file — that is the decision the whole app is built on — so reading
/// mode cannot render into it without rewriting the note on disk. This builds its
/// own attributed string from `ReadingRenderer` and never touches the document.
///
/// What that buys, beyond looking different: **copying gives prose.** In live
/// preview the syntax characters are still there at 0.01pt, so copying a
/// paragraph hands you `**bold**` back. Here they do not exist.
///
/// Everything the editor draws, this draws too.
///
/// Pictures, Mermaid diagrams and formulas are drawn here as `NSTextAttachment`s
/// — which the *editor* cannot do, because its storage is the file on disk and
/// TextKit only makes an attachment glyph for a U+FFFC character it would have to
/// insert. This view's storage is built from scratch and belongs to nobody, so
/// the attachment character is free.
///
/// Every one of them falls back to text. A picture that will not load leaves the
/// file's name, a formula that will not typeset leaves its LaTeX. Reading mode
/// may restyle anything; it may not lose anything.
struct ReadingView: View {
    let markdown: String
    /// Resolves an embed target to a file in the vault.
    var resolveAttachment: (String) -> URL? = { _ in nil }
    /// What a click does. Reading mode used to colour links and do nothing when
    /// one was clicked — including wikilinks, not only paths — so following a
    /// link meant leaving reading mode first.
    var actions = EditorActions()
    /// Resolves a path written as prose to a file, or nil if there is none.
    /// Paths are linked only when this answers, since a link going nowhere is
    /// worse than no link.
    var resolveVaultPath: (String) -> URL? = { _ in nil }
    @Environment(\.style) private var style
    /// Bumped when a Mermaid diagram finishes rendering.
    ///
    /// The image caches for pictures and formulas answer synchronously; Mermaid
    /// cannot, because it draws through a web view. Without this the first look
    /// at a note showed the diagram's source and went on showing it for ever,
    /// since nothing else would ever ask again.
    @State private var mermaidGeneration = 0

    var body: some View {
        // No `GeometryReader`: wrapping the representable in one collapsed it to
        // nothing and reading mode rendered a blank page. The text view knows its
        // own width in `updateNSView`, which is where a picture's size has to be
        // decided anyway.
        ReadingTextView(
            document: ReadingRenderer.render(
                markdown, isLinkable: { resolveVaultPath($0) != nil }),
            style: style,
            resolveAttachment: resolveAttachment,
            resolveVaultPath: resolveVaultPath,
            actions: actions,
            generation: mermaidGeneration
        )
        .background(style.background)
        .onAppear {
            MermaidRenderer.shared.onRendered = { mermaidGeneration += 1 }
        }
    }
}

/// Turns a `ReadingDocument` into something a text view can draw.
///
/// Split out from the view so the mapping from span to attribute is one place,
/// and so the renderer in the core stays free of fonts and colours.
@MainActor
enum ReadingTypesetter {
    static func attributed(
        _ document: ReadingDocument,
        style: Style,
        resolveAttachment: (String) -> URL? = { _ in nil },
        resolveVaultPath: (String) -> URL? = { _ in nil },
        availableWidth: CGFloat = 680
    ) -> NSAttributedString {
        let typography = style.typography
        let palette = style.palette
        let body = typography.editorFont.platformFont(size: typography.editorFontSize)

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = typography.lineHeightMultiple
        paragraph.paragraphSpacing = typography.paragraphSpacing

        let result = NSMutableAttributedString(
            string: document.text,
            attributes: [
                .font: body,
                .foregroundColor: palette.text.platformColor,
                .paragraphStyle: paragraph,
            ]
        )
        let full = NSRange(location: 0, length: result.length)

        for span in document.spans {
            guard span.range.location >= 0, NSMaxRange(span.range) <= full.length else { continue }
            switch span.style {
            case .heading(let level):
                let size = typography.headingSize(level: level)
                result.addAttribute(
                    .font,
                    value: typography.editorFont.platformFont(
                        size: size, weight: typography.headingWeightBoost ? .bold : .semibold),
                    range: span.range
                )
            case .bold:
                result.addAttribute(.font, value: bolded(body), range: span.range)
            case .italic:
                result.addAttribute(.font, value: italicised(body), range: span.range)
            case .strikethrough:
                result.addAttribute(.strikethroughStyle,
                                    value: NSUnderlineStyle.single.rawValue, range: span.range)
                result.addAttribute(.foregroundColor,
                                    value: palette.secondaryText.platformColor, range: span.range)
            case .highlight:
                result.addAttribute(.backgroundColor,
                                    value: palette.highlight.platformColor, range: span.range)
            case .inlineCode:
                result.addAttribute(
                    .font,
                    value: typography.codeFont.platformFont(size: typography.codeFontSize),
                    range: span.range
                )
                result.addAttribute(.backgroundColor,
                                    value: palette.codeBackground.platformColor, range: span.range)

            case .codeBlock:
                result.addAttribute(
                    .font,
                    value: typography.codeFont.platformFont(size: typography.codeFontSize),
                    range: span.range
                )
                result.addAttribute(.backgroundColor,
                                    value: palette.codeBackground.platformColor, range: span.range)
                // Every line of a fenced block is its own paragraph, so the body
                // paragraph style put a full paragraph gap between each of them
                // and a twenty-line block became three screens of mostly nothing.
                let code = NSMutableParagraphStyle()
                code.lineHeightMultiple = typography.codeLineHeightMultiple
                code.paragraphSpacing = 0
                code.paragraphSpacingBefore = 0
                result.addAttribute(.paragraphStyle, value: code, range: span.range)
            case .link(let target), .embed(let target):
                result.addAttribute(.foregroundColor, value: palette.link.platformColor, range: span.range)
                // The same attributes the editor uses, so one activation path
                // serves both modes rather than reading mode growing its own.
                if target.contains("://") {
                    result.addAttribute(.inkstoneLinkDestination, value: target, range: span.range)
                } else if let file = resolveVaultPath(target) {
                    result.addAttribute(.inkstoneVaultFile, value: file, range: span.range)
                } else {
                    result.addAttribute(
                        .inkstoneWikiLink,
                        value: WikiLink(target: target),
                        range: span.range)
                }

            case .math(let display):
                result.addAttribute(
                    .font,
                    value: typography.codeFont.platformFont(size: typography.codeFontSize),
                    range: span.range
                )
                // A formula that will not parse keeps its source, in the colour
                // the editor uses for the same thing — silently rendering nothing
                // leaves the author with no idea which formula is wrong.
                let latex = (document.text as NSString).substring(with: span.range)
                if MathRenderer.shared.error(
                    latex: latex, fontSize: typography.editorFontSize,
                    isDisplay: display, colour: palette.text.platformColor) != nil {
                    result.addAttribute(.foregroundColor,
                                        value: palette.unresolvedLink.platformColor, range: span.range)
                }
            case .tag:
                result.addAttribute(.foregroundColor, value: palette.tag.platformColor, range: span.range)
            case .quote:
                result.addAttribute(.foregroundColor,
                                    value: palette.secondaryText.platformColor, range: span.range)
            case .table:
                break   // rebuilt as a real table below

            case .properties:
                // A note's own metadata, set as the aside it is: smaller, quieter
                // and tighter than the prose, but present. It used to be deleted.
                result.addAttribute(
                    .font,
                    value: typography.codeFont.platformFont(size: typography.codeFontSize * 0.92),
                    range: span.range
                )
                result.addAttribute(.foregroundColor,
                                    value: palette.secondaryText.platformColor, range: span.range)
                let aside = NSMutableParagraphStyle()
                aside.lineHeightMultiple = 1.25
                aside.paragraphSpacing = 0
                aside.paragraphSpacingBefore = 0
                result.addAttribute(.paragraphStyle, value: aside, range: span.range)

            case .horizontalRule:
                break
            }
        }
        drawTables(into: result, document: document, style: style)
        drawAttachments(
            into: result, document: document, style: style,
            resolveAttachment: resolveAttachment, availableWidth: availableWidth
        )
        return result
    }

    /// Rebuilds each table as a real `NSTextTable`, with rules.
    ///
    /// Not box-drawing characters, which was the first attempt: a CJK glyph in a
    /// monospaced font is 1.61× the width of an ASCII one, not 2×, because the
    /// font has no CJK and the fallback is not a multiple of its advance. A table
    /// padded by counting characters lines up perfectly in a string and not at
    /// all on screen. TextKit lays out a real table by measuring, so a column of
    /// mixed Chinese and English comes out square.
    ///
    /// Back to front, so the ranges of the tables not yet replaced stay valid.
    private static func drawTables(
        into result: NSMutableAttributedString,
        document: ReadingDocument,
        style: Style
    ) {
        let tables = document.spans.filter { $0.style == .table }
        for span in tables.sorted(by: { $0.range.location > $1.range.location }) {
            guard NSMaxRange(span.range) <= result.length else { continue }
            let source = (document.text as NSString).substring(with: span.range)
            guard let parsed = ReadingRenderer.tableRows(source) else { continue }

            guard let built = table(parsed.rows, headerRows: parsed.headerRows, style: style)
            else { continue }
            result.replaceCharacters(in: span.range, with: built)
        }
    }

    #if os(macOS)
    /// A real `NSTextTable`: TextKit measures the columns and draws the rules.
    private static func table(
        _ rows: [[String]], headerRows: Int, style: Style
    ) -> NSAttributedString? {
        let table = NSTextTable()
        table.numberOfColumns = rows.first?.count ?? 0
        table.layoutAlgorithm = .automaticLayoutAlgorithm
        table.collapsesBorders = true
        guard table.numberOfColumns > 0 else { return nil }

        let built = NSMutableAttributedString()
        for (rowIndex, row) in rows.enumerated() {
            for (columnIndex, cell) in row.enumerated() {
                let block = NSTextTableBlock(
                    table: table, startingRow: rowIndex, rowSpan: 1,
                    startingColumn: columnIndex, columnSpan: 1
                )
                block.setBorderColor(style.palette.divider.platformColor)
                block.setWidth(1, type: .absoluteValueType, for: .border)
                block.setWidth(6, type: .absoluteValueType, for: .padding)

                let paragraph = NSMutableParagraphStyle()
                paragraph.textBlocks = [block]
                paragraph.paragraphSpacing = 0
                paragraph.paragraphSpacingBefore = 0

                // The newline is what ends a cell; TextKit needs one per cell.
                built.append(NSAttributedString(string: cell + "\n", attributes: [
                    .font: style.typography.editorFont.platformFont(
                        size: style.typography.editorFontSize,
                        weight: rowIndex < headerRows ? .semibold : .regular),
                    .foregroundColor: style.palette.text.platformColor,
                    .paragraphStyle: paragraph,
                ]))
            }
        }
        return built
    }
    #else
    /// UIKit has no `NSTextTable`, so the columns are held apart by tab stops
    /// and separated by a rule character.
    ///
    /// The stops are placed by *measuring* each cell, not by counting its
    /// characters — the same reason the Mac side uses a real table. A vertical
    /// bar between columns and a rule under the header is not a drawn table, but
    /// it is a table with lines in it, and it is square.
    private static func table(
        _ rows: [[String]], headerRows: Int, style: Style
    ) -> NSAttributedString? {
        let columns = rows.first?.count ?? 0
        guard columns > 0 else { return nil }

        let body = style.typography.editorFont.platformFont(size: style.typography.editorFontSize)
        let header = style.typography.editorFont.platformFont(
            size: style.typography.editorFontSize, weight: .semibold)

        func width(_ text: String, _ font: PlatformFont) -> CGFloat {
            (text as NSString).size(withAttributes: [.font: font]).width
        }

        var widths = [CGFloat](repeating: 0, count: columns)
        for (rowIndex, row) in rows.enumerated() {
            for (columnIndex, cell) in row.enumerated() where columnIndex < columns {
                widths[columnIndex] = max(widths[columnIndex],
                                          width(cell, rowIndex < headerRows ? header : body))
            }
        }

        let gutter: CGFloat = 18
        var stops: [NSTextTab] = []
        var x: CGFloat = 0
        for columnWidth in widths.dropLast() {
            x += columnWidth + gutter
            stops.append(NSTextTab(textAlignment: .left, location: x, options: [:]))
        }

        let paragraph = NSMutableParagraphStyle()
        paragraph.tabStops = stops
        paragraph.defaultTabInterval = 40
        paragraph.paragraphSpacing = 0
        paragraph.paragraphSpacingBefore = 0

        let built = NSMutableAttributedString()
        for (rowIndex, row) in rows.enumerated() {
            let isHeader = rowIndex < headerRows
            built.append(NSAttributedString(
                string: row.joined(separator: "\t") + "\n",
                attributes: [
                    .font: isHeader ? header : body,
                    .foregroundColor: style.palette.text.platformColor,
                    .paragraphStyle: paragraph,
                ]
            ))
            if isHeader, rowIndex == headerRows - 1 {
                // A rule under the header, as wide as the widest row.
                let total = widths.reduce(0, +) + gutter * CGFloat(columns - 1)
                let dashes = max(4, Int(total / max(1, width("─", body))))
                built.append(NSAttributedString(
                    string: String(repeating: "─", count: dashes) + "\n",
                    attributes: [
                        .font: body,
                        .foregroundColor: style.palette.divider.platformColor,
                        .paragraphStyle: paragraph,
                    ]
                ))
            }
        }
        return built
    }
    #endif

    /// Swaps embeds, formulas and Mermaid blocks for the pictures of themselves.
    ///
    /// Back to front, so the ranges of the ones not yet replaced stay valid, and
    /// each one silently leaves its text alone when the picture is not available:
    /// the caches answer nil while they are still working, and a note that shows
    /// a file name until the thumbnail arrives is better than one that shows a
    /// gap.
    private static func drawAttachments(
        into result: NSMutableAttributedString,
        document: ReadingDocument,
        style: Style,
        resolveAttachment: (String) -> URL?,
        availableWidth: CGFloat
    ) {
        struct Replacement {
            let range: NSRange
            let image: PlatformImage
        }

        var replacements: [Replacement] = []
        for span in document.spans {
            guard NSMaxRange(span.range) <= result.length else { continue }
            let text = (document.text as NSString).substring(with: span.range)

            let image: PlatformImage?
            switch span.style {
            case .embed(let target):
                image = resolveAttachment(target).flatMap {
                    AttachmentImageCache.shared.image(for: $0, maxWidth: availableWidth)
                }
            case .math(let display):
                image = MathRenderer.shared.image(
                    latex: text,
                    fontSize: style.typography.editorFontSize,
                    isDisplay: display,
                    colour: style.palette.text.platformColor
                )
            case .codeBlock(let language) where language?.lowercased() == "mermaid":
                image = MermaidRenderer.shared.image(for: text, isDark: style.isDark)
            default:
                continue
            }
            guard let image else { continue }
            replacements.append(Replacement(range: span.range, image: image))
        }

        for replacement in replacements.sorted(by: { $0.range.location > $1.range.location }) {
            let attachment = NSTextAttachment()
            attachment.image = replacement.image
            attachment.bounds = CGRect(origin: .zero, size: replacement.image.size)
            let attributed = NSMutableAttributedString(attachment: attachment)
            // Attachments sit on their own line, centred, the way live preview
            // draws a block image.
            let centred = NSMutableParagraphStyle()
            centred.alignment = .center
            centred.paragraphSpacing = style.typography.paragraphSpacing
            attributed.addAttribute(
                .paragraphStyle, value: centred,
                range: NSRange(location: 0, length: attributed.length)
            )
            result.replaceCharacters(in: replacement.range, with: attributed)
        }
    }

    private static func bolded(_ font: PlatformFont) -> PlatformFont {
        #if os(macOS)
        NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
        #else
        font.fontDescriptor.withSymbolicTraits(.traitBold).map { UIFont(descriptor: $0, size: 0) } ?? font
        #endif
    }

    private static func italicised(_ font: PlatformFont) -> PlatformFont {
        #if os(macOS)
        NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
        #else
        font.fontDescriptor.withSymbolicTraits(.traitItalic).map { UIFont(descriptor: $0, size: 0) } ?? font
        #endif
    }
}

#if os(macOS)
/// A read-only, selectable text view. Selectable because reading a note and
/// wanting to quote a line from it is the same activity.
private struct ReadingTextView: NSViewRepresentable {
    let document: ReadingDocument
    let style: Style
    let resolveAttachment: (String) -> URL?
    let resolveVaultPath: (String) -> URL?
    let actions: EditorActions
    /// Changes when a Mermaid diagram finishes, so SwiftUI runs `updateNSView`.
    let generation: Int

    func makeNSView(context: Context) -> NSScrollView {
        // Built by hand rather than by `NSTextView.scrollableTextView()`, which
        // returns the base class and cannot be asked for a subclass. Same
        // arrangement the editor uses.
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.autohidesScrollers = true

        let textView = ReadingNSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainerInset = NSSize(width: 24, height: 32)

        scroll.documentView = textView
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? ReadingNSTextView else { return }
        textView.actions = actions

        // Centred and capped, the same measure the editor uses — the readable
        // line width is a typography setting, not an editor one.
        let available = scroll.contentSize.width
        let measure = style.typography.isReadableLineWidthEnabled
            ? min(available - 48, style.typography.readableLineWidth)
            : available - 48
        textView.textContainerInset = NSSize(width: max(24, (available - measure) / 2), height: 32)

        // Typeset here rather than in `body`, because the measure a picture is
        // scaled to is only known once the view has a width.
        textView.textStorage?.setAttributedString(ReadingTypesetter.attributed(
            document, style: style,
            resolveAttachment: resolveAttachment,
            resolveVaultPath: resolveVaultPath,
            availableWidth: max(120, measure)
        ))
        textView.selectedTextAttributes = [.backgroundColor: style.palette.selection.platformColor]
    }
}
#else
private struct ReadingTextView: UIViewRepresentable {
    let document: ReadingDocument
    let style: Style
    let resolveAttachment: (String) -> URL?
    let resolveVaultPath: (String) -> URL?
    let actions: EditorActions
    let generation: Int

    func makeUIView(context: Context) -> UITextView {
        let textView = ReadingUITextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.backgroundColor = .clear
        textView.textContainerInset = UIEdgeInsets(top: 24, left: 16, bottom: 24, right: 16)
        // A tap recogniser rather than UITextView's own link handling: the
        // destinations here are vault files and wikilinks carried on custom
        // attributes, not the `.link` URLs UIKit knows how to follow.
        let tap = UITapGestureRecognizer(target: textView, action: #selector(ReadingUITextView.handleTap(_:)))
        textView.addGestureRecognizer(tap)
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        (textView as? ReadingUITextView)?.actions = actions
        let measure = max(120, textView.bounds.width - 32)
        textView.attributedText = ReadingTypesetter.attributed(
            document, style: style,
            resolveAttachment: resolveAttachment,
            resolveVaultPath: resolveVaultPath,
            availableWidth: measure
        )
    }
}
#endif


#if os(macOS)
/// A read-only text view whose links can be followed.
///
/// Reading mode coloured links and did nothing with a click — wikilinks
/// included, not only the paths that prompted this. Following a link meant
/// switching back to live preview first, which makes reading mode the one place
/// a knowledge base cannot be navigated.
///
/// The activation logic is not duplicated here: the typesetter marks links with
/// the same `.inkstoneVaultFile` / `.inkstoneWikiLink` / `.inkstoneLinkDestination`
/// attributes the editor uses, so both modes dispatch on the same three keys.
private final class ReadingNSTextView: NSTextView {
    var actions = EditorActions()

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let index = characterIndexForInsertion(at: point)
        if !event.modifierFlags.contains(.option), follow(at: index) { return }
        super.mouseDown(with: event)
    }

    /// The pointer becomes a hand over a link, which is how a reader can tell
    /// there is one without clicking to find out.
    override func resetCursorRects() {
        super.resetCursorRects()
        guard let storage = textStorage, let layoutManager, let container = textContainer
        else { return }
        let visible = visibleRect
        let glyphs = layoutManager.glyphRange(forBoundingRect: visible, in: container)
        let characters = layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        guard characters.length > 0 else { return }

        storage.enumerateAttributes(in: characters) { attributes, range, _ in
            guard attributes[.inkstoneVaultFile] != nil
                    || attributes[.inkstoneWikiLink] != nil
                    || attributes[.inkstoneLinkDestination] != nil
            else { return }
            let glyphRange = layoutManager.glyphRange(forCharacterRange: range,
                                                      actualCharacterRange: nil)
            layoutManager.enumerateEnclosingRects(
                forGlyphRange: glyphRange,
                withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                in: container
            ) { rect, _ in
                var rect = rect
                rect.origin.x += self.textContainerOrigin.x
                rect.origin.y += self.textContainerOrigin.y
                self.addCursorRect(rect, cursor: .pointingHand)
            }
        }
    }

    private func follow(at index: Int) -> Bool {
        guard let storage = textStorage, index >= 0, index < storage.length else { return false }
        let attributes = storage.attributes(at: index, effectiveRange: nil)
        if let file = attributes[.inkstoneVaultFile] as? URL {
            actions.openVaultFile(file)
            return true
        }
        if let link = attributes[.inkstoneWikiLink] as? WikiLink {
            actions.followWikiLink(link)
            return true
        }
        if let destination = attributes[.inkstoneLinkDestination] as? String,
           destination.contains("://"), let url = URL(string: destination) {
            actions.openExternal(url)
            return true
        }
        return false
    }
}
#else
/// The same, for UIKit. See the macOS version for why this exists.
private final class ReadingUITextView: UITextView {
    var actions = EditorActions()

    @objc func handleTap(_ recogniser: UITapGestureRecognizer) {
        var point = recogniser.location(in: self)
        point.x -= textContainerInset.left
        point.y -= textContainerInset.top
        let index = layoutManager.characterIndex(for: point, in: textContainer,
                                                 fractionOfDistanceBetweenInsertionPoints: nil)
        guard index >= 0, index < textStorage.length else { return }
        let attributes = textStorage.attributes(at: index, effectiveRange: nil)
        if let file = attributes[.inkstoneVaultFile] as? URL {
            actions.openVaultFile(file)
        } else if let link = attributes[.inkstoneWikiLink] as? WikiLink {
            actions.followWikiLink(link)
        } else if let destination = attributes[.inkstoneLinkDestination] as? String,
                  destination.contains("://"), let url = URL(string: destination) {
            actions.openExternal(url)
        }
    }
}
#endif
