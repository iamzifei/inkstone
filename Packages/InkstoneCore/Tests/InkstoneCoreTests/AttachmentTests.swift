import Testing
import Foundation
@testable import InkstoneCore

/// Attachments: what the user adds by hand, as opposed to what the assistant
/// finds for itself.
@Suite("Chat attachments")
struct ChatAttachmentTests {
    @Test("An attached note is read at send time, not at attach time")
    func readsLate() {
        // A note edited between attaching and sending should go as it is now.
        // The renderer is handed a closure rather than text for exactly this.
        var current = "first version"
        let block = AttachmentRenderer.textBlock(
            for: [ChatAttachment(kind: .note(path: "a.md"))],
            readNote: { _ in current }, listFolder: { _ in [] })
        #expect(block?.contains("first version") == true)

        current = "second version"
        let later = AttachmentRenderer.textBlock(
            for: [ChatAttachment(kind: .note(path: "a.md"))],
            readNote: { _ in current }, listFolder: { _ in [] })
        #expect(later?.contains("second version") == true)
    }

    @Test("A note that cannot be read says so rather than going missing")
    func reportsUnreadableNotes() {
        let block = AttachmentRenderer.textBlock(
            for: [ChatAttachment(kind: .note(path: "gone.md"))],
            readNote: { _ in nil }, listFolder: { _ in [] })
        #expect(block?.contains("could not be read") == true)
    }

    @Test("A folder is listed, not read")
    func listsFoldersWithoutReading() {
        // A folder can hold hundreds of notes; attaching one means "look in
        // here", which the assistant can then do with its own tools.
        let block = AttachmentRenderer.textBlock(
            for: [ChatAttachment(kind: .folder(path: "work"))],
            readNote: { _ in "SHOULD NOT APPEAR" },
            listFolder: { _ in ["work/a.md", "work/b.md"] })
        #expect(block?.contains("work/a.md") == true)
        #expect(block?.contains("SHOULD NOT APPEAR") == false)
        #expect(block?.contains("2 notes") == true)
    }

    @Test("An oversized attachment is cut and says where")
    func truncatesLongAttachments() {
        let long = String(repeating: "字", count: AttachmentRenderer.characterLimit + 100)
        let block = AttachmentRenderer.textBlock(
            for: [ChatAttachment(kind: .file(name: "big.txt", text: long))],
            readNote: { _ in nil }, listFolder: { _ in [] })
        #expect(block?.contains("truncated") == true)
    }

    @Test("Images become their own blocks, not text")
    func separatesImages() {
        // A vision model needs a picture as a picture. Described in prose it is
        // just a claim that an image exists.
        let attachments = [
            ChatAttachment(kind: .image(mimeType: "image/png", data: Data([1, 2, 3]))),
            ChatAttachment(kind: .note(path: "a.md")),
        ]
        let blocks = AttachmentRenderer.imageBlocks(for: attachments)
        #expect(blocks.count == 1)
        guard case .image(let mime, _) = blocks[0] else { Issue.record("not an image"); return }
        #expect(mime == "image/png")

        // And the text block does not mention the image.
        let text = AttachmentRenderer.textBlock(
            for: attachments, readNote: { _ in "note text" }, listFolder: { _ in [] })
        #expect(text?.contains("note text") == true)
    }

    @Test("Nothing attached produces no block at all")
    func staysQuietWhenEmpty() {
        // An empty "the user attached the following" costs tokens and says the
        // opposite of the truth.
        #expect(AttachmentRenderer.textBlock(
            for: [], readNote: { _ in nil }, listFolder: { _ in [] }) == nil)
        #expect(AttachmentRenderer.textBlock(
            for: [ChatAttachment(kind: .image(mimeType: "image/png", data: Data()))],
            readNote: { _ in nil }, listFolder: { _ in [] }) == nil)
    }

    @Test("Attachments say what they are in the chip")
    func labelsThemselves() {
        #expect(ChatAttachment(kind: .note(path: "work/plan.md")).label == "plan.md")
        #expect(ChatAttachment(kind: .folder(path: "work/deep")).label == "deep/")
        #expect(ChatAttachment(kind: .file(name: "x.csv", text: "")).label == "x.csv")
        #expect(!ChatAttachment(kind: .note(path: "a.md")).isImage)
        #expect(ChatAttachment(kind: .image(mimeType: "image/png", data: Data())).isImage)
    }

    @Test("Attachments survive being saved with the conversation")
    func codesForHistory() throws {
        let attachment = ChatAttachment(kind: .selection(from: "note", text: "选中的话"))
        let data = try JSONEncoder().encode(attachment)
        #expect(try JSONDecoder().decode(ChatAttachment.self, from: data) == attachment)
    }
}

@Suite("Mentions")
struct MentionTests {
    let root = URL(fileURLWithPath: "/vault")

    private func snapshot(_ paths: [String]) -> IndexSnapshot {
        IndexBuilder.assemble(
            paths.map { NoteParser.parse(text: "", url: root.appending(path: $0)) },
            vaultRoot: root)
    }

    @Test("A mention finds notes by name the way ⌘O does")
    func matchesNotes() {
        // Reusing quickSwitch rather than writing a second matcher: two places
        // that both match note names must not disagree about what matches.
        let found = MentionIndex.matching(
            "plan", in: snapshot(["work/plan.md", "other.md"]), vaultRoot: root)
        #expect(found.contains { $0.label == "plan.md" })
        #expect(!found.contains { $0.label == "other.md" })
    }

    @Test("A mention can pick a folder")
    func matchesFolders() {
        let found = MentionIndex.matching(
            "work", in: snapshot(["work/a.md", "work/b.md", "home/c.md"]), vaultRoot: root)
        #expect(found.contains { if case .folder = $0.kind { return true }; return false })
    }

    @Test("An empty query offers notes rather than nothing")
    func handlesEmptyQuery() {
        // Typing `@` alone should show something to pick from.
        #expect(!MentionIndex.matching("", in: snapshot(["a.md", "b.md"]), vaultRoot: root).isEmpty)
    }
}
