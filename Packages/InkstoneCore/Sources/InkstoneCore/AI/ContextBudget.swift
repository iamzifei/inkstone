import Foundation

/// How much of an attachment fits in what is left of a context window.
///
/// Its own type because getting it wrong is silent and total: the request is
/// refused, and what a person sees is that attaching a note to the small model
/// never works. The arithmetic that failed subtracted a flat constant from the
/// window instead of measuring what the prompt already held.
public enum ContextBudget {
    /// Characters available for an attachment.
    ///
    /// - Parameters:
    ///   - window: the model's usable window, in characters.
    ///   - used: what the prompt and the conversation already occupy.
    ///   - reserve: room for the question being typed and the reply's overhead.
    ///
    /// Returns zero rather than a negative number when nothing fits, so a caller
    /// can test one condition rather than two.
    public static func allowance(window: Int, used: Int, reserve: Int) -> Int {
        max(0, window - used - reserve)
    }

    /// Whether an allowance is large enough to be worth using.
    ///
    /// Below this, attaching the opening two sentences of a note and answering
    /// about them as though they were the note is worse than saying the note
    /// did not fit.
    public static let minimumUsefulAllowance = 200

    /// Truncates text to an allowance, marking where it was cut.
    ///
    /// Returns nil when nothing useful fits, which is the caller's signal to say
    /// so rather than to attach a fragment.
    public static func fit(_ text: String, into allowance: Int, marker: String) -> String? {
        guard allowance >= minimumUsefulAllowance else { return nil }
        guard text.count > allowance else { return text }
        return String(text.prefix(allowance)) + marker
    }
}
