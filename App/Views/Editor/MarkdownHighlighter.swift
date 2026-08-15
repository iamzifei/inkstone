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
        for token in tokens {
            apply(token, to: storage, caretLineRange: caretLineRange, fullText: text as NSString)
        }

        if style.typography.cjkLatinSpacing {
            applyCJKLatinSpacing(to: storage, text: text as NSString)
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
        fullText: NSString
    ) {
        let typography = style.typography
        let palette = style.palette
        // Editing the line the caret is on always shows raw syntax.
        let isBeingEdited = mode == .source
            || (caretLineRange.map { NSIntersectionRange($0, token.range).length > 0 } ?? false)

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
            storage.addAttribute(.foregroundColor, value: palette.faintText.platformColor, range: token.range)
            setFont(typography.codeFont.platformFont(size: typography.codeFontSize), range: token.range)

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
            setFont(
                typography.editorFont.platformFont(size: typography.editorFontSize, weight: .bold),
                range: token.contentRange
            )
            styleDelimiters(delimiters(of: token), in: storage, isBeingEdited: isBeingEdited, conceal: conceal)

        case .italic:
            setFont(italicFont(size: typography.editorFontSize), range: token.contentRange)
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

        case .task(let checked):
            if checked {
                storage.addAttribute(.foregroundColor, value: palette.secondaryText.platformColor, range: token.range)
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

    private func italicFont(size: CGFloat) -> PlatformFont {
        let base = style.typography.editorFont.platformFont(size: size)
        #if os(macOS)
        return NSFontManager.shared.convert(base, toHaveTrait: .italicFontMask)
        #else
        guard let descriptor = base.fontDescriptor.withSymbolicTraits(.traitItalic) else { return base }
        return UIFont(descriptor: descriptor, size: size)
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
