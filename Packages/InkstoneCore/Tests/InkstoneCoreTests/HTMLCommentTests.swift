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

    // Review of #29 (measured cases).
    @Test func aCommentSpanningLinesInProseIsHiddenWhole() {
        let out = ReadingRenderer.render("text <!-- a\nb #tag --> more #real\n").text
        #expect(!out.contains(">"))
        #expect(out.contains("text"))
        #expect(out.contains("more"))
    }

    @Test func textBetweenTwoCommentsOnALineStays() {
        let out = ReadingRenderer.render("<!-- a --> visible <!-- b -->\n").text
        #expect(out.contains("visible"))
    }

    @Test func tagsAndLinksInsideACommentAreNotIndexed() {
        let tokens = SyntaxScanner().scan("<!-- #secret [[Hidden]] -->\n\ntext #real\n")
        let tags = tokens.compactMap { if case .tag = $0.kind { return $0 } else { return nil } }
        #expect(tags.count == 1)
        #expect(SyntaxScanner().links(in: "<!-- [[Hidden]] -->\n").isEmpty)
    }

    @Test func exportKeepsHTMLCommentsAndDropsObsidianOnes() {
        let html = HTMLExporter.bodyHTML("- a\n\n<!-- -->\n\n- b\n\n%%private%%\n", resolveAttachment: { _ in nil })
        #expect(html.contains("<!-- -->"))
        #expect(!html.contains("private"))
    }

    @Test func aCommentSpanningLinesInAQuoteAListOrCRLFIsHiddenWhole() {
        for md in ["> text <!-- a\n> b --> more\n", "- item <!-- a\n  b --> more\n", "text <!-- a\r\nb\r\nc --> more\r\n"] {
            let out = ReadingRenderer.render(md).text
            #expect(!out.contains("->"), "\(md.debugDescription) → \(out.debugDescription)")
            #expect(out.contains("more"), "\(md.debugDescription)")
        }
    }
}

