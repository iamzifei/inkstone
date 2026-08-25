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
    /// Resolves `![[Note]]` — and `![[Note#Heading]]`, `![[Note#^block]]` — to
    /// the text it should show. Nil when the note or the fragment is not there,
    /// which is what leaves the embed styled as an unresolved link.
    var resolveNoteEmbed: (WikiLink) -> String? = { _ in nil }
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
    /// Show a note's frontmatter as a properties table rather than hiding it.
    var showProperties: Bool = true
    /// A range to scroll into view, set by the outline pane.
    var reveal: Workspace.RevealTarget?
    /// Changes when the vault index is rebuilt, so link resolution can be redone.
    var indexGeneration: Int = 0

    var body: some View {
        TextViewRepresentable(
            text: $text, style: style, mode: mode, actions: actions,
            spellCheck: spellCheck, showProperties: showProperties,
            reveal: reveal, indexGeneration: indexGeneration
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
    var showProperties: Bool
    /// Guards against the re-entrant highlight → didChange → highlight loop.
    var isApplyingAttributes = false

    init(
        text: Binding<String>,
        style: Style,
        mode: EditorMode,
        actions: EditorActions,
        spellCheck: Bool,
        showProperties: Bool
    ) {
        self.text = text
        self.style = style
        self.mode = mode
        self.actions = actions
        self.spellCheck = spellCheck
        self.showProperties = showProperties
    }

    var highlighter: MarkdownHighlighter {
        var highlighter = MarkdownHighlighter(style: style, mode: mode)
        highlighter.resolveAttachment = actions.resolveAttachment
        highlighter.resolveNoteEmbed = actions.resolveNoteEmbed
        highlighter.availableWidth = inlineImageWidth
        highlighter.showProperties = showProperties
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

    /// The index generation the current attributes were styled against.
    private var styledIndexGeneration = 0

    /// Whether the index has changed since the last pass, and records the new
    /// generation so it is only acted on once.
    func consumeIndexGeneration(_ generation: Int) -> Bool {
        guard generation != styledIndexGeneration else { return false }
        styledIndexGeneration = generation
        return true
    }

    /// Whether the caret has moved to a different line since the last pass.
    ///
    /// The decision itself lives in `InkstoneCore.CaretLineTracker`, where it is
    /// tested; this is only the wiring.
    var caretTracker = CaretLineTracker()

    /// Whether a selection change needs a new highlight pass.
    func selectionNeedsRehighlight(_ caret: NSRange?) -> Bool {
        #if DEBUG
        // The pre-guard behaviour, for measuring against in the same binary.
        if ProcessInfo.processInfo.environment["INKSTONE_NO_SELECTION_GUARD"] != nil { return true }
        #endif
        return caretTracker.needsPass(caretLine: caret)
    }

    /// The reveal request already acted on, so an unrelated SwiftUI update does
    /// not scroll the reader back to a heading they have since scrolled away from.
    private var handledRevealToken: Int?

    /// Scrolls `range` into view and puts the caret at its start.
    ///
    /// Clamped to the current text: the ranges come from the index, which is
    /// rebuilt on save, so a note with unsaved edits can hand back a range that
    /// is past the end of what is on screen.
    func applyReveal(_ target: Workspace.RevealTarget?, to textView: PlatformTextView) {
        guard let target, handledRevealToken != target.token else { return }
        handledRevealToken = target.token

        let length = (textView.inkstoneText as NSString).length
        guard target.range.location < length else { return }
        let range = NSRange(
            location: target.range.location,
            length: min(target.range.length, length - target.range.location)
        )
        // No explicit re-highlight: moving the caret posts a selection change,
        // and `CaretLineTracker` decides from there whether the pass is needed.
        textView.inkstoneReveal(range)
    }

    /// Paragraph range containing the caret, so live preview can reveal syntax
    /// on the line being edited.
    func caretLineRange(in string: NSString, selection: NSRange) -> NSRange? {
        guard mode == .livePreview else { return nil }
        guard selection.location <= string.length else { return nil }
        return string.paragraphRange(for: NSRange(location: selection.location, length: 0))
    }

    /// Copies a code block or table to the clipboard, without its fences.
    ///
    /// The fences are markup, not content: pasting ``` into a terminal is never
    /// what the button was pressed for.
    func copyBlock(range: NSRange, in storage: NSTextStorage) -> Bool {
        let source = storage.string as NSString
        guard range.location >= 0, range.location + range.length <= source.length else { return false }

        let body = source.substring(with: range)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                return !(trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~"))
            }
            .joined(separator: "\n")
            .trimmingCharacters(in: .newlines)
        guard !body.isEmpty else { return false }

        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(body, forType: .string)
        #else
        UIPasteboard.general.string = body
        #endif
        return true
    }

    /// Ticks or unticks the task whose marker is `range`.
    ///
    /// The state lives in the source text and nowhere else, so this is a text
    /// edit, written through the binding so it saves and re-highlights like any
    /// other. The string work itself is `TaskMarker`, which is tested.
    ///
    /// - Returns: whether a task was found and toggled.
    func toggleTask(markerAt range: NSRange, in storage: NSTextStorage) -> Bool {
        guard let updated = TaskMarker.toggled(in: storage.string, markerRange: range) else {
            return false
        }
        text.wrappedValue = updated
        return true
    }

    /// Folds or unfolds the callout whose header is `range`.
    ///
    /// A text edit, like ticking a checkbox: the state lives in the header's
    /// `+`/`-` and nowhere else, so it survives editing, reindexing and being
    /// opened on another device. See `CalloutMarker` for why a view-only fold
    /// would need an identity a range cannot give it.
    ///
    /// - Returns: whether a callout was found and toggled.
    func toggleCallout(headerAt range: NSRange, in storage: NSTextStorage) -> Bool {
        guard let updated = CalloutMarker.toggled(in: storage.string, headerRange: range) else {
            return false
        }
        text.wrappedValue = updated
        return true
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
/// How tall the caret and the selection highlight should be on a given line.
///
/// Neither should be the height of the line *fragment*. That is the line box:
/// an explicit 1.6x line height plus, at the end of a paragraph, its
/// `paragraphSpacing` — 29.6pt around 18.8pt of text on a list item. Painting
/// either to that box makes both stand conspicuously taller than the words and
/// the checkbox beside them, and makes a task line's highlight taller than a
/// body line's for no reason a reader can see.
///
/// Nor should they be the glyph height alone, which looks stunted against that
/// leading. Half the leading sits between the two, and — more importantly — is
/// the *same* answer for the caret and the selection, which is what stops them
/// disagreeing with each other.
enum CaretMetrics {

    /// The height, and how far its top sits above the text's baseline.
    ///
    /// Both are needed together: the extra space an explicit line height buys is
    /// added almost entirely *above* the glyphs — measured at 7.1pt above and
    /// none below on body text — so anything centred on the line fragment lands
    /// too high. The baseline is the only stable anchor.
    static func metrics(in storage: NSTextStorage, at location: Int) -> (height: CGFloat, aboveBaseline: CGFloat)? {
        guard storage.length > 0 else { return nil }
        let location = min(max(0, location), storage.length - 1)

        guard let style = storage.attribute(.paragraphStyle, at: location, effectiveRange: nil)
            as? NSParagraphStyle, style.maximumLineHeight > 0 else { return nil }
        guard let font = visibleFont(in: storage, at: location) else { return nil }

        let glyphs = font.ascender - font.descender
        let height = style.maximumLineHeight > glyphs
            ? glyphs + (style.maximumLineHeight - glyphs) * 0.5
            : glyphs
        // Centre it on the glyphs: the same margin above the ascender as below
        // the descender.
        return (height, font.ascender + (height - glyphs) / 2)
    }

    static func height(in storage: NSTextStorage, at location: Int) -> CGFloat? {
        metrics(in: storage, at: location)?.height
    }

    /// The font of the first character on the line that is actually drawn.
    ///
    /// A heading or task line begins with a marker collapsed to 0.01pt, whose
    /// metrics describe nothing on screen; measuring it would size the caret to
    /// a hair.
    private static func visibleFont(in storage: NSTextStorage, at location: Int) -> NSFont? {
        let line = (storage.string as NSString).lineRange(for: NSRange(location: location, length: 0))
        var probe = line.location
        while probe < NSMaxRange(line), probe < storage.length {
            if let font = storage.attribute(.font, at: probe, effectiveRange: nil) as? NSFont,
               font.pointSize >= 1 {
                return font
            }
            probe += 1
        }

        // An empty task line — "- [ ] " and nothing else — has no visible
        // character at all, and its collapsed marker would measure 0.01pt and
        // paint a speck. Borrow the nearest real font in the document instead.
        var back = line.location - 1
        var forward = NSMaxRange(line)
        while back >= 0 || forward < storage.length {
            if back >= 0,
               let font = storage.attribute(.font, at: back, effectiveRange: nil) as? NSFont,
               font.pointSize >= 1 { return font }
            if forward < storage.length,
               let font = storage.attribute(.font, at: forward, effectiveRange: nil) as? NSFont,
               font.pointSize >= 1 { return font }
            back -= 1
            forward += 1
        }
        return nil
    }
}

/// Draws the selection at the height of the text rather than of the line box.
final class InkstoneLayoutManager: NSLayoutManager {

    override func fillBackgroundRectArray(
        _ rectArray: UnsafePointer<NSRect>,
        count: Int,
        forCharacterRange charRange: NSRange,
        color: NSColor
    ) {
        guard let storage = textStorage, let container = textContainers.first else {
            super.fillBackgroundRectArray(rectArray, count: count, forCharacterRange: charRange, color: color)
            return
        }

        var rects: [NSRect] = []
        rects.reserveCapacity(count)
        for index in 0..<count {
            var rect = rectArray[index]

            // Each rect is one line of the selection, so it is measured against
            // that line rather than against the range's first character — a
            // selection spanning a heading and body text has a different answer
            // per line.
            let glyph = glyphIndex(for: CGPoint(x: rect.midX, y: rect.midY), in: container)
            let character = characterIndexForGlyph(at: glyph)
            let fragment = lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            let baseline = fragment.minY + location(forGlyphAt: glyph).y

            if let metrics = CaretMetrics.metrics(in: storage, at: character),
               metrics.height < rect.height {
                rect.origin.y = baseline - metrics.aboveBaseline
                rect.size.height = metrics.height
            }
            rects.append(rect)
        }

        rects.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            super.fillBackgroundRectArray(base, count: count, forCharacterRange: charRange, color: color)
        }
    }
}

final class InkstoneTextView: NSTextView {
    weak var coordinator: EditorCoordinator?

    /// The copy button under the pointer, and the one just pressed.
    ///
    /// Held on the view rather than in the highlighter's attributes: neither is
    /// a property of the text, and putting them in the storage would mean an
    /// attribute pass — and a document-wide re-highlight — every time the
    /// pointer crossed a corner.
    var hoveredCopyBlock: NSRange? {
        didSet { if hoveredCopyBlock != oldValue { needsDisplay = true } }
    }
    var copiedCopyBlock: NSRange? {
        didSet { if copiedCopyBlock != oldValue { needsDisplay = true } }
    }
    private var copiedResetTask: Task<Void, Never>?

    /// Marks a block as just-copied, and clears the mark shortly after.
    func flashCopied(_ range: NSRange) {
        copiedCopyBlock = range
        copiedResetTask?.cancel()
        copiedResetTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(1100))
            guard !Task.isCancelled else { return }
            self?.copiedCopyBlock = nil
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // A tracking area with `.mouseMoved` is documented to deliver without
        // this, but setting it costs nothing and removes the doubt.
        window?.acceptsMouseMovedEvents = true

        // The selection is drawn by hand, and an active one is a different
        // colour from an inactive one, so both edges of the window's key state
        // have to repaint. AppKit would have done this for its own selection.
        for observer in keyStateObservers { NotificationCenter.default.removeObserver(observer) }
        keyStateObservers = [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification]
            .map { name in
                NotificationCenter.default.addObserver(
                    forName: name, object: window, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.needsDisplay = true }
                }
            }
    }

    /// Held so they can be replaced when the view moves to another window.
    private var keyStateObservers: [any NSObjectProtocol] = []

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self
        ))
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        let point = convert(event.locationInWindow, from: nil)
        guard let coordinator, let storage = textStorage, let layoutManager,
              let container = textContainer
        else { return }
        hoveredCopyBlock = MainActor.assumeIsolated {
            EditorRenderer(
                storage: storage, layoutManager: layoutManager, container: container,
                origin: textContainerOrigin, style: coordinator.style
            ).copyButtonHit(at: point)
        }
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        hoveredCopyBlock = nil
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        // Checkboxes are hit-tested geometrically, before anything else. They
        // are painted in the gutter beside a marker collapsed to 0.01pt, so
        // there is no character under the pointer to dispatch on.
        if let coordinator, let storage = textStorage, let layoutManager,
           let container = textContainer,
           let range = MainActor.assumeIsolated({
               EditorRenderer(
                   storage: storage, layoutManager: layoutManager, container: container,
                   origin: textContainerOrigin, style: coordinator.style
               ).checkboxHit(at: point)
           }),
           MainActor.assumeIsolated({ coordinator.toggleTask(markerAt: range, in: storage) }) {
            return
        }

        if let coordinator, let storage = textStorage, let layoutManager,
           let container = textContainer,
           let range = MainActor.assumeIsolated({
               EditorRenderer(
                   storage: storage, layoutManager: layoutManager, container: container,
                   origin: textContainerOrigin, style: coordinator.style
               ).calloutDisclosureHit(at: point)
           }),
           MainActor.assumeIsolated({ coordinator.toggleCallout(headerAt: range, in: storage) }) {
            return
        }

        if let coordinator, let storage = textStorage, let layoutManager,
           let container = textContainer,
           let range = MainActor.assumeIsolated({
               EditorRenderer(
                   storage: storage, layoutManager: layoutManager, container: container,
                   origin: textContainerOrigin, style: coordinator.style
               ).copyButtonHit(at: point)
           }),
           MainActor.assumeIsolated({ coordinator.copyBlock(range: range, in: storage) }) {
            MainActor.assumeIsolated { flashCopied(range) }
            return
        }

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
        // Positioned from the baseline, by the same metric the selection uses.
        // Adjusting the rect AppKit supplies would mean trusting what its height
        // means, and the two would drift apart the moment that changed.
        if let storage = textStorage, let layoutManager,
           storage.length > 0,
           let metrics = CaretMetrics.metrics(in: storage, at: selectedRange().location) {
            let location = min(selectedRange().location, storage.length - 1)
            let glyph = layoutManager.glyphIndexForCharacter(at: location)
            if glyph < layoutManager.numberOfGlyphs {
                let fragment = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
                let baseline = fragment.minY + layoutManager.location(forGlyphAt: glyph).y
                rect.origin.y = baseline - metrics.aboveBaseline + textContainerOrigin.y
                rect.size.height = metrics.height
            }
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
    /// Covers the tallest caret extension in use. Body text gains 3.4pt of
    /// height, so 2pt each way; 3 leaves a margin. This widens *every*
    /// invalidation, not only the caret's, so it stays at what the measurements
    /// call for rather than a comfortable overestimate.
    private static let caretOvershoot: CGFloat = 3

    /// The height of the line fragment the caret currently sits in.

    /// Paints inline attachment images into the space the highlighter reserved.
    ///
    /// See `MarkdownHighlighter.inlineImage` for why this is drawn by hand rather
    /// than with `NSTextAttachment`: the layout manager only renders attachments
    /// for the U+FFFC character, and adding one to the note's text would change
    /// the file on disk.
    /// Whether the selection is the *active* one: this view is being typed in,
    /// in the window the user is looking at. An inactive selection is still
    /// drawn, in a muted colour, as everywhere else on the platform.
    private var isSelectionVisible: Bool {
        window?.isKeyWindow == true && window?.firstResponder === self
    }

    /// The selection is drawn by hand, so the view has to be told to repaint
    /// when it moves — AppKit only invalidates what *its* own selection drawing
    /// would have covered, which is nothing now.
    override func setSelectedRanges(
        _ ranges: [NSValue],
        affinity: NSSelectionAffinity,
        stillSelecting: Bool
    ) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        needsDisplay = true
    }

    override func becomeFirstResponder() -> Bool {
        defer { needsDisplay = true }
        return super.becomeFirstResponder()
    }

    override func resignFirstResponder() -> Bool {
        defer { needsDisplay = true }
        return super.resignFirstResponder()
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard let storage = textStorage, let layoutManager, let container = textContainer else { return }

        let origin = textContainerOrigin
        guard let coordinator else { return }
        EditorRenderer(
            storage: storage,
            layoutManager: layoutManager,
            container: container,
            origin: textContainerOrigin,
            style: MainActor.assumeIsolated { coordinator.style },
            hoveredCopyBlock: hoveredCopyBlock,
            copiedCopyBlock: copiedCopyBlock,
            selectedRange: selectedRange(),
            isSelectionActive: isSelectionVisible
        ).draw(in: rect)
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

        // And over the copy button, which had no cursor change, no hover state
        // and no confirmation — three separate reasons to think it was a picture
        // rather than a control.
        if let coordinator {
            let renderer = MainActor.assumeIsolated {
                EditorRenderer(
                    storage: storage, layoutManager: layoutManager, container: container,
                    origin: textContainerOrigin, style: coordinator.style
                )
            }
            storage.enumerateAttribute(
                .inkstoneBlockFill, in: NSRange(location: 0, length: storage.length)
            ) { value, range, _ in
                guard value != nil,
                      let button = MainActor.assumeIsolated({ renderer.copyButtonRect(for: range) })
                else { return }
                addCursorRect(button, cursor: .pointingHand)
            }
        }
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
    let showProperties: Bool
    let reveal: Workspace.RevealTarget?
    let indexGeneration: Int

    func makeCoordinator() -> MacCoordinator {
        MacCoordinator(text: $text, style: style, mode: mode, actions: actions,
                       spellCheck: spellCheck, showProperties: showProperties)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.autohidesScrollers = true

        let textView = InkstoneTextView()
        // Swap in the layout manager that draws the selection at text height.
        // Replacing it on the existing container keeps AppKit's own text stack
        // intact — building the stack by hand would mean re-wiring storage,
        // container sizing and the scroll view's tracking as well.
        textView.textContainer?.replaceLayoutManager(InkstoneLayoutManager())
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
        defer { coordinator.applyReveal(reveal, to: textView) }
        if coordinator.consumeIndexGeneration(indexGeneration) { coordinator.rehighlight() }
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
            || coordinator.spellCheck != spellCheck
            || coordinator.showProperties != showProperties {
            coordinator.style = style
            coordinator.mode = mode
            coordinator.spellCheck = spellCheck
            coordinator.showProperties = showProperties
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
            // Clear, because the selection is drawn by `EditorRenderer` instead.
            // AppKit's own is a per-glyph-run background, and in a live-preview
            // layout — where syntax markers are 0.01pt and every block has its
            // own line height — those runs came out at different heights and left
            // the selection looking like a row of disconnected bars.
            textView.selectedTextAttributes = [
                .backgroundColor: PlatformColor.clear
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
                let logAll = ProcessInfo.processInfo.environment["INKSTONE_LOG_HIGHLIGHTS"] != nil
                if ms > 8 || logAll {
                    FileHandle.standardError.write(Data(
                        "[inkstone] highlight \(storage.length) chars in \(String(format: "%.1f", ms)) ms\n".utf8
                    ))
                    let url = (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                        ?? URL(fileURLWithPath: NSTemporaryDirectory())).appending(path: "inkstone-debug.log")
                    let line = "[perf] highlight \(storage.length) chars "
                        + "\(String(format: "%.1f", ms)) ms scans=\(ScanCache.shared.scanCount)\n"
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
            caretTracker.record(caretLine: caretRange)
            highlighter.highlight(storage, caretLineRange: caretRange, visibleRange: scope)
        }

        func textDidChange(_ notification: Notification) {
            guard !isApplyingAttributes, let textView else { return }
            text.wrappedValue = textView.string
            rehighlight()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard !isApplyingAttributes, let textView, let storage = textView.textStorage else { return }
            // Live preview needs a re-run whenever the caret moves to a new line —
            // and only then. Typing fires this *as well as* `textDidChange`, so
            // without the guard every keystroke ran the pass twice.
            let caret = caretLineRange(in: storage.string as NSString, selection: textView.selectedRange())
            guard selectionNeedsRehighlight(caret) else { return }
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



/// The row of Markdown controls above the keyboard.
///
/// On a phone the syntax is the hard part: `#`, `` ` ``, `[`, `>` and `-` are
/// each two taps away on the iOS keyboard, and `[[` for a wikilink is four.
/// Typing a note is otherwise a constant round trip through the symbol plane.
@MainActor
final class MarkdownAccessoryView: UIInputView {

    /// What a button does to the text.
    private enum Action {
        /// Puts the text at the start of the line, replacing any marker already
        /// there — tapping "heading" twice should not give `## ##`.
        case linePrefix(String)
        /// Wraps the selection, or inserts the pair and puts the caret between.
        case wrap(String, String)
        case insert(String)
    }

    private struct Item {
        let symbol: String
        let label: String
        let action: Action
    }

    private static let items: [Item] = [
        Item(symbol: "number", label: "Heading", action: .linePrefix("# ")),
        Item(symbol: "list.bullet", label: "List", action: .linePrefix("- ")),
        Item(symbol: "checklist", label: "Task", action: .linePrefix("- [ ] ")),
        Item(symbol: "text.quote", label: "Quote", action: .linePrefix("> ")),
        Item(symbol: "bold", label: "Bold", action: .wrap("**", "**")),
        Item(symbol: "italic", label: "Italic", action: .wrap("*", "*")),
        Item(symbol: "chevron.left.forwardslash.chevron.right", label: "Code", action: .wrap("`", "`")),
        Item(symbol: "link", label: "Link", action: .wrap("[[", "]]")),
    ]

    /// A marker already at the start of the line, so tapping "heading" twice
    /// gives `# ` rather than `## # `.
    ///
    /// Built once: constructing it per tap would mean either a force-try or an
    /// optional to unwrap on every keystroke.
    private static let existingMarker: NSRegularExpression = {
        // Safe to force here and nowhere else: the pattern is a literal, so a
        // failure would be a programming error caught the first time this runs.
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: "^[ \\t]*(?:#{1,6} |[-*+] (?:\\[.\\] )?|> )")
    }()

    private weak var textView: UITextView?

    init(textView: UITextView, tint: UIColor) {
        self.textView = textView
        super.init(
            frame: CGRect(x: 0, y: 0, width: 0, height: 44),
            inputViewStyle: .keyboard
        )

        let stack = UIStackView()
        stack.axis = .horizontal
        stack.distribution = .fillEqually
        stack.translatesAutoresizingMaskIntoConstraints = false

        for (index, item) in Self.items.enumerated() {
            var configuration = UIButton.Configuration.plain()
            configuration.image = UIImage(systemName: item.symbol)
            let button = UIButton(configuration: configuration)
            button.tag = index
            button.tintColor = tint
            button.accessibilityLabel = item.label
            button.addTarget(self, action: #selector(tap(_:)), for: .touchUpInside)
            stack.addArrangedSubview(button)
        }

        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor, constant: 4),
            stack.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -4),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func tap(_ sender: UIButton) {
        guard let textView, Self.items.indices.contains(sender.tag) else { return }
        let item = Self.items[sender.tag]
        let text = textView.text as NSString
        let selection = textView.selectedRange

        switch item.action {
        case .linePrefix(let prefix):
            let line = text.lineRange(for: NSRange(location: selection.location, length: 0))
            let existing = text.substring(with: line)
            // Replace an existing marker rather than stacking a second one.
            let stripped = Self.existingMarker.stringByReplacingMatches(
                in: existing,
                range: NSRange(location: 0, length: (existing as NSString).length),
                withTemplate: ""
            )
            textView.replace(range: line, with: prefix + stripped)
            let moved = prefix.utf16.count - (existing.utf16.count - stripped.utf16.count)
            textView.selectedRange = NSRange(location: max(0, selection.location + moved), length: 0)

        case .wrap(let open, let close):
            if selection.length > 0 {
                let selected = text.substring(with: selection)
                textView.replace(range: selection, with: open + selected + close)
                textView.selectedRange = NSRange(
                    location: selection.location + open.utf16.count,
                    length: selection.length
                )
            } else {
                textView.replace(range: selection, with: open + close)
                textView.selectedRange = NSRange(
                    location: selection.location + open.utf16.count, length: 0
                )
            }

        case .insert(let string):
            textView.replace(range: selection, with: string)
            textView.selectedRange = NSRange(
                location: selection.location + string.utf16.count, length: 0
            )
        }
    }
}

private extension UITextView {
    /// Replaces a range and tells the delegate, so the edit saves and
    /// re-highlights like a typed one.
    func replace(range: NSRange, with string: String) {
        guard let start = position(from: beginningOfDocument, offset: range.location),
              let end = position(from: start, offset: range.length),
              let textRange = textRange(from: start, to: end)
        else { return }
        replace(textRange, withText: string)
    }
}

/// Paints the hand-drawn elements the highlighter reserved space for.
///
/// Without this, iOS collapsed a task's `- [ ] ` marker to 0.01pt exactly as
/// macOS does — and then drew nothing in its place, so checkboxes and bullets
/// were not merely unstyled but missing entirely.
///
/// `draw(_:)` rather than AppKit's `drawBackground(in:)`, which UIKit has no
/// equivalent of. The text is drawn by the layout manager afterwards, so
/// everything painted here lands behind it, which is what the fills and rules
/// need.
final class InkstonePhoneTextView: UITextView {
    /// Called on every layout pass. A closure rather than a coordinator
    /// reference because the coordinator type is nested in the representable and
    /// not nameable from here.
    var onLayout: (() -> Void)?

    /// The measure changes when the view is first given bounds, and on rotation.
    ///
    /// AppKit gets this from a frame-change notification; UIKit had nothing, so
    /// `updateInsets` ran once at setup — when the view was zero-wide — and never
    /// again. Everything scaled to the measure was left at its default: an
    /// embedded picture, and a transcluded note, drawn 680pt wide on a phone.
    override func layoutSubviews() {
        super.layoutSubviews()
        onLayout?()
    }

    /// The block whose copy button was just tapped, drawn as a tick for a
    /// moment. There is no hover on a touch screen, which makes the
    /// confirmation the only feedback there is.
    var copiedCopyBlock: NSRange? {
        didSet { if copiedCopyBlock != oldValue { setNeedsDisplay() } }
    }
    private var copiedResetTask: Task<Void, Never>?

    func flashCopied(_ range: NSRange) {
        copiedCopyBlock = range
        copiedResetTask?.cancel()
        copiedResetTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(1100))
            guard !Task.isCancelled else { return }
            self?.copiedCopyBlock = nil
        }
    }

    weak var coordinator: EditorCoordinator?

    override func draw(_ rect: CGRect) {
        super.draw(rect)

        guard let coordinator, let container = textContainer as NSTextContainer?,
              let storage = textStorage as NSTextStorage?
        else { return }
        let layoutManager = self.layoutManager

        EditorRenderer(
            storage: storage,
            layoutManager: layoutManager,
            container: container,
            // UIKit expresses the same offset as an inset rather than an origin.
            origin: CGPoint(x: textContainerInset.left, y: textContainerInset.top),
            style: MainActor.assumeIsolated { coordinator.style },
            // No hover on a touch screen; the confirmation still matters.
            copiedCopyBlock: copiedCopyBlock
        ).draw(in: rect)
    }
}

private struct TextViewRepresentable: UIViewRepresentable {
    @Binding var text: String
    let style: Style
    let mode: EditorMode
    let actions: EditorActions
    let spellCheck: Bool
    let showProperties: Bool
    let reveal: Workspace.RevealTarget?
    let indexGeneration: Int

    func makeCoordinator() -> PhoneCoordinator {
        PhoneCoordinator(text: $text, style: style, mode: mode, actions: actions,
                         spellCheck: spellCheck, showProperties: showProperties)
    }

    func makeUIView(context: Context) -> UITextView {
        // TextKit 1 deliberately: we need `layoutManager.characterIndex(for:)`
        // to hit-test link taps, which has no direct TextKit 2 equivalent that
        // works as cleanly inside a `UITextView`.
        let textView = InkstonePhoneTextView(usingTextLayoutManager: false)
        textView.coordinator = context.coordinator
        textView.delegate = context.coordinator
        textView.onLayout = { [weak coordinator = context.coordinator] in
            MainActor.assumeIsolated { coordinator?.updateInsets() }
        }
        // The hand-drawn elements sit outside the glyphs' own rects, so the text
        // view has to repaint the whole visible area rather than just the runs
        // that changed.
        textView.contentMode = .redraw
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
        //
        // `cancelsTouchesInView = false` lets the touches through, but it does
        // not stop this recogniser competing with the text view's own tap — the
        // one that places the caret and takes first responder, which is what
        // raises the keyboard. Two tap recognisers on one view do not
        // automatically both fire; a delegate saying so is what makes that true.
        tap.cancelsTouchesInView = false
        tap.delegate = context.coordinator
        textView.addGestureRecognizer(tap)

        textView.inputAccessoryView = MarkdownAccessoryView(
            textView: textView, tint: style.palette.accent.platformColor
        )

        // A Mermaid diagram renders asynchronously; when one lands, run again so
        // it replaces its source. Guarded by the renderer's cache, so this
        // settles rather than looping.
        //
        // This was set on macOS only, so on iOS the diagram rendered — the trace
        // showed a 316x73 image — and then nothing asked the editor to redraw,
        // leaving the source on screen forever.
        MermaidRenderer.shared.onRendered = { [weak coordinator = context.coordinator] in
            MainActor.assumeIsolated { coordinator?.rehighlight() }
        }

        #if DEBUG
        // Brings the keyboard up so the accessory row can be seen in a
        // screenshot; the simulator otherwise uses the Mac's keyboard and never
        // shows one.
        if ProcessInfo.processInfo.environment["INKSTONE_FOCUS_EDITOR"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                textView.becomeFirstResponder()
            }
        }
        #endif

        context.coordinator.textView = textView
        context.coordinator.applyStyle()
        context.coordinator.rehighlight()
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        let coordinator = context.coordinator
        coordinator.text = $text
        coordinator.actions = actions
        defer { coordinator.applyReveal(reveal, to: textView) }
        if coordinator.consumeIndexGeneration(indexGeneration) { coordinator.rehighlight() }

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
            || coordinator.spellCheck != spellCheck
            || coordinator.showProperties != showProperties {
            coordinator.style = style
            coordinator.mode = mode
            coordinator.spellCheck = spellCheck
            coordinator.showProperties = showProperties
            coordinator.applyStyle()
            coordinator.rehighlight()
        }
    }

    @MainActor
    final class PhoneCoordinator: EditorCoordinator, UITextViewDelegate, UIGestureRecognizerDelegate {
        weak var textView: UITextView?

        /// Our tap recogniser must not exclude the text view's own.
        nonisolated func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool {
            true
        }

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

            // The measure inline pictures are scaled to, which AppKit has always
            // set and UIKit never did — so every embedded image and every
            // transcluded note was drawn 680pt wide on a phone that is 370, and
            // ran off the side. Bucketed like the Mac's, so a rotation does not
            // re-render everything for a point or two.
            //
            // Guarded on a plausible width: this runs during layout, and it runs
            // once before the view has any bounds at all. Taking that pass at
            // face value set the measure to -32 and every transclusion silently
            // refused to render.
            guard measure > 80 else { return }
            if abs(inlineImageWidth - measure) >= 32 {
                inlineImageWidth = measure
                rehighlight()
            }
        }

        func rehighlight() {
            guard let textView else { return }
            let storage = textView.textStorage
            isApplyingAttributes = true
            defer { isApplyingAttributes = false }
            let caretRange = caretLineRange(in: storage.string as NSString, selection: textView.selectedRange)
            caretTracker.record(caretLine: caretRange)
            highlighter.highlight(storage, caretLineRange: caretRange)

            // Ask for a repaint of the hand-drawn layer.
            //
            // Changing attributes makes UIKit redraw the *text*, but it does not
            // call `draw(_:)` again, so bullets, checkboxes and inline images
            // stayed at whatever the previous pass left. A Mermaid diagram made
            // this visible: the render finished, the attribute was set, and the
            // picture never appeared because nothing repainted. AppKit does not
            // have this problem — `drawBackground(in:)` is part of the text
            // drawing itself.
            textView.setNeedsDisplay()
        }

        func textViewDidChange(_ textView: UITextView) {
            guard !isApplyingAttributes else { return }
            text.wrappedValue = textView.text
            rehighlight()
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            guard !isApplyingAttributes else { return }
            // Same guard as AppKit: only a change of caret *line* can change what
            // live preview shows. UIKit fires this while scrolling a selection
            // into view too, which made it even hotter than on the Mac.
            let caret = caretLineRange(
                in: textView.textStorage.string as NSString, selection: textView.selectedRange
            )
            guard selectionNeedsRehighlight(caret) else { return }
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
            let viewPoint = recognizer.location(in: textView)

            // Checkboxes first, and in view coordinates: they are drawn in the
            // gutter beside a marker collapsed to 0.01pt, so hit-testing by
            // character index would never land on one.
            let renderer = EditorRenderer(
                storage: storage,
                layoutManager: textView.layoutManager,
                container: textView.textContainer,
                origin: CGPoint(x: textView.textContainerInset.left,
                                y: textView.textContainerInset.top),
                style: style
            )
            if let range = renderer.checkboxHit(at: viewPoint),
               toggleTask(markerAt: range, in: storage) {
                return
            }
            if let range = renderer.calloutDisclosureHit(at: viewPoint),
               toggleCallout(headerAt: range, in: storage) {
                return
            }
            if let range = renderer.copyButtonHit(at: viewPoint),
               copyBlock(range: range, in: storage) {
                (textView as? InkstonePhoneTextView)?.flashCopied(range)
                return
            }

            var point = viewPoint
            point.x -= textView.textContainerInset.left
            point.y -= textView.textContainerInset.top
            let index = textView.layoutManager.characterIndex(
                for: point,
                in: textView.textContainer,
                fractionOfDistanceBetweenInsertionPoints: nil
            )
            // Nothing on this tap was a link, a checkbox or a button, so it was
            // a tap into the text: put the caret where it landed and take focus.
            //
            // Done here rather than left to the text view's own recogniser, so
            // that raising the keyboard does not depend on which of two
            // recognisers wins. Harmless when the text view is already first
            // responder.
            if !handleActivation(at: index, in: storage), textView.isEditable {
                textView.selectedRange = NSRange(location: index, length: 0)
                if !textView.isFirstResponder { textView.becomeFirstResponder() }
            }
        }

        private func textRange(_ textView: UITextView, _ range: NSRange) -> UITextRange {
            let start = textView.position(from: textView.beginningOfDocument, offset: range.location)!
            let end = textView.position(from: start, offset: range.length)!
            return textView.textRange(from: start, to: end)!
        }
    }
}

#endif
