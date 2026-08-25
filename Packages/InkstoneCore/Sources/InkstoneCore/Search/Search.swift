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
    /// The same search, reading the vault in parallel batches.
    ///
    /// Two things had to be true at once, and neither implementation alone
    /// managed both. Measured on 8,852 notes, release build:
    ///
    /// | query | serial | all-at-once | batched |
    /// | --- | --- | --- | --- |
    /// | matches nothing | 774 ms | 102 ms | 105 ms |
    /// | matches plenty | 110 ms | 178 ms | 44 ms |
    ///
    /// Serial reads one file at a time, so the no-match case — every prefix of
    /// every query you are still typing — waits on disk 8,852 times. Reading the
    /// whole vault at once fixes that and loses the early exit, so the case that
    /// *did* stop at 200 hits now reads everything.
    ///
    /// Batches keep both: each batch is read in parallel, and the loop stops as
    /// soon as there are enough hits. A common query finishes in the first batch;
    /// a query with no hits pays for the whole vault but pays concurrently.
    public static func fullTextConcurrently(
        query: String,
        in snapshot: IndexSnapshot,
        store: NoteStore,
        limit: Int = 200,
        batchSize: Int = 1_024
    ) async -> [SearchHit] {
        let parsed = SearchQuery(raw: query)
        guard !parsed.terms.isEmpty || !parsed.tags.isEmpty else { return [] }

        // `orderedNotes` was sorted once when the snapshot was built. Sorting
        // here instead — by `url.path`, which builds a String per comparison —
        // cost more than the search did.
        let candidates = snapshot.orderedNotes.compactMap { url -> NoteMetadata? in
            guard let note = snapshot.notes[url], parsed.matchesMetadata(note) else { return nil }
            return note
        }

        guard !parsed.terms.isEmpty else {
            return candidates.prefix(limit).map {
                SearchHit(url: $0.url, title: $0.title, lineNumber: 0,
                          line: "", matchRanges: [], score: 1)
            }
        }

        var hits: [SearchHit] = []
        var start = candidates.startIndex

        while start < candidates.endIndex, hits.count < limit {
            if Task.isCancelled { return hits }
            let end = candidates.index(start, offsetBy: batchSize, limitedBy: candidates.endIndex)
                ?? candidates.endIndex
            let batch = candidates[start..<end]

            var found: [(offset: Int, hits: [SearchHit])] = []
            await withTaskGroup(of: (Int, [SearchHit]).self) { group in
                for (offset, note) in batch.enumerated() {
                    group.addTask {
                        guard let text = try? store.read(note.url) else { return (offset, []) }
                        return (offset, matches(of: parsed, in: text, note: note))
                    }
                }
                for await result in group { found.append(result) }
            }
            // Back into candidate order, which the task group does not preserve.
            for entry in found.sorted(by: { $0.offset < $1.offset }) {
                hits.append(contentsOf: entry.hits)
            }
            start = end
        }
        return Array(hits.prefix(limit))
    }

    /// Every matching line in one note.
    private static func matches(of parsed: SearchQuery, in text: String, note: NoteMetadata) -> [SearchHit] {
        var hits: [SearchHit] = []
        for (offset, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let lineString = String(line)
            var ranges: [NSRange] = []
            var matchedAll = true
            for term in parsed.terms {
                let found = (lineString as NSString).range(
                    of: term, options: [.caseInsensitive, .diacriticInsensitive])
                if found.location == NSNotFound { matchedAll = false; break }
                ranges.append(found)
            }
            guard matchedAll else { continue }
            hits.append(SearchHit(
                url: note.url, title: note.title, lineNumber: offset + 1,
                line: lineString, matchRanges: ranges, score: Double(ranges.count)
            ))
        }
        return hits
    }

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

    /// Whether a note matches without reading its body.
    ///
    /// The index deliberately keeps note text on disk, so the graph has no
    /// bodies to search: a bare word there means "somewhere in the file's path",
    /// which is what Obsidian's graph filter matches on too.
    func matchesWithoutBody(_ note: NoteMetadata) -> Bool {
        guard matchesMetadata(note) else { return false }
        guard !terms.isEmpty else { return true }
        let path = note.url.path(percentEncoded: false)
        return terms.allSatisfy { path.localizedCaseInsensitiveContains($0) }
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
