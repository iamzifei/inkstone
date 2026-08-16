import Testing
import Foundation
@testable import InkstoneCore

/// Footnotes, superscript and subscript — the Typora syntax that was missing.
/// The boundaries matter most here: these markers all collide with something
/// else in Markdown, and getting one wrong silently eats the other.
@Suite("Footnotes and scripts")
struct FootnoteTests {
    private let scanner = SyntaxScanner()

    private func kinds(_ text: String) -> [TokenKind] { scanner.scan(text).map(\.kind) }

    private func ids(_ text: String, definitions: Bool) -> [String] {
        scanner.scan(text).compactMap {
            switch $0.kind {
            case .footnoteDefinition(let id) where definitions: return id
            case .footnoteReference(let id) where !definitions: return id
            default: return nil
            }
        }
    }

    // MARK: - Footnotes

    @Test("A reference in the body is found")
    func reference() {
        #expect(ids("Some claim[^1] needs support.", definitions: false) == ["1"])
    }

    @Test("A definition at the start of a line is found")
    func definition() {
        #expect(ids("[^1]: The source.", definitions: true) == ["1"])
    }

    @Test("A definition's own marker is not also a reference")
    func definitionIsNotAReference() {
        // Otherwise every footnote would render its definition as a link to
        // itself, and the numbering would double.
        let text = "[^note]: The source."
        #expect(ids(text, definitions: true) == ["note"])
        #expect(ids(text, definitions: false).isEmpty)
    }

    @Test("Named footnotes work, not just numbers")
    func namedFootnotes() {
        let text = "See[^why].\n\n[^why]: Because."
        #expect(ids(text, definitions: false) == ["why"])
        #expect(ids(text, definitions: true) == ["why"])
    }

    @Test("An ordinary link is not a footnote")
    func ordinaryLinkUnaffected() {
        let found = kinds("A [link](https://example.com) and [[Wiki]].")
        #expect(!found.contains { if case .footnoteReference = $0 { return true }; return false })
    }

    // MARK: - Superscript and subscript

    @Test("Superscript and subscript are recognised")
    func scripts() {
        #expect(kinds("2^10^ and H~2~O").contains(.superscript))
        #expect(kinds("2^10^ and H~2~O").contains(.subscript))
    }

    @Test("Strikethrough is not read as two subscripts")
    func strikethroughWins() {
        // `~~gone~~` must stay a single strikethrough; a greedy subscript rule
        // would split it into `~` + `gone` + `~`.
        let found = kinds("~~gone~~")
        #expect(found.contains(.strikethrough))
        #expect(!found.contains(.subscript))
    }

    @Test("A caret with spaces around it is arithmetic, not superscript")
    func caretWithSpaces() {
        #expect(!kinds("a ^ b").contains(.superscript))
    }

    @Test("Markers inside code are ignored")
    func codeWins() {
        let text = "`H~2~O` and a fence:\n\n```\nx^2^\n```"
        #expect(!kinds(text).contains(.superscript))
        #expect(!kinds(text).contains(.subscript))
    }

    @Test("Content ranges point at the text, not the markers")
    func contentRanges() {
        let text = "H~2~O"
        let ns = text as NSString
        let token = scanner.scan(text).first { $0.kind == .subscript }
        #expect(token.map { ns.substring(with: $0.contentRange) } == "2")
    }
}

@Suite("Table of contents")
struct TOCTests {
    private let scanner = SyntaxScanner()

    private func hasTOC(_ text: String) -> Bool {
        scanner.scan(text).contains { $0.kind == .tableOfContents }
    }

    @Test("[TOC] alone on a line is recognised, in either case")
    func recognised() {
        #expect(hasTOC("# Title\n\n[TOC]\n\nBody"))
        #expect(hasTOC("[toc]"))
    }

    @Test("A bracketed word mid-sentence is not a TOC")
    func notInline() {
        // Otherwise a sentence mentioning [TOC] would sprout a table of contents.
        #expect(!hasTOC("The [TOC] marker generates a table of contents."))
    }

    @Test("A wikilink that merely looks similar is left alone")
    func wikilinkUnaffected() {
        #expect(!hasTOC("[[TOC]]"))
    }

    @Test("A TOC inside a code fence is not a TOC")
    func codeWins() {
        #expect(!hasTOC("```\n[TOC]\n```"))
    }
}
