import Foundation
import InkstoneCore

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Renders an embedded note into a picture the editor can place.
///
/// `![[Note]]` has to show the note's *content*, and that content is not in the
/// buffer — the buffer is this file. So it takes the same route every other
/// replaced construct takes: conceal the source, reserve the height, draw into
/// the gap. Mermaid diagrams, display formulas and `[TOC]` all work this way.
///
/// The picture is produced by running the real highlighter and the real renderer
/// over the embedded text, in a layout manager of their own. Drawing the
/// attributed string alone would lose everything the renderer paints by hand —
/// bullets, checkboxes, code panels, table rules — which is most of what makes
/// an embed look like the note it came from.
@MainActor
final class TransclusionRenderer {
    static let shared = TransclusionRenderer()

    private struct Key: Hashable {
        let text: String
        let width: CGFloat
        let isDark: Bool
        let fontSize: Double
    }

    private var cache: [Key: PlatformImage] = [:]

    /// A rendered embed, or nil when there is nothing to show.
    func image(for text: String, style: Style, width: CGFloat) -> PlatformImage? {
        #if DEBUG
        func trace(_ why: String) {
            if ProcessInfo.processInfo.environment["INKSTONE_EMBED_TRACE"] != nil {
                FileHandle.standardError.write(Data("[render] \(why)\n".utf8))
            }
        }
        #else
        func trace(_ why: String) {}
        #endif

        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty, width > 40 else {
            trace("empty body or width \(width)")
            return nil
        }

        let key = Key(
            text: body, width: width.rounded(),
            isDark: style.isDark, fontSize: style.typography.editorFontSize
        )
        if let cached = cache[key] { return cached }

        let storage = NSTextStorage(string: NoteSlice.strippingAnchor(body))
        // No note resolver on the inner highlighter, which is what stops an embed
        // of an embed from recursing — and a note that embeds itself from hanging
        // the editor. A nested embed renders as a link, one level deep.
        var highlighter = MarkdownHighlighter(style: style, mode: .reading)
        highlighter.availableWidth = width
        highlighter.highlight(storage, caretLineRange: nil)

        let container = NSTextContainer(size: CGSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        let layoutManager = NSLayoutManager()
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)
        layoutManager.ensureLayout(for: container)

        let used = layoutManager.usedRect(for: container)
        let size = CGSize(width: width, height: ceil(used.height))
        trace("laid out \(body.count) chars at width \(width) → height \(size.height)")
        guard size.height > 1, size.height < 4000 else {
            trace("height \(size.height) rejected")
            return nil
        }

        let image = draw(size: size) {
            EditorRenderer(
                storage: storage, layoutManager: layoutManager, container: container,
                origin: .zero, style: style
            ).draw(in: CGRect(origin: .zero, size: size))
            let glyphs = layoutManager.glyphRange(for: container)
            layoutManager.drawBackground(forGlyphRange: glyphs, at: .zero)
            layoutManager.drawGlyphs(forGlyphRange: glyphs, at: .zero)
        }

        // Bounded: a vault of many embeds should not grow this without limit.
        if cache.count > 64 { cache.removeAll() }
        cache[key] = image
        return image
    }

    /// Thrown away when the theme or the fonts change, since every entry is
    /// drawn in them.
    func invalidate() { cache.removeAll() }

    private func draw(size: CGSize, _ body: () -> Void) -> PlatformImage {
        #if os(macOS)
        let image = NSImage(size: size)
        // Flipped, because `NSTextView` is: the renderer's geometry assumes it,
        // and an unflipped context draws every hand-painted mark upside down.
        image.lockFocusFlipped(true)
        body()
        image.unlockFocus()
        return image
        #else
        return UIGraphicsImageRenderer(size: size).image { _ in body() }
        #endif
    }
}
