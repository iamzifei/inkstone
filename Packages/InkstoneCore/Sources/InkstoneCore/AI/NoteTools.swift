import Foundation

/// What a tool call produced.
public struct ToolOutcome: Sendable, Hashable {
    public let content: String
    public let isError: Bool

    public init(content: String, isError: Bool = false) {
        self.content = content
        self.isError = isError
    }

    /// A failure the model can act on.
    ///
    /// Phrased as instructions rather than as a status, because the model reads
    /// this and decides what to do next: "no note at X, use search_notes to find
    /// it" leads somewhere, "ENOENT" does not.
    public static func failure(_ message: String) -> ToolOutcome {
        ToolOutcome(content: message, isError: true)
    }
}

/// The vault, as a set of tools a model can call.
///
/// Read-only, deliberately: this is the half where a mistake costs nothing. The
/// tools that write come with a review step and belong in their own pass.
///
/// Everything here is built on machinery that already exists and is already
/// fast — `SearchEngine.fullTextConcurrently` covers 8,865 notes in 115 ms, and
/// `IndexSnapshot` holds the link graph as dictionaries. No new index, no
/// embeddings, no crawl.
public struct NoteToolbox: Sendable {
    private let snapshot: IndexSnapshot
    private let store: NoteStore
    private let vaultRoot: URL

    /// How much of a note to return.
    ///
    /// A cap rather than the whole file, because one note in this vault runs to
    /// 40,000 characters and a tool result that fills the context window leaves
    /// no room for the answer. The model is told when it has been truncated and
    /// can ask for the rest.
    public static let noteCharacterLimit = 12_000
    /// How many hits to describe.
    public static let searchResultLimit = 20

    public init(snapshot: IndexSnapshot, store: NoteStore, vaultRoot: URL) {
        self.snapshot = snapshot
        self.store = store
        self.vaultRoot = vaultRoot
    }

    // MARK: - Definitions

    /// What the model is told it can do.
    ///
    /// The descriptions matter more than they look: they are the only
    /// documentation the model gets, and getting one wrong makes the model fail
    /// in a way that looks like the vault is empty.
    ///
    /// This was measured. An earlier version of the search description advised
    /// "two or three words match more than a sentence", which is exactly
    /// backwards: search matches **lines**, so every extra word narrows the
    /// match to lines containing all of them. Given that advice, a model asked
    /// what a note said about brewing searched three multi-word phrases, found
    /// nothing each time, and reported the subject absent from a vault that
    /// contained it. With the rule stated instead, the same model recovered on
    /// its second try and answered correctly.
    public static var definitions: [ToolDefinition] {
        [
            ToolDefinition(
                name: "search_notes",
                description: """
                    Search the user's notes. This matches **lines, not \
                    documents**: every word in the query must appear on the same \
                    line, so search for ONE distinctive word at a time. \
                    "oolong water" finds nothing when a note has "# Oolong" as a \
                    heading and "water 92C" three lines below — search "oolong", \
                    then read the note.

                    Matching is literal, not by meaning, so if a word returns \
                    nothing try a synonym rather than concluding the subject is \
                    absent. Prefix a term with `tag:` to match a tag. Returns \
                    the path, title and matching line of each hit.
                    """,
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "query": .object([
                            "type": .string("string"),
                            "description": .string("One distinctive word, usually. Every word must appear on the same line for a note to match."),
                        ]),
                        "limit": .object([
                            "type": .string("integer"),
                            "description": .string("Maximum hits to return. Defaults to 20."),
                        ]),
                    ]),
                    "required": .array([.string("query")]),
                ])),

            ToolDefinition(
                name: "read_note",
                description: """
                    Read a note in full, by the path search_notes returned. Long \
                    notes are truncated, and the result says so when they are.
                    """,
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "path": .object([
                            "type": .string("string"),
                            "description": .string("Vault-relative path, e.g. `notes/tea.md`."),
                        ]),
                        "offset": .object([
                            "type": .string("integer"),
                            "description": .string("Character to start from, for reading past a truncation point."),
                        ]),
                    ]),
                    "required": .array([.string("path")]),
                ])),

            ToolDefinition(
                name: "list_links",
                description: """
                    List the notes a note links to, and the notes that link to \
                    it. Use this to follow the user's own connections instead of \
                    guessing which notes are related.
                    """,
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "path": .object([
                            "type": .string("string"),
                            "description": .string("Vault-relative path of the note."),
                        ]),
                    ]),
                    "required": .array([.string("path")]),
                ])),

            ToolDefinition(
                name: "list_notes",
                description: """
                    List notes in a folder, or the vault's folders. Use this to \
                    find your bearings when a search has not worked and you do \
                    not know how the vault is organised.
                    """,
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "folder": .object([
                            "type": .string("string"),
                            "description": .string("Vault-relative folder. Omit for the top level."),
                        ]),
                    ]),
                ])),
        ]
    }

    public static let names: Set<String> = Set(definitions.map(\.name))

    // MARK: - Running

    public func run(_ name: String, input: JSONValue) async -> ToolOutcome {
        switch name {
        case "search_notes": return await search(input)
        case "read_note": return read(input)
        case "list_links": return links(input)
        case "list_notes": return list(input)
        default:
            return .failure("There is no tool called \(name).")
        }
    }

    // MARK: - search_notes

    private func search(_ input: JSONValue) async -> ToolOutcome {
        guard let query = input["query"]?.stringValue, !query.isEmpty else {
            return .failure("search_notes needs a `query`.")
        }
        let limit = min(input["limit"]?.intValue ?? Self.searchResultLimit, 50)
        let hits = await SearchEngine.fullTextConcurrently(
            query: query, in: snapshot, store: store, limit: limit)

        guard !hits.isEmpty else {
            // Not an error: nothing found is a real answer. Flagging it as one
            // invites the model to apologise instead of trying another word.
            // The advice names the most likely cause. Measured: a model given
            // only "try related words" retried with more multi-word queries
            // three times and then reported the subject absent from a vault
            // that contained it.
            let words = query.split(whereSeparator: { $0 == " " || $0 == "　" })
            var advice = """
                No notes matched "\(query)".
                """
            if words.count > 1 {
                advice += """
                     All words must appear on the **same line**. Try just \
                    "\(words[0])" on its own, then read the notes it finds.
                    """
            } else {
                advice += """
                     Matching is literal, so try a synonym, or list_notes to \
                    see how the vault is arranged.
                    """
            }
            return ToolOutcome(content: advice)
        }

        var lines = ["\(hits.count) note\(hits.count == 1 ? "" : "s") matched \"\(query)\":", ""]
        for hit in hits {
            let path = relativePath(hit.url)
            let line = hit.line.trimmingCharacters(in: .whitespaces)
            lines.append("- \(path) — \(hit.title)")
            if !line.isEmpty {
                lines.append("  line \(hit.lineNumber): \(line.prefix(200))")
            }
        }
        return ToolOutcome(content: lines.joined(separator: "\n"))
    }

    // MARK: - read_note

    private func read(_ input: JSONValue) -> ToolOutcome {
        guard let path = input["path"]?.stringValue, !path.isEmpty else {
            return .failure("read_note needs a `path`.")
        }
        guard let url = resolve(path) else {
            return .failure("""
                No note at \(path). Use search_notes to find it, or list_notes \
                to see what is in that folder.
                """)
        }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            return .failure("\(path) could not be read.")
        }

        let offset = max(0, input["offset"]?.intValue ?? 0)
        guard offset < text.count else {
            return ToolOutcome(content: "\(path) has \(text.count) characters; offset \(offset) is past the end.")
        }
        let body = String(text.dropFirst(offset).prefix(Self.noteCharacterLimit))
        let end = offset + body.count

        var header = "\(path)"
        if offset > 0 { header += " (from character \(offset))" }
        var footer = ""
        if end < text.count {
            // Told, not silently cut. A model that does not know it received
            // part of a note will answer as though it received all of it.
            footer = "\n\n[Truncated at \(end) of \(text.count) characters. " +
                     "Call read_note again with offset: \(end) for the rest.]"
        }
        return ToolOutcome(content: "--- \(header) ---\n\(body)\(footer)")
    }

    // MARK: - list_links

    private func links(_ input: JSONValue) -> ToolOutcome {
        guard let path = input["path"]?.stringValue, !path.isEmpty else {
            return .failure("list_links needs a `path`.")
        }
        guard let url = resolve(path) else {
            return .failure("No note at \(path).")
        }

        let outgoing = snapshot.outgoing(from: url)
        let incoming = snapshot.backlinks[url] ?? []
        var lines: [String] = []

        if outgoing.isEmpty && incoming.isEmpty {
            return ToolOutcome(content: "\(path) has no links in either direction.")
        }
        if !outgoing.isEmpty {
            lines.append("\(path) links to:")
            // De-duplicated: one note may be referenced several times, and the
            // model does not need to know it was mentioned twice.
            var seen = Set<String>()
            for edge in outgoing {
                let target = edge.destination.map(relativePath) ?? edge.unresolvedTarget
                guard seen.insert(target).inserted else { continue }
                lines.append(edge.destination == nil
                             ? "- \(target) (does not exist yet)"
                             : "- \(target)")
            }
            lines.append("")
        }
        if !incoming.isEmpty {
            lines.append("Notes linking to \(path):")
            var seen = Set<String>()
            for edge in incoming where seen.insert(relativePath(edge.source)).inserted {
                lines.append("- \(relativePath(edge.source))")
            }
        }
        return ToolOutcome(content: lines.joined(separator: "\n"))
    }

    // MARK: - list_notes

    private func list(_ input: JSONValue) -> ToolOutcome {
        let folder = input["folder"]?.stringValue ?? ""
        let prefix = folder.isEmpty ? "" : (folder.hasSuffix("/") ? folder : folder + "/")

        var notes: [String] = []
        var subfolders: Set<String> = []
        for url in snapshot.orderedNotes {
            let path = relativePath(url)
            guard path.hasPrefix(prefix) else { continue }
            let rest = String(path.dropFirst(prefix.count))
            if let slash = rest.firstIndex(of: "/") {
                subfolders.insert(String(rest[rest.startIndex..<slash]))
            } else {
                notes.append(rest)
            }
        }

        guard !notes.isEmpty || !subfolders.isEmpty else {
            return ToolOutcome(content: folder.isEmpty
                ? "The vault has no notes."
                : "Nothing under \(folder). Check the path, or omit it to see the top level.")
        }

        var lines: [String] = []
        if !subfolders.isEmpty {
            lines.append("Folders in \(folder.isEmpty ? "the vault root" : folder):")
            lines += subfolders.sorted().map { "- \(prefix)\($0)/" }
            lines.append("")
        }
        if !notes.isEmpty {
            lines.append("Notes in \(folder.isEmpty ? "the vault root" : folder):")
            // Capped, because a flat folder of several thousand notes would
            // otherwise become the whole context.
            lines += notes.sorted().prefix(100).map { "- \(prefix)\($0)" }
            if notes.count > 100 {
                lines.append("… and \(notes.count - 100) more.")
            }
        }
        return ToolOutcome(content: lines.joined(separator: "\n"))
    }

    // MARK: - Paths

    /// Resolves a path the model supplied.
    ///
    /// Tolerant on purpose: a model that read `work/plan.md` from a search
    /// result may write back `work/plan`, and refusing that teaches it nothing.
    /// Refuses anything outside the vault, which is the part that must not be
    /// tolerant.
    private func resolve(_ path: String) -> URL? {
        guard let relative = VaultPathDetector.vaultRelative(path, vaultRoot: vaultRoot),
              !relative.hasPrefix("..") else { return nil }

        let direct = vaultRoot.appending(path: relative)
        if snapshot.metadata(for: direct) != nil { return direct }

        let withExtension = relative.hasSuffix(".md") ? relative : relative + ".md"
        let guessed = vaultRoot.appending(path: withExtension)
        if snapshot.metadata(for: guessed) != nil { return guessed }

        // Last resort: match on name alone, the way a wikilink resolves.
        return snapshot.resolve(relative, from: vaultRoot, vaultRoot: vaultRoot)
    }

    private func relativePath(_ url: URL) -> String {
        let root = vaultRoot.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(root) else { return url.lastPathComponent }
        return String(path.dropFirst(root.count).drop(while: { $0 == "/" }))
    }
}
