import Foundation

/// Decides whether a change of selection needs the editor to re-run its
/// highlight pass.
///
/// Live preview's entire dependency on the selection is *which line the caret is
/// on*, because that is the one line whose Markdown syntax is revealed rather
/// than concealed. Moving within a line, extending a selection, clicking
/// somewhere else on the same line, or any selection change at all in source and
/// reading mode cannot alter a single attribute.
///
/// The editor used to re-highlight on every selection notification regardless.
/// On a 56KB note that was a full document scan and a full attribute pass per
/// arrow key — and, because typing posts a selection change *and* a text change,
/// twice per keystroke.
///
/// Lives here rather than in the editor coordinator so it can be tested: the
/// coordinator is `@MainActor`, wrapped around a platform text view, and has no
/// test target. This is the whole of the decision, and it is pure.
public struct CaretLineTracker: Sendable, Equatable {
    /// The caret line the last completed pass was run for. `nil` is meaningful:
    /// it is what source and reading mode always pass, and what live preview
    /// passes when the selection is out of bounds.
    private var last: NSRange?
    /// Whether any pass has been recorded. Without this the first selection
    /// change in source mode would compare `nil` against `nil` and be skipped,
    /// leaving the document unstyled.
    private var hasRecorded = false

    public init() {}

    /// Records that a highlight pass has just run for `caretLine`.
    public mutating func record(caretLine: NSRange?) {
        last = caretLine
        hasRecorded = true
    }

    /// Whether a selection change to `caretLine` requires a new pass.
    public func needsPass(caretLine: NSRange?) -> Bool {
        guard hasRecorded else { return true }
        switch (caretLine, last) {
        case (nil, nil):
            return false
        case let (new?, previous?):
            return !NSEqualRanges(new, previous)
        default:
            // One side has a caret and the other does not — the mode changed.
            return true
        }
    }
}
