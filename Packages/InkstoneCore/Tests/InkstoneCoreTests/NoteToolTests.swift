import Testing
import Foundation
@testable import InkstoneCore

/// The vault as tools. What these return is what the assistant knows, so a
/// wrong or unhelpful result becomes a wrong answer rather than an error.
@Suite("Note tools")
struct NoteToolTests {
    /// A vault on disk, because read_note reads files.
    private func vault(_ files: [String: String]) throws -> (URL, NoteToolbox) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "tools-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var notes: [NoteMetadata] = []
        for (name, text) in files {
            let url = root.appending(path: name)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
            notes.append(NoteParser.parse(text: text, url: url))
        }
        let snapshot = IndexBuilder.assemble(notes, vaultRoot: root)
        return (root, NoteToolbox(snapshot: snapshot, store: NoteStore(root: root), vaultRoot: root))
    }

    // MARK: - search_notes

    @Test("A search reports the path, title and matching line")
    func searchesNotes() async throws {
        let (root, tools) = try vault([
            "tea/oolong.md": "# 乌龙\n水温 95 度最合适",
            "tea/green.md": "# 绿茶\n水温 80 度",
            "other.md": "无关内容",
        ])
        defer { try? FileManager.default.removeItem(at: root) }

        let outcome = await tools.run("search_notes", input: .object(["query": .string("水温")]))
        #expect(!outcome.isError)
        // The path is what read_note is called with next, so it has to be there.
        #expect(outcome.content.contains("tea/oolong.md"))
        #expect(outcome.content.contains("tea/green.md"))
        #expect(!outcome.content.contains("other.md"))
    }

    @Test("Finding nothing is an answer, not an error")
    func handlesNoHits() async throws {
        // Flagged as an error, this invites the model to apologise and stop.
        // Said plainly, with the reason, it tries another word — which is what
        // a person does with a keyword search.
        let (root, tools) = try vault(["a.md": "content"])
        defer { try? FileManager.default.removeItem(at: root) }

        let outcome = await tools.run("search_notes", input: .object(["query": .string("zzz")]))
        #expect(!outcome.isError)
        #expect(outcome.content.contains("synonym"))
    }

    @Test("A multi-word miss says why, since that is usually the reason")
    func explainsMultiWordMisses() async throws {
        // Measured against a real model: told only "try related words", it
        // retried with more multi-word queries three times and then reported
        // the subject absent from a vault that contained it. Search matches
        // lines, so every extra word narrows the match rather than widening it,
        // and the advice has to say so.
        let (root, tools) = try vault([
            "brewing/oolong.md": "# 乌龙茶\n\n水温 92 度。",
        ])
        defer { try? FileManager.default.removeItem(at: root) }

        let missed = await tools.run("search_notes",
                                     input: .object(["query": .string("乌龙茶 水温")]))
        #expect(missed.content.contains("same line"))
        // And it names the word to try, rather than leaving that as an exercise.
        #expect(missed.content.contains("乌龙茶"))

        // Which works.
        let found = await tools.run("search_notes", input: .object(["query": .string("乌龙茶")]))
        #expect(found.content.contains("brewing/oolong.md"))
    }

    @Test("A search with no query says which argument is missing")
    func rejectsEmptyQuery() async throws {
        let (root, tools) = try vault(["a.md": ""])
        defer { try? FileManager.default.removeItem(at: root) }
        let outcome = await tools.run("search_notes", input: .object([:]))
        #expect(outcome.isError)
        #expect(outcome.content.contains("query"))
    }

    // MARK: - read_note

    @Test("A note is returned whole, with its path")
    func readsNotes() async throws {
        let (root, tools) = try vault(["work/plan.md": "# Plan\n\nStep one."])
        defer { try? FileManager.default.removeItem(at: root) }

        let outcome = await tools.run("read_note", input: .object(["path": .string("work/plan.md")]))
        #expect(!outcome.isError)
        #expect(outcome.content.contains("Step one."))
        #expect(outcome.content.contains("work/plan.md"))
    }

    @Test("A path written without its extension still resolves")
    func toleratesLoosePaths() async throws {
        // A model that read `work/plan.md` from a search result may write back
        // `work/plan`. Refusing that teaches it nothing and costs a round.
        let (root, tools) = try vault(["work/plan.md": "content"])
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(!(await tools.run("read_note", input: .object(["path": .string("work/plan")]))).isError)
    }

    @Test("A missing note says what to do instead")
    func reportsMissingNotes() async throws {
        let (root, tools) = try vault(["a.md": ""])
        defer { try? FileManager.default.removeItem(at: root) }

        let outcome = await tools.run("read_note", input: .object(["path": .string("nope.md")]))
        #expect(outcome.isError)
        // Names the next move, since the model reads this and decides.
        #expect(outcome.content.contains("search_notes"))
    }

    @Test("A path outside the vault is refused")
    func refusesEscapes() async throws {
        // The one place tolerance stops. These are read-only tools, but a model
        // that can read /etc/passwd by asking is a model that exfiltrates it.
        let (root, tools) = try vault(["a.md": ""])
        defer { try? FileManager.default.removeItem(at: root) }

        for path in ["/etc/passwd", "../../secrets.md", "~/.ssh/id_rsa"] {
            let outcome = await tools.run("read_note", input: .object(["path": .string(path)]))
            #expect(outcome.isError, "\(path) was not refused")
        }
    }

    @Test("A long note is truncated and says so, with how to continue")
    func truncatesLongNotes() async throws {
        // Silently cutting a note means the model answers as though it read all
        // of it, which is a wrong answer given confidently.
        let long = String(repeating: "字", count: NoteToolbox.noteCharacterLimit + 500)
        let (root, tools) = try vault(["big.md": long])
        defer { try? FileManager.default.removeItem(at: root) }

        let outcome = await tools.run("read_note", input: .object(["path": .string("big.md")]))
        #expect(outcome.content.contains("Truncated"))
        #expect(outcome.content.contains("offset"))

        // And the offset works, so the advice is not empty.
        let rest = await tools.run("read_note", input: .object([
            "path": .string("big.md"),
            "offset": .number(Double(NoteToolbox.noteCharacterLimit)),
        ]))
        #expect(!rest.isError)
        #expect(rest.content.contains("from character"))
    }

    // MARK: - list_links

    @Test("Links are reported in both directions")
    func listsLinks() async throws {
        let (root, tools) = try vault([
            "hub.md": "See [[spoke]] and [[missing]]",
            "spoke.md": "Back to [[hub]]",
        ])
        defer { try? FileManager.default.removeItem(at: root) }

        let outcome = await tools.run("list_links", input: .object(["path": .string("hub.md")]))
        #expect(outcome.content.contains("spoke.md"))
        // An unresolved link is shown as one, not hidden: "does not exist yet"
        // is exactly the kind of thing someone asks the assistant about.
        #expect(outcome.content.contains("does not exist yet"))
        #expect(outcome.content.contains("Notes linking to"))
    }

    @Test("A note referenced twice appears once")
    func deduplicatesLinks() async throws {
        let (root, tools) = try vault([
            "a.md": "[[b]] and again [[b]] and once more [[b]]",
            "b.md": "",
        ])
        defer { try? FileManager.default.removeItem(at: root) }

        let outcome = await tools.run("list_links", input: .object(["path": .string("a.md")]))
        #expect(outcome.content.components(separatedBy: "- b.md").count - 1 == 1)
    }

    // MARK: - list_notes

    @Test("Listing shows folders and notes separately")
    func listsNotes() async throws {
        let (root, tools) = try vault([
            "top.md": "", "work/plan.md": "", "work/deep/x.md": "",
        ])
        defer { try? FileManager.default.removeItem(at: root) }

        let outcome = await tools.run("list_notes", input: .object([:]))
        #expect(outcome.content.contains("work/"))
        #expect(outcome.content.contains("top.md"))
        // A folder's contents are not flattened into the root listing.
        #expect(!outcome.content.contains("work/plan.md"))

        let inner = await tools.run("list_notes", input: .object(["folder": .string("work")]))
        #expect(inner.content.contains("work/plan.md"))
        #expect(inner.content.contains("work/deep/"))
    }

    // MARK: - Dispatch

    @Test("An unknown tool is named, not ignored")
    func rejectsUnknownTools() async throws {
        let (root, tools) = try vault(["a.md": ""])
        defer { try? FileManager.default.removeItem(at: root) }
        let outcome = await tools.run("delete_everything", input: .object([:]))
        #expect(outcome.isError)
        #expect(outcome.content.contains("delete_everything"))
    }

    @Test("Every declared tool can be dispatched")
    func declaresWhatItRuns() async throws {
        // The definitions are what the model is told it can call. A name here
        // that dispatch does not know is a tool that always fails.
        let (root, tools) = try vault(["a.md": "x"])
        defer { try? FileManager.default.removeItem(at: root) }

        for definition in NoteToolbox.definitions {
            let outcome = await tools.run(definition.name, input: .object([:]))
            #expect(!outcome.content.contains("There is no tool called"),
                    "\(definition.name) is declared but not dispatched")
        }
    }

    @Test("Every tool's schema is a well-formed object schema")
    func declaresUsableSchemas() {
        // The schema is the model's only documentation. A malformed one is
        // rejected by the provider at request time, on every request.
        for definition in NoteToolbox.definitions {
            #expect(definition.inputSchema["type"]?.stringValue == "object", "\(definition.name)")
            #expect(definition.inputSchema["properties"]?.objectValue != nil, "\(definition.name)")
            #expect(!definition.description.isEmpty, "\(definition.name)")
        }
    }
}

/// The on-device model's limits, which are what make it a different kind of
/// tool rather than a cheaper one.
@Suite("On-device budget")
struct OnDeviceBudgetTests {
    /// Mirrors `AppleOnDeviceProvider.isTooLong`, which lives in the app target
    /// because it imports FoundationModels. The arithmetic is what matters and
    /// it is worth pinning: the window is 4,096 tokens, measured, and the model
    /// refuses the request outright rather than truncating it.
    private func size(_ request: CompletionRequest) -> Int {
        let system = request.system?.count ?? 0
        return system + request.messages.reduce(0) { total, message in
            total + message.blocks.reduce(0) { $0 + $1.plainText.count }
        }
    }

    @Test("A note-sized attachment is over budget")
    func measuresRequests() {
        // A real note from the vault this was built against runs to tens of
        // thousands of characters. The budget is 3,600.
        let note = String(repeating: "笔", count: 8_000)
        let request = CompletionRequest(
            model: "apple-on-device",
            system: "You are an assistant.\n\(note)",
            messages: [.init(role: .user, text: "summarise")])
        #expect(size(request) > 3_600)
    }

    @Test("A short exchange fits")
    func allowsShortRequests() {
        let request = CompletionRequest(
            model: "apple-on-device",
            system: "You are an assistant.",
            messages: [.init(role: .user, text: "rewrite this sentence")])
        #expect(size(request) < 3_600)
    }

    @Test("Tool results alone would exceed the whole window")
    func showsWhyToolsAreDeclined() {
        // The reason tools are refused rather than offered and left to fail:
        // one read_note result is more than three times the entire budget, so
        // the first round of any loop would be the last.
        #expect(NoteToolbox.noteCharacterLimit > 3_600 * 3)
    }
}
