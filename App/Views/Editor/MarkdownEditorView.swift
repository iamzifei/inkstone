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
        MarkdownHighlighter(style: style, mode: mode)
    }

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
            textView.isContinuousSpellCheckingEnabled = true
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
