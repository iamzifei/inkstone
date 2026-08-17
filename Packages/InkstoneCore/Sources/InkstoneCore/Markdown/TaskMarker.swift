import Foundation

/// Ticking and unticking a task list item.
///
/// The state of a task lives in the source text and nowhere else — `- [ ]` or
/// `- [x]` on disk — so toggling one is a text edit. Kept here rather than in
/// the editor because it is pure string work: the editor supplies a marker
/// range, this decides what the text becomes.
public enum TaskMarker {

    /// Toggles the checkbox inside the marker at `range`.
    ///
    /// - Parameters:
    ///   - text: the whole document.
    ///   - range: the marker, e.g. the `- [ ] ` at the start of a task line.
    /// - Returns: the document with that one character flipped, or nil when
    ///   `range` does not contain a checkbox.
    public static func toggled(in text: String, markerRange range: NSRange) -> String? {
        let source = text as NSString
        guard range.location >= 0,
              range.length > 0,
              range.location + range.length <= source.length
        else { return nil }

        // Find the brackets rather than assuming an offset: the indent varies
        // with nesting and the bullet may be any of `-`, `*` or `+`.
        let marker = source.substring(with: range)
        guard let open = marker.firstIndex(of: "["),
              let close = marker.firstIndex(of: "]"),
              marker.index(after: open) < close
        else { return nil }

        let stateOffset = marker.distance(from: marker.startIndex, to: marker.index(after: open))
        let stateRange = NSRange(location: range.location + stateOffset, length: 1)

        // Anything other than blank counts as done, which is what every Markdown
        // renderer does: `[x]`, `[X]` and `[✓]` are all ticked.
        let current = source.substring(with: stateRange)
        let replacement = current.trimmingCharacters(in: .whitespaces).isEmpty ? "x" : " "

        var updated = text
        guard let swiftRange = Range(stateRange, in: updated) else { return nil }
        updated.replaceSubrange(swiftRange, with: replacement)
        return updated
    }
}
