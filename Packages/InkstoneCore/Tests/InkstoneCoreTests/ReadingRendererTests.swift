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

    @Test("Frontmatter loses its rules and keeps everything between them")
    func rendersFrontmatter() {
        // This test used to assert the opposite — that the whole block vanished
        // — which is what the bug was. Reading mode may restyle a note's
        // properties; it may not throw them away.
        let text = rendered("---\ntags: [a]\n---\n# Title\n")
        #expect(text.contains("tags: [a]"))
        #expect(!text.contains("---"))
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

    // MARK: - Nothing is lost

    @Test("Frontmatter keeps its contents and loses only its rules")
    func keepsFrontmatterContents() {
        // It used to be deleted whole. On a header written with full-width
        // colons — which YAML reads as one long scalar, not a mapping — that
        // threw away a dozen lines of the author's own text with nothing to say
        // why. The identical mistake had already been made once in live preview.
        let text = rendered("---\n编号：N19\n类型：认知\n---\n# 标题\n")
        #expect(text.contains("编号：N19"))
        #expect(text.contains("类型：认知"))
        #expect(!text.contains("---"))

        let yaml = rendered("---\ntags: [a, b]\ntitle: T\n---\nbody\n")
        #expect(yaml.contains("tags: [a, b]"))
        #expect(yaml.contains("title: T"))
    }

    @Test("A comment removes itself and nothing either side of it")
    func removesOnlyTheComment() {
        // `%%like this%%` is the one thing here that is meant to disappear. It
        // used to take its whole line with it, so a line with prose around a
        // comment rendered as nothing at all.
        let text = rendered("正文 %%隐藏的%% 继续")
        #expect(text.contains("正文"))
        #expect(text.contains("继续"))
        #expect(!text.contains("隐藏的"))
    }

    @Test("A callout keeps its title and drops its marker")
    func rendersCallouts() {
        let text = rendered("> [!note] 标题\n> 正文")
        #expect(text.contains("标题"))
        #expect(text.contains("正文"))
        #expect(!text.contains("[!note]"))
    }

    @Test("A table keeps its cells and loses its alignment row")
    func rendersTables() {
        // `| --- | --- |` carries no content — it exists to tell a parser where
        // the header ends. Showing it to a reader is showing them scaffolding.
        let text = rendered("| 列一 | 列二 |\n| --- | --- |\n| 甲 | 乙 |")
        #expect(text.contains("列一"))
        #expect(text.contains("甲"))
        #expect(!text.contains("---"))
    }

    @Test("A display formula keeps its maths and loses its fences")
    func rendersDisplayMath() {
        let text = rendered("$$\nE=mc^2\n$$")
        #expect(text.contains("E=mc^2"))
        #expect(!text.contains("$$"))
    }

    @Test("Nothing an author wrote goes missing")
    func losesNoContent() {
        // The property behind every test above, stated once so a *new* kind of
        // block cannot quietly start eating text. Reading mode may restyle
        // anything and remove syntax; it may not remove words.
        //
        // Two exceptions, both by design rather than by accident, and both kept
        // out of the sample rather than out of the rule: `%%comments%%` are meant
        // to disappear, and an aliased `[[target|shown]]` is meant to show the
        // alias — `rendersLinks` covers that one.
        let markdown = """
        ---
        编号：N19
        tags: [对标, 采集]
        ---
        # 上下文的暗文

        > [!warning] 注意
        > 引用里的正文

        正文有 **加粗**、*斜体*、`代码` 和 [[某个链接]]。

        - [ ] 一个待办
        - 一个项目
        1. 第一步

        | 列一 | 列二 |
        | --- | --- |
        | 甲 | 乙 |

        ```swift
        let answer = 42
        ```

        $$
        E=mc^2
        $$

        结尾一句。
        """
        let text = ReadingRenderer.render(markdown).text

        // Every run of letters, digits or CJK in the source has to survive.
        // Syntax is punctuation, so this is exactly the set that must not move.
        let words = markdown.components(separatedBy: CharacterSet.alphanumerics.union(
            CharacterSet(charactersIn: "\u{4E00}"..."\u{9FFF}")).inverted)
            .filter { $0.count > 1 }

        for word in Set(words) {
            // `md`, `note`, `swift` and friends live only inside markers.
            guard !["swift", "warning", "tags", "true", "false"].contains(word.lowercased()) else { continue }
            #expect(text.contains(word), "\(word.debugDescription) went missing")
        }
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
