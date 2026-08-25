import Foundation

/// The order a note's properties should be shown in: the order they appear in
/// the file.
///
/// `Frontmatter.properties` is a dictionary, and Swift seeds its hashing per
/// process, so taking `keys` directly gives a different order on every launch —
/// a properties table that rearranges itself between sessions. Sorting would be
/// stable but would still rearrange what the author wrote. So the order is read
/// back out of the YAML source.
///
/// Lives in the core rather than in the view that draws it so it can be tested
/// without a text view.
public enum NotePropertyOrder {
    public static func keys(of frontmatter: Frontmatter, in source: String) -> [String] {
        var seen: Set<String> = []
        var ordered: [String] = []

        for line in source.split(separator: "\n", omittingEmptySubsequences: false) {
            // Top-level keys only: an indented line is a nested value, and a
            // leading `-` is a list item belonging to the key above it.
            guard let first = line.first, !first.isWhitespace, first != "-" else { continue }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[line.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, frontmatter.properties[key] != nil else { continue }
            if seen.insert(key).inserted { ordered.append(key) }
        }

        // A key the scan could not match — a quoted one, say — goes on the end
        // in a stable order rather than vanishing from the table.
        for key in frontmatter.properties.keys.sorted() where !seen.contains(key) {
            ordered.append(key)
        }
        return ordered
    }
}
