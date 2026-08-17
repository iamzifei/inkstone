import Testing
import Foundation
@testable import InkstoneCore

/// Inline HTML comes from cmark's `InlineHTML` nodes, so *finding* a tag is the
/// parser's job and cannot misfire inside code. What is tested here is reading
/// one — and the cases that are not tags at all.
@Suite("Inline HTML")
struct InlineHTMLTests {

    private func tags(_ text: String) -> [String] {
        SyntaxScanner().scan(text).compactMap { token in
            if case .htmlTag(let name, let isClosing) = token.kind {
                return (isClosing ? "/" : "") + name
            }
            return nil
        }
    }

    @Test("Opening and closing tags are told apart")
    func openAndClose() {
        #expect(tags("this is <b>bold</b> text") == ["b", "/b"])
        #expect(tags("<em>a</em> and <strong>b</strong>") == ["em", "/em", "strong", "/strong"])
    }

    @Test("Names are lowercased and stripped of everything else")
    func names() {
        #expect(DocumentScanner.parseTag("<B>")?.name == "b")
        #expect(DocumentScanner.parseTag("<br/>")?.name == "br")
        #expect(DocumentScanner.parseTag(#"<img src="x.png">"#)?.name == "img")
        #expect(DocumentScanner.parseTag(#"<span style="color:red">"#)?.name == "span")
        #expect(DocumentScanner.parseTag("</div>")?.isClosing == true)
        #expect(DocumentScanner.parseTag("<div>")?.isClosing == false)
    }

    @Test("What is not a tag is not read as one")
    func notTags() {
        #expect(DocumentScanner.parseTag("<!-- comment -->") == nil)
        #expect(DocumentScanner.parseTag("<?php ?>") == nil)
        #expect(DocumentScanner.parseTag("<>") == nil)
        #expect(DocumentScanner.parseTag("not a tag") == nil)
    }

    @Test("A tag inside code is text")
    func insideCode() {
        // The parser's doing, not a rule of ours: cmark does not produce inline
        // HTML inside a code span or a fenced block.
        #expect(tags("`<b>bold</b>`").isEmpty)
        #expect(tags("```html\n<b>bold</b>\n```").isEmpty)
    }

    @Test("A less-than that is not markup stays text")
    func notMarkup() {
        #expect(tags("a < b and c > d").isEmpty)
        #expect(tags("5 <3 apples").isEmpty)
    }

    @Test("Tag ranges cover the tag and nothing else")
    func ranges() {
        let text = "x <b>y</b> z"
        let ns = text as NSString
        let slices = SyntaxScanner().scan(text).compactMap { token -> String? in
            if case .htmlTag = token.kind { return ns.substring(with: token.range) }
            return nil
        }
        #expect(slices == ["<b>", "</b>"])
    }
}
