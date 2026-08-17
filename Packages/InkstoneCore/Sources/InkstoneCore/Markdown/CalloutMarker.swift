import Foundation

/// Folding and unfolding a callout.
///
/// Obsidian writes the state into the header: `> [!note]-` starts collapsed,
/// `> [!note]+` starts expanded, and a bare `> [!note]` is not foldable at all.
/// Toggling therefore edits the text, the same way ticking a checkbox does —
/// which is also what keeps the feature stateless. A fold held only in the view
/// would need an identity for each callout that survives editing, and a range is
/// not one: type a word above it and every range below has moved.
public enum CalloutMarker {

    /// Flips the fold marker on the callout header at `headerRange`.
    ///
    /// A header with no marker gains `-`, because the only reason to click one
    /// that is showing its body is to put the body away.
    ///
    /// - Returns: the document with that one character changed, or nil when
    ///   `headerRange` does not hold a callout header.
    public static func toggled(in text: String, headerRange range: NSRange) -> String? {
        let source = text as NSString
        guard range.location >= 0, range.length > 0,
              NSMaxRange(range) <= source.length
        else { return nil }

        let header = source.substring(with: range)
        // The `]` of `[!type]`, which is what the marker follows.
        guard let open = header.range(of: "[!"),
              let close = header.range(of: "]", range: open.upperBound..<header.endIndex)
        else { return nil }

        let afterClose = header.distance(from: header.startIndex, to: close.upperBound)
        let markerLocation = range.location + afterClose
        let existing = markerLocation < source.length
            ? source.substring(with: NSRange(location: markerLocation, length: 1))
            : ""

        var updated = text
        switch existing {
        case "-":
            guard let swiftRange = Range(
                NSRange(location: markerLocation, length: 1), in: updated
            ) else { return nil }
            updated.replaceSubrange(swiftRange, with: "+")
        case "+":
            guard let swiftRange = Range(
                NSRange(location: markerLocation, length: 1), in: updated
            ) else { return nil }
            updated.replaceSubrange(swiftRange, with: "-")
        default:
            guard let insertion = Range(
                NSRange(location: markerLocation, length: 0), in: updated
            ) else { return nil }
            updated.replaceSubrange(insertion, with: "-")
        }
        return updated
    }
}
