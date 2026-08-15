import Foundation

/// One hit in full-text search: the note plus the line it matched on.
public struct SearchHit: Identifiable, Hashable, Sendable {
    public let id = UUID()
    public let url: URL
    public let title: String
    public let lineNumber: Int
    public let line: String
    /// Ranges within `line` that matched, for highlighting.
    public let matchRanges: [NSRange]
    public let score: Double
}

/// Ranked result for the quick switcher (⌘O) — filename/alias matching only.
public struct QuickSwitchResult: Identifiable, Hashable, Sendable {
    public var id: URL { url }
    public let url: URL
    public let title: String
    public let subtitle: String
    /// Indices in `title` that matched the query, for highlighting.
    public let matchedIndices: [Int]
    public let score: Double
    public let exists: Bool
}

public enum SearchEngine {
    // MARK: - Quick switcher

    /// Fuzzy-matches a query against note titles, aliases, and paths.
    ///
    /// Scoring rewards matches at word starts and consecutive runs, which is what
    /// makes typing "dnw" find "Daily Notes/Weekly" rather than a random file
    /// containing those letters far apart.
    public static func quickSwitch(
        query: String,
        in snapshot: IndexSnapshot,
        vaultRoot: URL,
        limit: Int = 50
    ) -> [QuickSwitchResult] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        let notes = snapshot.notes.values

        guard !trimmed.isEmpty else {
            return notes
                .sorted { $0.modified > $1.modified }
                .prefix(limit)
                .map {
                    QuickSwitchResult(
                        url: $0.url,
                        title: $0.title,
                        subtitle: relativePath(of: $0.url, in: vaultRoot),
                        matchedIndices: [],
                        score: 0,
                        exists: true
                    )
                }
        }

        var results: [QuickSwitchResult] = []
        for note in notes {
            // Try title, then each alias, then the relative path; keep the best.
            let path = relativePath(of: note.url, in: vaultRoot)
            let candidates = [note.title, note.basename] + note.aliases
            var best: (score: Double, indices: [Int], text: String)?

            for candidate in candidates {
                guard let match = fuzzyMatch(query: trimmed, in: candidate) else { continue }
                if best == nil || match.score > best!.score {
                    best = (match.score, match.indices, candidate)
                }
            }
            // A path match is worth less than a name match but still useful.
            if best == nil, let match = fuzzyMatch(query: trimmed, in: path) {
                best = (match.score * 0.5, [], path)
            }

            guard let best else { continue }
            results.append(QuickSwitchResult(
                url: note.url,
                title: best.text,
                subtitle: path,
                matchedIndices: best.indices,
                score: best.score,
                exists: true
            ))
        }

        results.sort { $0.score > $1.score }
        return Array(results.prefix(limit))
    }

    /// Case-insensitive subsequence match with positional bonuses.
    /// Returns `nil` when the query isn't a subsequence of the candidate.
    public static func fuzzyMatch(query: String, in candidate: String) -> (score: Double, indices: [Int])? {
        let queryChars = Array(query.lowercased())
        let candidateChars = Array(candidate.lowercased())
        guard !queryChars.isEmpty, queryChars.count <= candidateChars.count else { return nil }

        var indices: [Int] = []
        var score = 0.0
        var queryIndex = 0
        var previousMatchIndex = -1

        for (index, character) in candidateChars.enumerated() {
            guard queryIndex < queryChars.count, character == queryChars[queryIndex] else { continue }

            // Consecutive characters score much higher than scattered ones.
            if previousMatchIndex == index - 1 { score += 8 } else { score += 1 }

            // Word boundaries (start of string, after a separator, or a CJK
            // character) are strong signals of intent.
            let isBoundary = index == 0
                || " -_/.·，。".contains(candidateChars[index - 1])
            if isBoundary { score += 6 }

            // Earlier matches beat later ones, all else equal.
            score += max(0, 3.0 - Double(index) * 0.05)

            indices.append(index)
            previousMatchIndex = index
            queryIndex += 1
        }

        guard queryIndex == queryChars.count else { return nil }

        // Prefer shorter candidates: "Notes" should beat "Notes about notes".
        score -= Double(candidateChars.count) * 0.05
        if candidateChars.count == queryChars.count { score += 20 }
        return (score, indices)
    }

    // MARK: - Full text

    /// Searches note bodies. Supports plain substrings and `tag:`/`path:`/`file:`
    /// filters, mirroring the operators Obsidian users already know.
    public static func fullText(
        query: String,
        in snapshot: IndexSnapshot,
        store: NoteStore,
        limit: Int = 200
    ) -> [SearchHit] {
        let parsed = SearchQuery(raw: query)
        guard !parsed.terms.isEmpty || !parsed.tags.isEmpty else { return [] }

        var hits: [SearchHit] = []
        for note in snapshot.notes.values {
            guard parsed.matchesMetadata(note) else { continue }
            guard !parsed.terms.isEmpty else {
                hits.append(SearchHit(
                    url: note.url,
                    title: note.title,
                    lineNumber: 0,
                    line: "",
                    matchRanges: [],
                    score: 1
                ))
                continue
            }
            guard let text = try? store.read(note.url) else { continue }

            for (offset, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let lineString = String(line)
                var ranges: [NSRange] = []
                var matchedAll = true
                for term in parsed.terms {
                    let found = (lineString as NSString).range(of: term, options: [.caseInsensitive, .diacriticInsensitive])
                    if found.location == NSNotFound { matchedAll = false; break }
                    ranges.append(found)
                }
                guard matchedAll else { continue }
                hits.append(SearchHit(
                    url: note.url,
                    title: note.title,
                    lineNumber: offset + 1,
                    line: lineString,
                    matchRanges: ranges,
                    score: Double(ranges.count)
                ))
                if hits.count >= limit { break }
            }
            if hits.count >= limit { break }
        }
        return hits
    }

    private static func relativePath(of url: URL, in root: URL) -> String {
        let rootPath = root.path(percentEncoded: false)
        let path = url.deletingPathExtension().path(percentEncoded: false)
        guard path.hasPrefix(rootPath) else { return path }
        return String(path.dropFirst(rootPath.count).drop(while: { $0 == "/" }))
    }
}

/// Parses `tag:foo path:bar plain words` into structured filters.
struct SearchQuery {
    var terms: [String] = []
    var tags: [String] = []
    var pathFragments: [String] = []

    init(raw: String) {
        for token in raw.split(separator: " ", omittingEmptySubsequences: true) {
            if token.hasPrefix("tag:") {
                tags.append(String(token.dropFirst(4)).trimmingCharacters(in: CharacterSet(charactersIn: "#")))
            } else if token.hasPrefix("path:") {
                pathFragments.append(String(token.dropFirst(5)))
            } else if token.hasPrefix("file:") {
                pathFragments.append(String(token.dropFirst(5)))
            } else {
                terms.append(String(token))
            }
        }
    }

    func matchesMetadata(_ note: NoteMetadata) -> Bool {
        for tag in tags {
            // `tag:project` matches `#project` and `#project/inkstone`.
            guard note.tags.contains(where: { $0 == tag || $0.hasPrefix(tag + "/") }) else { return false }
        }
        for fragment in pathFragments {
            guard note.url.path(percentEncoded: false).localizedCaseInsensitiveContains(fragment) else { return false }
        }
        return true
    }
}
