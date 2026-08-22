import Foundation

/// Which part of a note an embed refers to.
///
/// `![[Note]]` is the whole body, `![[Note#Heading]]` is that heading's section,
/// and `![[Note#^anchor]]` is the block carrying that anchor. Splitting this out
/// of the editor is what makes it testable: the rules for "where does a section
/// end" are fiddly and entirely about text.
public enum NoteSlice {

    /// The range of `text` an embed's `fragment` refers to.
    ///
    /// Returns the whole body — frontmatter excluded — when there is no
    /// fragment, and an empty range when the fragment names something the note
    /// does not contain. An empty range is the honest answer: it lets the caller
    /// show the embed as unresolved rather than silently transcluding the whole
    /// note, which is what a typo in a heading name would otherwise do.
    public static func range(in text: String, fragment: String?) -> NSRange {
        let ns = text as NSString
        let body = bodyRange(in: ns)
        guard let fragment, !fragment.isEmpty else { return body }

        if fragment.hasPrefix("^") {
            return blockRange(in: ns, anchor: String(fragment.dropFirst()), within: body)
        }
        return sectionRange(in: ns, heading: fragment, within: body)
    }

    /// Everything after the frontmatter.
    private static func bodyRange(in text: NSString) -> NSRange {
        let full = NSRange(location: 0, length: text.length)
        guard let frontmatter = frontmatterRange(in: text) else { return full }
        let start = NSMaxRange(frontmatter)
        return NSRange(location: start, length: max(0, text.length - start))
    }

    private static func frontmatterRange(in text: NSString) -> NSRange? {
        guard text.hasPrefix("---") else { return nil }
        let pattern = try! NSRegularExpression(pattern: #"\A---[ \t]*\n[\s\S]*?\n---[ \t]*(?:\n|\z)"#)
        guard let match = pattern.firstMatch(
            in: text as String, range: NSRange(location: 0, length: text.length)
        ), match.range.location == 0 else { return nil }
        return match.range
    }

    /// A heading and everything under it, up to the next heading of the same or
    /// a higher level.
    ///
    /// "The same or higher" is what makes an embedded `## Section` bring its
    /// `###` subsections with it and stop at the next `##`. Stopping at the next
    /// heading of *any* level would truncate almost every real section.
    private static func sectionRange(in text: NSString, heading: String, within body: NSRange) -> NSRange {
        let wanted = heading.trimmingCharacters(in: .whitespaces).lowercased()
        var location = body.location
        var start: Int?
        var startLevel = 0

        while location < NSMaxRange(body) {
            let line = text.lineRange(for: NSRange(location: location, length: 0))
            defer { location = max(NSMaxRange(line), location + 1) }
            guard let (level, title) = atxHeading(text.substring(with: line)) else { continue }

            if let start {
                guard level <= startLevel else { continue }
                return NSRange(location: start, length: line.location - start)
            }
            if title.lowercased() == wanted {
                start = line.location
                startLevel = level
            }
        }
        guard let start else { return NSRange(location: body.location, length: 0) }
        return NSRange(location: start, length: NSMaxRange(body) - start)
    }

    /// `# Title` → (1, "Title"), or nil for a line that is not an ATX heading.
    private static func atxHeading(_ line: String) -> (level: Int, title: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        let hashes = trimmed.prefix { $0 == "#" }
        guard (1...6).contains(hashes.count) else { return nil }
        let rest = trimmed.dropFirst(hashes.count)
        guard rest.first?.isWhitespace == true else { return nil }
        // A closing run of hashes is decoration, not part of the title.
        let title = rest.trimmingCharacters(in: .whitespaces)
            .reversed().drop { $0 == "#" }.reversed()
        return (hashes.count, String(title).trimmingCharacters(in: .whitespaces))
    }

    /// The block a `^anchor` sits at the end of.
    ///
    /// A block is the run of non-blank lines the anchor's line belongs to, which
    /// is what makes an anchor on the last line of a list item bring the whole
    /// item — and only that item.
    private static func blockRange(in text: NSString, anchor: String, within body: NSRange) -> NSRange {
        let wanted = anchor.trimmingCharacters(in: .whitespaces)
        guard !wanted.isEmpty else { return NSRange(location: body.location, length: 0) }
        let pattern = try! NSRegularExpression(
            pattern: #"(?m)(?:^|[ \t])\^"# + NSRegularExpression.escapedPattern(for: wanted) + #"[ \t]*$"#
        )
        guard let match = pattern.firstMatch(in: text as String, range: body) else {
            return NSRange(location: body.location, length: 0)
        }

        let anchorLine = text.lineRange(for: NSRange(location: match.range.location, length: 0))
        var start = anchorLine.location
        while start > body.location {
            let previous = text.lineRange(for: NSRange(location: start - 1, length: 0))
            guard !isBlank(text.substring(with: previous)) else { break }
            start = previous.location
        }
        var end = NSMaxRange(anchorLine)
        while end < NSMaxRange(body) {
            let next = text.lineRange(for: NSRange(location: end, length: 0))
            guard !isBlank(text.substring(with: next)) else { break }
            end = NSMaxRange(next)
        }
        return NSRange(location: start, length: end - start)
    }

    private static func isBlank(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The anchor stripped from a block's text, so a transclusion does not show
    /// the `^id` that was only there to be linked to.
    public static func strippingAnchor(_ text: String) -> String {
        let pattern = try! NSRegularExpression(pattern: #"(?m)[ \t]*\^[A-Za-z0-9][A-Za-z0-9-]*[ \t]*$"#)
        let range = NSRange(location: 0, length: (text as NSString).length)
        return pattern.stringByReplacingMatches(in: text, range: range, withTemplate: "")
    }
}
