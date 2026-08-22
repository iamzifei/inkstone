import Testing
import Foundation
@testable import InkstoneCore

/// Runs both scanner engines over the same documents and compares their token
/// streams position by position.
///
/// The port from thirty regexes to a cmark parse is a behaviour change wearing a
/// refactor's clothes. Every difference between the engines is either a bug fixed
/// or a bug introduced, and nothing about the diff itself says which — so each one
/// is listed below with a verdict and a reason. A difference that is *not* on the
/// list fails the test, which is the whole point: silent drift is what a rewrite
/// of a 488-line scanner would otherwise produce.
@Suite("Engine diff")
struct EngineDiffTests {

    private let parser = SyntaxScanner(engine: .parser)
    private let legacy = SyntaxScanner(engine: .legacy)

    /// A token reduced to what a diff should care about: what it is and where.
    /// Two tokens of the same kind at the same place are the same token, whatever
    /// the two engines had to do to find it.
    private struct Key: Hashable, CustomStringConvertible {
        let kind: String
        let location: Int
        let length: Int

        init(_ token: SyntaxToken) {
            // The associated values are deliberately kept: a `.heading(level: 2)`
            // where the other engine says level 3 is a difference worth failing on.
            kind = String(describing: token.kind)
            location = token.range.location
            length = token.range.length
        }

        var description: String { "\(kind)@\(location)+\(length)" }
    }

    private struct Difference {
        let document: String
        let onlyInParser: [Key]
        let onlyInLegacy: [Key]
        var isEmpty: Bool { onlyInParser.isEmpty && onlyInLegacy.isEmpty }
    }

    private func diff(_ text: String, named name: String) -> Difference {
        let new = Set(parser.scan(text).map(Key.init))
        let old = Set(legacy.scan(text).map(Key.init))
        return Difference(
            document: name,
            onlyInParser: new.subtracting(old).sorted { $0.location < $1.location },
            onlyInLegacy: old.subtracting(new).sorted { $0.location < $1.location }
        )
    }

    private func report(_ difference: Difference) -> String {
        var lines = ["\(difference.document):"]
        for key in difference.onlyInParser { lines.append("  + \(key)") }
        for key in difference.onlyInLegacy { lines.append("  - \(key)") }
        return lines.joined(separator: "\n")
    }

    // MARK: - Documents the two engines must agree on exactly

    /// Constructs where both engines are known to be right, so any difference is
    /// a porting mistake.
    static let agreed: [(String, String)] = [
        ("plain prose", "Just a sentence, and another one.\n\nA second paragraph.\n"),
        ("headings", "# One\n\n## Two\n\n### Three\n"),
        ("emphasis", "Some **bold**, some *italic*, some ~~struck~~, some `code`.\n"),
        ("wikilinks", "See [[Typography Notes]] and [[Ideas/Product Ideas|产品想法]].\n"),
        ("embeds", "An image: ![[diagram.png]] and a note: ![[Home]].\n"),
        ("tags", "Tagged #design and #design/typography and #中文标签 here.\n"),
        ("fenced code", "```swift\nlet x = 1  // #nottag [[notlink]]\n```\n"),
        ("table", "| Area | State |\n| --- | --- |\n| Tables | works |\n"),
        ("cjk table", "| 项目 | 状态 |\n| --- | --- |\n| 表格 | 可以渲染 |\n"),
        ("quotes", "> one\n> > nested\n>>> three\n"),
        ("callout", "> [!warning] Mind the gap\n> body text\n"),
        ("tasks", "- [ ] open\n- [x] done\n- plain bullet\n"),
        ("nested tasks", "- [ ] top\n  - [ ] nested\n    - [x] deeper\n"),
        ("frontmatter", "---\ntags: [a, b]\ntitle: 中文\n---\n\n# Body\n\nText.\n"),
        ("math", "Inline $x^2$ and a block:\n\n$$\n\\int_0^1 x\\,dx\n$$\n"),
        ("highlight", "Some ==marked text== in a line.\n"),
        ("footnotes", "A claim[^1] here.\n\n[^1]: The source, with more words after it.\n"),
        ("horizontal rule", "before\n\n---\n\nafter\n"),
        ("comment", "Visible %%hidden note%% visible.\n"),
        ("block id", "A paragraph worth linking to. ^my-block\n"),
        ("toc", "# Title\n\n[TOC]\n\n## Section\n"),
        ("cjk prose", "中文段落，里面有 **粗体** 和 `代码` 和 [[链接]]。\n"),
        ("mixed", """
        ---
        tags: [demo]
        ---

        # 标题 with #tag

        A paragraph with **bold**, *italic*, `inline`, [[Wiki]], $x$ and ==mark==.

        - [ ] a task
        - a bullet
          - nested

        > [!note] Callout
        > with body

        | A | B |
        | --- | --- |
        | 1 | 2 |

        ```python
        # not a tag
        print("[[not a link]]")
        ```

        Final line.[^n]

        [^n]: A footnote with several words so it is not a link definition.
        """),
    ]

    @Test("The engines agree on ordinary documents", arguments: agreed)
    func agreement(name: String, text: String) {
        let difference = diff(text, named: name)
        #expect(difference.isEmpty, "\(report(difference))")
    }

    @Test("The engines agree on the sample vault")
    func sampleVault() throws {
        let vault = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // InkstoneCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // InkstoneCore
            .deletingLastPathComponent()   // Packages
            .deletingLastPathComponent()   // repository root
            .appendingPathComponent("Samples/Inkstone Demo")

        let files = try FileManager.default
            .subpathsOfDirectory(atPath: vault.path)
            .filter { $0.hasSuffix(".md") }
        #expect(!files.isEmpty, "the sample vault should still be at \(vault.path)")

        for file in files {
            let text = try String(contentsOf: vault.appendingPathComponent(file), encoding: .utf8)
            let difference = diff(text, named: file)
            #expect(difference.isEmpty, "\(report(difference))")
        }
    }

    // MARK: - Documents where the engines are meant to disagree

    /// Each case here is a difference that was found by the diff, looked at, and
    /// judged. The expectation is written as "the parser finds this and the legacy
    /// scanner does not" (or the reverse), so if the behaviour ever reverts the
    /// test fails just as loudly as an unexplained difference would.

    @Test("A tag inside a code fence is a fix, not a regression")
    func tagInsideFence() {
        // The legacy scanner masked code by matching a fence pattern, and the
        // pattern could take the closing fence's newline with it — after which
        // the mask ended early and the text after it was scanned as prose. The
        // parser has no such failure mode: it is not looking for a fence, it
        // knows where the code block ends.
        let text = "```\n#nottag\n```\n\n#realtag\n"
        #expect(parser.tags(in: text) == ["realtag"])
        #expect(legacy.tags(in: text) == ["realtag"])

        // Where they part company: an indented code block, which the legacy
        // scanner has no pattern for at all.
        let indented = "Prose:\n\n    #nottag in indented code\n"
        #expect(parser.tags(in: indented).isEmpty)
        #expect(legacy.tags(in: indented) == ["nottag"], "legacy wrongly finds it")
    }

    @Test("A heading containing inline code is found only by the parser")
    func headingWithCode() {
        // A legacy bug, and a whole class of them. The old scanner masked inline
        // code before it looked for block constructs, and then skipped any match
        // that touched the mask — so *every* heading, list item or quote
        // containing a `code span` was dropped entirely and rendered as body
        // text. The parser finds the heading first and the code inside it after,
        // because that is the actual structure.
        let text = "### Three with `code`\n"
        #expect(parser.scan(text).contains { $0.kind == .heading(level: 3) })
        #expect(!legacy.scan(text).contains { if case .heading = $0.kind { return true }; return false })

        // Both still find the code span itself; only the heading was lost.
        #expect(parser.scan(text).contains { $0.kind == .inlineCode })
        #expect(legacy.scan(text).contains { $0.kind == .inlineCode })
    }

    @Test("Escapes and entities are found only by the parser")
    func escapesAndEntities() {
        // Both are CommonMark, and the legacy scanner had no pattern for either:
        // a `\*` kept its backslash on screen and `&copy;` stayed as five
        // characters of source.
        let text = #"An escape \*not italic\* and an entity &copy; here."#
        #expect(parser.scan(text).contains { $0.kind == .escape })
        #expect(!legacy.scan(text).contains { $0.kind == .escape })
        #expect(parser.scan(text).contains { if case .entity = $0.kind { return true }; return false })
        #expect(!legacy.scan(text).contains { if case .entity = $0.kind { return true }; return false })

        // And the legacy scanner read the escaped asterisks as emphasis, which is
        // exactly what escaping them was meant to prevent.
        #expect(!parser.scan(text).contains { $0.kind == .italic })
        #expect(legacy.scan(text).contains { $0.kind == .italic }, "legacy wrongly emphasises")
    }

    @Test("Underscore emphasis is found only by the parser")
    func underscoreEmphasis() {
        // The legacy pattern matched `*` only, so `_italic_` rendered raw.
        let text = "Some _emphasis_ here.\n"
        #expect(parser.scan(text).contains { $0.kind == .italic })
        #expect(!legacy.scan(text).contains { $0.kind == .italic })
    }

    @Test("A setext heading is found only by the parser")
    func setextHeading() {
        // `Title\n=====` is a heading in every Markdown parser. The legacy
        // scanner's heading pattern is ATX-only, so it saw a paragraph — and, for
        // the `---` form, a horizontal rule.
        let text = "Title\n=====\n\nBody.\n"
        #expect(parser.scan(text).contains { $0.kind == .heading(level: 1) })
        #expect(!legacy.scan(text).contains { if case .heading = $0.kind { return true }; return false })
    }

    @Test("A tab-indented item with no parent list is code, not a list")
    func tabIndentedItem() {
        // CommonMark: four spaces or a tab at the start of a block is an indented
        // code block, and `- indented` inside one is not a list. The legacy
        // pattern matched the bullet wherever it appeared and reported nesting
        // level 1. The parser is right and this is a deliberate change — but it
        // only bites for an item with no list above it, which is malformed
        // anyway; a tab-indented item *under* a list still nests.
        let orphan = "\t- indented\n"
        #expect(!parser.scan(orphan).contains { if case .listMarker = $0.kind { return true }; return false })
        #expect(legacy.scan(orphan).contains { if case .listMarker = $0.kind { return true }; return false })

        let nested = "- parent\n\t- child\n"
        let levels = parser.scan(nested).compactMap { token -> Int? in
            if case .listMarker(let level, _) = token.kind { return level }
            return nil
        }
        #expect(levels == [0, 1], "a tab-indented item under a list still nests")
    }

    @Test("A pipe table without outer pipes is found only by the parser")
    func pipelessTable() {
        // The legacy pattern required leading and trailing pipes because without
        // them it could not tell a table from prose containing a `|`. GFM allows
        // the bare form and the parser handles it correctly, because it is
        // parsing rather than pattern-matching.
        let text = "A | B\n--- | ---\n1 | 2\n"
        #expect(parser.scan(text).contains { $0.kind == .table })
        #expect(!legacy.scan(text).contains { $0.kind == .table })
    }

    @Test("Emphasis spanning a code span is not emphasis")
    func emphasisAcrossCode() {
        // The legacy inline patterns did not know where code spans were when they
        // ran, so a `*` on either side of one paired up across it.
        let text = "a * b `c * d` e\n"
        #expect(!parser.scan(text).contains { $0.kind == .italic })
    }

    // MARK: - Fuzzing for crashes and range corruption

    @Test("Neither engine produces a range outside the document")
    func rangesAreInBounds() {
        // Ranges go straight into `NSTextStorage.addAttribute`, where one past
        // the end is not a wrong colour, it is a crash. Worth checking on exactly
        // the inputs that make range arithmetic hard: CJK, emoji, truncated
        // syntax, and no trailing newline.
        let documents = Self.agreed.map(\.1) + [
            "中文**粗**体🌏 and `code` [[链接]] #标签",
            "```swift\nunterminated fence with 中文",
            "| 中 | 文 |\n| --- | --- |\n| 🌏 | x",
            "$$\n中文公式\n",
            "- [ ] 任务🌏\n\t- [x] 子任务",
            "> [!注意] 中文标注\n> 内容",
            "#",
            "```",
            "|",
            "[[",
            "$",
            "---\n",
            "\n\n\n",
            "a\r\nb\r\n",
        ]

        for text in documents {
            let length = (text as NSString).length
            for engine in [parser, legacy] {
                for token in engine.scan(text) {
                    #expect(token.range.location >= 0)
                    #expect(NSMaxRange(token.range) <= length, "\(token.kind) escaped \(length) in «\(text.prefix(40))»")
                    #expect(token.contentRange.location >= 0)
                    #expect(NSMaxRange(token.contentRange) <= length)
                    #expect(NSMaxRange(token.contentRange) <= NSMaxRange(token.range))
                    #expect(token.contentRange.location >= token.range.location)
                }
            }
        }
    }

    @Test("Scanning any prefix of a document neither crashes nor escapes it")
    func incrementalPrefixes() {
        // Approximates typing: every prefix of a document is a document that the
        // editor will scan while it is being written, and half-finished syntax is
        // where a scanner is most likely to produce a range it should not.
        let full = Self.agreed.first { $0.0 == "mixed" }!.1
        let ns = full as NSString
        for end in stride(from: 0, through: ns.length, by: 7) {
            let prefix = ns.substring(to: end)
            for token in parser.scan(prefix) {
                #expect(NSMaxRange(token.range) <= end, "\(token.kind) escaped at prefix length \(end)")
            }
        }
    }
}
