import Foundation

/// Re-scans only the part of a note an edit touched.
///
/// A full scan of an 88 KB note costs about 16 ms, and the editor did one per
/// keystroke. Almost every keystroke changes one paragraph; this finds the
/// changed span, widens it to whole top-level blocks (blank-line separated,
/// starting at column 0 — so a list's continuation or an indented line is never
/// read on its own), scans just that window and splices its tokens between the
/// old ones before and after it, shifted by the edit's length.
///
/// It gives up — returns nil, and the caller does a full scan — whenever the
/// window could depend on text outside it: a fence, maths block, comment,
/// HTML block or front matter in or near the edit, a reference-style link
/// definition, a token crossing the window's edge, or a window that is most
/// of the note anyway. `IncrementalScanTests` checks the result is exactly a
/// full scan's over random edits on real notes.
enum IncrementalScan {
    static func rescan(old: String, oldTokens: [SyntaxToken], new: String, scanner: SyntaxScanner) -> [SyntaxToken]? {
        let o = old as NSString, n = new as NSString
        let oldLength = o.length, newLength = n.length
        guard oldLength > 2_000 else { return nil }   // small notes: a full scan is already cheap

        // The changed span: common prefix and suffix, in UTF-16 units.
        var prefix = 0
        let limit = min(oldLength, newLength)
        while prefix < limit, o.character(at: prefix) == n.character(at: prefix) { prefix += 1 }
        var suffix = 0
        while suffix < limit - prefix,
              o.character(at: oldLength - 1 - suffix) == n.character(at: newLength - 1 - suffix) { suffix += 1 }
        let delta = newLength - oldLength

        // Widen to whole top-level blocks, in the new text.
        let start = blockStart(before: prefix, in: n)
        let newEnd = blockEnd(after: newLength - suffix, in: n)
        let oldEnd = newEnd - delta
        guard start >= 0, newEnd <= newLength, oldEnd <= oldLength, oldEnd >= start,
              newEnd - start < newLength / 2 else { return nil }

        let oldWindow = o.substring(with: NSRange(location: start, length: oldEnd - start))
        let newWindow = n.substring(with: NSRange(location: start, length: newEnd - start))
        guard isSelfContained(oldWindow), isSelfContained(newWindow) else { return nil }
        // A window starting with --- would be read as front matter on its own;
        // and a window at the very start of a note that has (or had) front
        // matter may cut it short — its blank lines look like block breaks.
        if newWindow.hasPrefix("---") || newWindow.hasPrefix("+++") { return nil }
        if start == 0, old.hasPrefix("---") || old.hasPrefix("+++") || new.hasPrefix("---") || new.hasPrefix("+++") { return nil }

        // Old tokens: those before the window, those after it; none may cross it.
        var before: [SyntaxToken] = [], after: [SyntaxToken] = []
        for token in oldTokens {
            let end = NSMaxRange(token.range)
            if end <= start { before.append(token) }
            else if token.range.location >= oldEnd { after.append(token) }
            else if token.range.location < start || end > oldEnd { return nil }
        }
        let window = scanner.scan(newWindow).map { shift($0, by: start) }
        // Nothing in the window may claim the whole document (front matter).
        if start > 0, window.contains(where: { if case .frontmatter = $0.kind { return true } else { return false } }) { return nil }
        return before + window + after.map { shift($0, by: delta) }
    }

    /// Text whose meaning can reach outside its own blocks.
    private static let reachesOutside = ["```", "~~~", "$$", "%%", "<", "]:", "[^", "[TOC]", "[toc]"]

    private static func isSelfContained(_ window: String) -> Bool {
        !reachesOutside.contains { window.contains($0) }
    }

    /// Start of the top-level block containing `location`: just after a blank
    /// line, at a line that starts at column 0 and is not a list item, quote or
    /// table row (those can continue the block above).
    static func blockStart(before location: Int, in text: NSString) -> Int {
        var position = lineStart(of: min(location, text.length), in: text)
        while position > 0 {
            let previousLineStart = lineStart(of: position - 1, in: text)
            let previousLine = text.substring(with: NSRange(location: previousLineStart, length: position - previousLineStart))
            if previousLine.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, startsTopLevel(at: position, in: text) {
                return position
            }
            position = previousLineStart
        }
        return 0
    }

    /// End of the top-level block containing `location`: the start of the next
    /// line that begins a new top-level block after a blank line.
    static func blockEnd(after location: Int, in text: NSString) -> Int {
        var position = lineEnd(of: min(location, text.length), in: text)
        var sawBlank = false
        while position < text.length {
            let end = lineEnd(of: position, in: text)
            let line = text.substring(with: NSRange(location: position, length: end - position))
            if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                sawBlank = true
            } else if sawBlank, startsTopLevel(at: position, in: text) {
                return position
            } else {
                sawBlank = false
            }
            position = end
        }
        return text.length
    }

    private static func startsTopLevel(at position: Int, in text: NSString) -> Bool {
        guard position < text.length else { return true }
        let end = lineEnd(of: position, in: text)
        let line = text.substring(with: NSRange(location: position, length: end - position))
        guard let first = line.first, !first.isWhitespace else { return false }
        if line.hasPrefix(">") || line.hasPrefix("|") || line.hasPrefix("-") || line.hasPrefix("*")
            || line.hasPrefix("+") || line.hasPrefix("=") { return false }
        // Ordered list item ("12. ") or a setext underline.
        if let dot = line.firstIndex(where: { !$0.isNumber }), dot != line.startIndex,
           line[dot] == "." || line[dot] == ")" { return false }
        return true
    }

    private static func lineStart(of location: Int, in text: NSString) -> Int {
        text.lineRange(for: NSRange(location: min(location, text.length), length: 0)).location
    }

    /// Start of the line after the one containing `location`.
    private static func lineEnd(of location: Int, in text: NSString) -> Int {
        guard location < text.length else { return text.length }
        return NSMaxRange(text.lineRange(for: NSRange(location: location, length: 0)))
    }

    private static func shift(_ token: SyntaxToken, by offset: Int) -> SyntaxToken {
        guard offset != 0 else { return token }
        return SyntaxToken(
            kind: token.kind,
            range: NSRange(location: token.range.location + offset, length: token.range.length),
            contentRange: NSRange(location: token.contentRange.location + offset, length: token.contentRange.length))
    }
}
