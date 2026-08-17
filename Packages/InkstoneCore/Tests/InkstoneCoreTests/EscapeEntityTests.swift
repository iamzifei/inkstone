import Testing
import Foundation
@testable import InkstoneCore

/// `\*` and `&copy;` are CommonMark, and cmark resolves both into a `Text`
/// node's value without reporting where either came from. They are found again
/// by pattern, which makes the boundaries the whole test: a backslash inside a
/// code span is a backslash, and `&notanentity;` is text.
@Suite("Escapes and entities")
struct EscapeEntityTests {

    private func escapes(_ text: String) -> [String] {
        SyntaxScanner().scan(text).compactMap { token in
            token.kind == .escape ? (text as NSString).substring(with: token.range) : nil
        }
    }

    private func entities(_ text: String) -> [String] {
        SyntaxScanner().scan(text).compactMap { token in
            if case .entity(let replacement) = token.kind { return replacement }
            return nil
        }
    }

    // MARK: - Escapes

    @Test("An escape marks its backslash, and only that")
    func backslashOnly() {
        // The escaped character is already literal text; concealing it too would
        // delete what the author was protecting.
        let text = #"Escaped \*not italic\* here."#
        #expect(escapes(text) == ["\\", "\\"])
    }

    @Test("Only CommonMark's punctuation is escapable")
    func escapableSet() {
        #expect(escapes(#"\*"#) == ["\\"])
        #expect(escapes(#"\_"#) == ["\\"])
        #expect(escapes(##"\#"##) == ["\\"])
        #expect(escapes(#"\\"#) == ["\\"])
        // A backslash before a letter or a space is a literal backslash.
        #expect(escapes(#"\n is not an escape"#).isEmpty)
        #expect(escapes(#"C:\path\to\file"#).isEmpty)
        #expect(escapes(#"a \ b"#).isEmpty)
    }

    @Test("A backslash inside code is a backslash")
    func notInCode() {
        #expect(escapes("`\\*literal\\*`").isEmpty)
        #expect(escapes("```\nlet path = \"\\*\"\n```").isEmpty)
    }

    @Test("An escaped marker is not the marker")
    func escapedMarkerIsNotSyntax() {
        // The point of writing `\*` is that it should not turn into emphasis, and
        // the parser is what guarantees that — the escape token only hides the
        // backslash afterwards.
        let kinds = SyntaxScanner().scan(#"\*not italic\*"#).map(\.kind)
        #expect(!kinds.contains(.italic))
    }

    // MARK: - Entities

    @Test("Named entities decode")
    func named() {
        #expect(entities("&copy; &amp; &hellip;") == ["©", "&", "…"])
    }

    @Test("Numeric entities decode, decimal and hexadecimal")
    func numeric() {
        #expect(entities("&#8212; and &#x2014;") == ["—", "—"])
        #expect(entities("&#20013;") == ["中"])
    }

    @Test("What is not an entity is left alone")
    func notEntities() {
        // Unknown names stay as source, which is what every entity did before
        // this existed — the floor does not move.
        #expect(entities("&fjlig; &notreal;").isEmpty)
        #expect(entities("a & b").isEmpty)
        #expect(entities("&amp no semicolon").isEmpty)
        // A surrogate has no character to stand for.
        #expect(entities("&#xD800;").isEmpty)
        #expect(entities("&#99999999;").isEmpty)
    }

    @Test("An entity inside code is text")
    func entityInCode() {
        #expect(entities("`&copy;`").isEmpty)
        #expect(entities("```\n&copy;\n```").isEmpty)
    }

    @Test("Neither escapes a range past the document")
    func rangesAreInBounds() {
        for text in [#"\*"#, "&copy;", #"trailing \"#, "&", "&#", "&;"] {
            let length = (text as NSString).length
            for token in SyntaxScanner().scan(text) {
                #expect(NSMaxRange(token.range) <= length, "\(token.kind) escaped «\(text)»")
            }
        }
    }
}
