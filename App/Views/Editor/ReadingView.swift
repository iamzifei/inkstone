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
            document: ReadingRenderer.render(markdown),
            style: style,
            resolveAttachment: resolveAttachment,
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
            case .link, .embed:
                result.addAttribute(.foregroundColor, value: palette.link.platformColor, range: span.range)

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
                // Same reason as a code block: one paragraph per row.
                let rows = NSMutableParagraphStyle()
                rows.lineHeightMultiple = 1.2
                rows.paragraphSpacing = 0
                rows.paragraphSpacingBefore = 0
                result.addAttribute(.paragraphStyle, value: rows, range: span.range)
                result.addAttribute(
                    .font,
                    value: typography.codeFont.platformFont(size: typography.codeFontSize),
                    range: span.range
                )

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
        drawAttachments(
            into: result, document: document, style: style,
            resolveAttachment: resolveAttachment, availableWidth: availableWidth
        )
        return result
    }

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
    /// Changes when a Mermaid diagram finishes, so SwiftUI runs `updateNSView`.
    let generation: Int

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        guard let textView = scroll.documentView as? NSTextView else { return scroll }
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        scroll.drawsBackground = false
        textView.textContainerInset = NSSize(width: 24, height: 32)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? NSTextView else { return }

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
    let generation: Int

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.backgroundColor = .clear
        textView.textContainerInset = UIEdgeInsets(top: 24, left: 16, bottom: 24, right: 16)
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        let measure = max(120, textView.bounds.width - 32)
        textView.attributedText = ReadingTypesetter.attributed(
            document, style: style,
            resolveAttachment: resolveAttachment,
            availableWidth: measure
        )
    }
}
#endif
