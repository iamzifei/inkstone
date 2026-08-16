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

    var body: some View {
        TextViewRepresentable(text: $text, style: style, mode: mode, actions: actions)
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
    /// Guards against the re-entrant highlight → didChange → highlight loop.
    var isApplyingAttributes = false

    init(text: Binding<String>, style: Style, mode: EditorMode, actions: EditorActions) {
        self.text = text
        self.style = style
        self.mode = mode
        self.actions = actions
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

    /// Paints inline attachment images into the space the highlighter reserved.
    ///
    /// See `MarkdownHighlighter.inlineImage` for why this is drawn by hand rather
    /// than with `NSTextAttachment`: the layout manager only renders attachments
    /// for the U+FFFC character, and adding one to the note's text would change
    /// the file on disk.
    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard let storage = textStorage, let layoutManager, let container = textContainer else { return }

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
            let target = NSRect(
                x: lineRect.minX,
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
            // Sit the dot on the text's optical centre, not the line box's. With
            // a line-height multiple above 1 the box is much taller than the
            // glyphs, so centring on it floats the bullet above the words.
            let font = storage.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont
            let baseline = markerRect.minY
                + layoutManager.location(forGlyphAt: glyphRange.location).y
            let centre = baseline - (font?.xHeight ?? 8) / 2
            let dot = NSRect(
                x: markerRect.minX,
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
                let x = origin.x + CGFloat(level) * MarkdownHighlighter.quoteIndent + 4
                NSRect(x: x, y: lineRect.minY, width: 2, height: lineRect.height).fill()
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

    func makeCoordinator() -> MacCoordinator {
        MacCoordinator(text: $text, style: style, mode: mode, actions: actions)
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
        textView.isContinuousSpellCheckingEnabled = true
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
        scrollView.postsFrameChangedNotifications = true
        context.coordinator.frameObserver = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification,
            object: scrollView,
            queue: .main
        ) { [weak coordinator = context.coordinator] _ in
            MainActor.assumeIsolated { coordinator?.updateInsets() }
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
            || coordinator.mode != mode {
            coordinator.style = style
            coordinator.mode = mode
            coordinator.applyStyle()
            coordinator.rehighlight()
        }
    }

    @MainActor
    final class MacCoordinator: EditorCoordinator, NSTextViewDelegate {
        weak var textView: InkstoneTextView?
        /// Token for the scroll view's frame-change observation; removed on
        /// deinit so a closed tab does not keep re-laying-out a dead editor.
        ///
        /// `nonisolated(unsafe)` because `deinit` runs outside the main actor and
        /// cannot touch an isolated property. Safe in practice: it is only ever
        /// written once during `makeNSView` on the main actor, and only read
        /// again when the coordinator is being torn down.
        nonisolated(unsafe) var frameObserver: (any NSObjectProtocol)?

        deinit {
            if let frameObserver { NotificationCenter.default.removeObserver(frameObserver) }
        }

        func applyStyle() {
            guard let textView else { return }
            textView.insertionPointColor = style.palette.accent.platformColor
            textView.selectedTextAttributes = [
                .backgroundColor: style.palette.selection.platformColor
            ]
            textView.isContinuousSpellCheckingEnabled = mode != .reading

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

        func rehighlight() {
            guard let textView, let storage = textView.textStorage else { return }
            isApplyingAttributes = true
            defer { isApplyingAttributes = false }
            let caretRange = caretLineRange(in: storage.string as NSString, selection: textView.selectedRange())
            highlighter.highlight(storage, caretLineRange: caretRange)
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

    func makeCoordinator() -> PhoneCoordinator {
        PhoneCoordinator(text: $text, style: style, mode: mode, actions: actions)
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
            || coordinator.mode != mode {
            coordinator.style = style
            coordinator.mode = mode
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
