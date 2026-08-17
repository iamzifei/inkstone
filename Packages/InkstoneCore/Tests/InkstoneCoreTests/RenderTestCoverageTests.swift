import Testing
import Foundation
@testable import InkstoneCore

/// `Samples/Render Test/Render Test.md` is the document used to check rendering
/// by eye, on both platforms. Its whole value is being complete, and "complete"
/// is exactly the property that rots silently: a token kind gets added, nobody
/// adds an example, and the manual pass keeps looking fine because nothing on
/// screen is missing — there is simply nothing to miss.
///
/// So the document is checked against `TokenKind` itself. Adding a case without
/// adding an example to the sample fails here.
@Suite("Render test coverage")
struct RenderTestCoverageTests {

    private var document: String {
        get throws {
            let url = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()   // InkstoneCoreTests
                .deletingLastPathComponent()   // Tests
                .deletingLastPathComponent()   // InkstoneCore
                .deletingLastPathComponent()   // Packages
                .deletingLastPathComponent()   // repository root
                .appendingPathComponent("Samples/Render Test/Render Test.md")
            return try String(contentsOf: url, encoding: .utf8)
        }
    }

    /// The kinds the sample must contain at least one of, named the way the
    /// failure message should read.
    private func label(_ kind: TokenKind) -> String {
        switch kind {
        case .heading(let level): return "heading(\(level))"
        case .codeBlock(let language): return language == nil ? "codeBlock" : "codeBlock(\(language!))"
        case .listMarker(_, let ordered): return ordered ? "orderedListMarker" : "bulletListMarker"
        case .task(let checked, _): return checked ? "task(checked)" : "task(unchecked)"
        case .blockquote: return "blockquote"
        case .wikiLink: return "wikiLink"
        case .embed: return "embed"
        case .markdownLink: return "markdownLink"
        case .tag: return "tag"
        case .callout: return "callout"
        case .blockIdentifier: return "blockIdentifier"
        case .footnoteReference: return "footnoteReference"
        case .footnoteDefinition: return "footnoteDefinition"
        case .entity: return "entity"
        case .htmlTag: return "htmlTag"
        default: return String(describing: kind)
        }
    }

    @Test("Every token kind has an example in the sample document")
    func coversEveryKind() throws {
        let found = Set(SyntaxScanner().scan(try document).map { label($0.kind) })

        // Written out rather than derived: `TokenKind` is not `CaseIterable` and
        // could not be, since several cases carry values. Listing them means a
        // new case has to be added here consciously.
        let required = [
            "heading(1)", "heading(2)", "heading(3)", "heading(4)", "heading(5)", "heading(6)",
            "bold", "italic", "strikethrough", "highlight", "inlineCode",
            "codeBlock", "codeBlock(swift)", "codeBlock(mermaid)",
            "mathInline", "mathBlock",
            "wikiLink", "embed", "markdownLink",
            "tag", "blockIdentifier",
            "callout", "blockquote",
            "bulletListMarker", "orderedListMarker",
            "task(checked)", "task(unchecked)",
            "comment", "horizontalRule", "frontmatter",
            "footnoteReference", "footnoteDefinition",
            "tableOfContents", "superscript", "subscript",
            "table", "tableHeaderRow", "tableDelimiterRow",
            "escape", "entity", "htmlTag",
        ]

        let missing = required.filter { !found.contains($0) }
        #expect(missing.isEmpty, "no example in Render Test.md for: \(missing.sorted().joined(separator: ", "))")
    }

    @Test("No token escapes the document")
    func rangesAreInBounds() throws {
        // The sample is the most syntactically dense document in the repository,
        // which makes it the best fuzz case we have for range arithmetic — and a
        // range past the end of the storage is a crash, not a wrong colour.
        let text = try document
        let length = (text as NSString).length
        for token in SyntaxScanner().scan(text) {
            #expect(token.range.location >= 0)
            #expect(NSMaxRange(token.range) <= length, "\(token.kind) escaped the document")
            #expect(token.contentRange.location >= token.range.location)
            #expect(NSMaxRange(token.contentRange) <= NSMaxRange(token.range))
        }
    }

    @Test("Nothing inside a code block is styled")
    func negativeCasesHold() throws {
        // Section 13 of the sample deliberately puts Markdown inside fences. If
        // any of it is picked up, the sample is documenting a bug rather than
        // testing for one.
        let tokens = SyntaxScanner().scan(try document)
        let tags = tokens.compactMap { token -> String? in
            if case .tag(let name) = token.kind { return name }
            return nil
        }
        #expect(!tags.contains("nottag"), "a tag inside a code block was scanned")

        let links = SyntaxScanner().links(in: try document).map(\.target)
        #expect(!links.contains("not a wikilink"), "a wikilink inside a code block was scanned")
        #expect(!links.contains("not a link"), "a wikilink inside an inline code span was scanned")
    }
}
