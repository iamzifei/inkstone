import Testing
@testable import InkstoneCore

/// HTML comments read like Obsidian's %%comments%%: gone when reading.
/// Every knowledge base's entry files carry Inkstone's markers as comments.
@Suite("HTML comments")
struct HTMLCommentTests {
    @Test func readingModeHidesThemAndKeepsTheProse() {
        let md = "# AGENTS\n\n<!-- inkstone:auto:start -->\nThis is a knowledge base.\n<!-- inkstone:auto:end -->\n\ntext <!-- note --> more\n"
        let out = ReadingRenderer.render(md).text
        #expect(!out.contains("inkstone:auto"))
        #expect(!out.contains("note -->"))
        #expect(out.contains("This is a knowledge base."))
        #expect(out.contains("text"))
        #expect(out.contains("more"))
    }

    @Test func aCommentInCodeIsCode() {
        let md = "```html\n<!-- keep me -->\n```\n"
        #expect(ReadingRenderer.render(md).text.contains("<!-- keep me -->"))
    }
}
