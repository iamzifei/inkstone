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
/// Not yet rendered here: math, Mermaid diagrams and image embeds, which live
/// preview does draw. They are listed as absent rather than half-drawn.
struct ReadingView: View {
    let markdown: String
    @Environment(\.style) private var style

    var body: some View {
        ReadingTextView(attributed: attributed, style: style)
            .background(style.background)
    }

    private var attributed: NSAttributedString {
        ReadingTypesetter.attributed(
            ReadingRenderer.render(markdown),
            style: style
        )
    }
}

/// Turns a `ReadingDocument` into something a text view can draw.
///
/// Split out from the view so the mapping from span to attribute is one place,
/// and so the renderer in the core stays free of fonts and colours.
enum ReadingTypesetter {
    static func attributed(_ document: ReadingDocument, style: Style) -> NSAttributedString {
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
            case .link:
                result.addAttribute(.foregroundColor, value: palette.link.platformColor, range: span.range)
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
        return result
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
    let attributed: NSAttributedString
    let style: Style

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
        textView.textStorage?.setAttributedString(attributed)
        textView.selectedTextAttributes = [.backgroundColor: style.palette.selection.platformColor]
        // Centred and capped, the same measure the editor uses — the readable
        // line width is a typography setting, not an editor one.
        let available = scroll.contentSize.width
        let measure = style.typography.isReadableLineWidthEnabled
            ? min(available - 48, style.typography.readableLineWidth)
            : available - 48
        textView.textContainerInset = NSSize(width: max(24, (available - measure) / 2), height: 32)
    }
}
#else
private struct ReadingTextView: UIViewRepresentable {
    let attributed: NSAttributedString
    let style: Style

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.backgroundColor = .clear
        textView.textContainerInset = UIEdgeInsets(top: 24, left: 16, bottom: 24, right: 16)
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        textView.attributedText = attributed
    }
}
#endif
