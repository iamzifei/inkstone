import Testing
import Foundation
@testable import InkstoneCore

/// Reading mode.
///
/// Until this existed, `EditorMode.reading` had exactly one effect in the whole
/// codebase — `isEditable = false` — so the third button in the mode picker
/// offered something that was not there. The difference reading mode is supposed
/// to make is that the *syntax is gone*, not hidden: these tests are that
/// difference, stated.
@Suite("Reading renderer")
struct ReadingRendererTests {
    private func rendered(_ markdown: String) -> String {
        ReadingRenderer.render(markdown).text
    }

    // MARK: - The syntax is actually gone

    @Test("Inline delimiters are deleted, not hidden")
    func removesInlineSyntax() {
        // The whole point. Live preview leaves these characters in the document
        // at 0.01pt; copying a paragraph there gives you markup back.
        #expect(rendered("a **bold** word") == "a bold word")
        #expect(rendered("a *quiet* word") == "a quiet word")
        #expect(rendered("a ~~cut~~ word") == "a cut word")
        #expect(rendered("a ==lit== word") == "a lit word")
        #expect(rendered("a `code` word") == "a code word")
    }

    @Test("A heading loses its hashes and keeps its text")
    func removesHeadingMarkers() {
        #expect(rendered("# Title") == "Title")
        #expect(rendered("### Deeper") == "Deeper")
    }

    @Test("A wikilink reads as what it shows")
    func rendersLinks() {
        #expect(rendered("see [[Note]] here") == "see Note here")
        #expect(rendered("see [[Note|the note]] here") == "see the note here")
    }

    @Test("A quote loses its angle brackets")
    func removesQuoteMarkers() {
        // A blockquote token's content range is the whole line, so trimming its
        // "delimiters" cuts nothing — the `>` survived into the rendered text
        // and reading mode showed markup in the one place it promises not to.
        #expect(rendered("> quoted") == "quoted")
        #expect(rendered("> one\n> two") == "one\ntwo")
        #expect(rendered(">> deep") == "deep")
        // A `>` that is not a quote marker is left alone.
        #expect(rendered("a > b") == "a > b")
    }

    @Test("Frontmatter is not prose and does not appear")
    func removesFrontmatter() {
        let text = rendered("---\ntags: [a]\n---\n# Title\n")
        #expect(!text.contains("tags:"))
        #expect(text.contains("Title"))
    }

    @Test("A code fence goes and the code stays")
    func keepsCodeAndDropsFences() {
        let text = rendered("```swift\nlet x = 1\n```")
        #expect(text.contains("let x = 1"))
        #expect(!text.contains("```"))
    }

    // MARK: - Things that become symbols

    @Test("A bullet becomes a bullet")
    func rendersBullets() {
        #expect(rendered("- one\n- two") == "• one\n• two")
    }

    @Test("An ordered list keeps its numbers")
    func keepsOrderedNumbers() {
        // They carry meaning — step 2 is step 2 — where a `-` never did.
        #expect(rendered("1. first\n2. second") == "1. first\n2. second")
    }

    @Test("A task is drawn rather than offered")
    func rendersTasks() {
        // Nothing here can be ticked, and a checkbox that ignores a click is
        // worse than a symbol that never claimed to accept one.
        let text = rendered("- [ ] todo\n- [x] done")
        #expect(text.contains("☐ todo"))
        #expect(text.contains("☑ done"))
        #expect(!text.contains("[ ]"))
        #expect(!text.contains("[x]"))
    }

    @Test("Nested bullets keep their indentation")
    func keepsNesting() {
        #expect(rendered("- one\n  - two") == "• one\n  • two")
    }

    // MARK: - Styling survives the deletion

    @Test("A span points at the right text after the cuts")
    func mapsSpansToRenderedOffsets() {
        // The part most likely to be silently wrong: every offset moves when the
        // delimiters are deleted, so a span that was computed against the source
        // would land somewhere else entirely.
        let document = ReadingRenderer.render("a **bold** word")
        let bold = document.spans.first { $0.style == .bold }
        #expect(bold != nil)
        if let bold {
            #expect((document.text as NSString).substring(with: bold.range) == "bold")
        }
    }

    @Test("Every span lands inside the rendered text")
    func spansAreInBounds() {
        // A span past the end is a crash the moment anything draws it.
        let markdown = """
        ---
        tags: [x]
        ---
        # 标题 with **bold**

        > a quote with `code` and [[A Link|shown]]

        - [ ] a task
        - a bullet

        ```swift
        let x = 1
        ```

        | a | b |
        | --- | --- |
        | 1 | 2 |
        """
        let document = ReadingRenderer.render(markdown)
        let length = (document.text as NSString).length
        for span in document.spans {
            #expect(span.range.location >= 0)
            #expect(NSMaxRange(span.range) <= length,
                    "\(span.style) ends at \(NSMaxRange(span.range)) but text is \(length)")
        }
    }

    @Test("A heading span covers the heading's words")
    func stylesHeadings() {
        let document = ReadingRenderer.render("# Title\n\nbody")
        let heading = document.spans.first { if case .heading = $0.style { true } else { false } }
        #expect(heading != nil)
        if let heading {
            #expect((document.text as NSString).substring(with: heading.range) == "Title")
        }
    }

    // MARK: - It differs from the source, which is the whole point

    @Test("Reading a real note is not the same text as editing it")
    func differsFromSource() {
        let markdown = "# Title\n\nSome **bold** and a [[Link]] and `code`.\n"
        #expect(rendered(markdown) != markdown)
        #expect(rendered(markdown).count < markdown.count)
    }

    // MARK: - Robustness

    @Test("Unbalanced and empty input does not crash or corrupt")
    func survivesRoughInput() {
        for markdown in ["", "**", "`", "[[", "# ", "```\nunclosed", "~~~", "- [ ", "|"] {
            let document = ReadingRenderer.render(markdown)
            let length = (document.text as NSString).length
            for span in document.spans {
                #expect(NSMaxRange(span.range) <= length, "input \(markdown.debugDescription)")
            }
        }
    }

    @Test("CJK offsets survive the deletion pass")
    func handlesCJK() {
        // `NSRange` is UTF-16, and the vault this app is built for is full of
        // Chinese. An off-by-one here would cut a character in half.
        let document = ReadingRenderer.render("中文 **加粗** 结尾")
        #expect(document.text == "中文 加粗 结尾")
        let bold = document.spans.first { $0.style == .bold }
        #expect(bold != nil)
        if let bold {
            #expect((document.text as NSString).substring(with: bold.range) == "加粗")
        }
    }
}
