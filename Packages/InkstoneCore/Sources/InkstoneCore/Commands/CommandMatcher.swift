import Foundation

/// Ranks command titles against what was typed into the command palette.
///
/// A title matches when every typed character appears in it in order (case
/// and diacritics ignored). Matches are scored: a character at the start of a
/// word, or right after the previous matched one, scores more; earlier matches
/// score a little more. Ties keep the catalog's order.
public enum CommandMatcher {
    public static func rank<T>(_ query: String, _ items: [T], title: (T) -> String) -> [T] {
        let q = Array(fold(query).filter { !$0.isWhitespace })
        guard !q.isEmpty else { return items }
        return items.enumerated()
            .compactMap { index, item in score(q, Array(fold(title(item)))).map { (item, $0, index) } }
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.2 < $1.2 }
            .map(\.0)
    }

    private static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    /// Greedy left-to-right match, preferring word starts: for each typed
    /// character take the next word-start occurrence if one comes before the
    /// next plain occurrence's word ends, else the next occurrence.
    static func score(_ query: [Character], _ title: [Character]) -> Int? {
        func isWordStart(_ i: Int) -> Bool {
            i == 0 || !(title[i - 1].isLetter || title[i - 1].isNumber) || (title[i].isUppercase && title[i - 1].isLowercase)
                // Scripts without spaces (CJK): every character starts a word.
                || !title[i].isASCII
        }
        var total = 0
        var position = 0
        var previous = -2
        for ch in query {
            guard let next = title[position...].firstIndex(of: ch) else { return nil }
            // A word start further on beats a mid-word hit, unless the mid-word
            // hit continues the previous match.
            var pick = next
            if next != previous + 1, !isWordStart(next),
               let start = title[next...].indices.first(where: { title[$0] == ch && isWordStart($0) }) {
                pick = start
            }
            total += 1
            if isWordStart(pick) { total += 8 }
            if pick == previous + 1 { total += 5 }
            total -= min(pick, 20) / 4
            previous = pick
            position = pick + 1
        }
        return total
    }
}
