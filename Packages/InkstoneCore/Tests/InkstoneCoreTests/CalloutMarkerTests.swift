import Testing
import Foundation
@testable import InkstoneCore

/// Folding a callout is a text edit, like ticking a checkbox, so the document
/// has to come back byte for byte apart from the one character that changed.
@Suite("Callout markers")
struct CalloutMarkerTests {

    private func header(in text: String) throws -> NSRange {
        let token = try #require(SyntaxScanner().scan(text).first {
            if case .callout = $0.kind { return true }
            return false
        })
        return token.range
    }

    @Test("A callout with no marker collapses")
    func addsMarker() throws {
        let text = "> [!note] Title\n> body\n"
        #expect(try CalloutMarker.toggled(in: text, headerRange: header(in: text))
                == "> [!note]- Title\n> body\n")
    }

    @Test("A collapsed callout expands, and back again")
    func roundTrip() throws {
        let folded = "> [!warning]- Mind the gap\n> body\n"
        let expanded = try #require(CalloutMarker.toggled(in: folded, headerRange: header(in: folded)))
        #expect(expanded == "> [!warning]+ Mind the gap\n> body\n")
        #expect(try CalloutMarker.toggled(in: expanded, headerRange: header(in: expanded)) == folded)
    }

    @Test("Only the marker changes")
    func touchesOneCharacter() throws {
        let text = """
        # Notes

        > [!tip]- A tip
        > with a body
        > over two lines

        Text after, with [brackets] and a [link](url).
        """
        let result = try #require(CalloutMarker.toggled(in: text, headerRange: header(in: text)))
        #expect(result.count == text.count, "an expand swaps a character, it does not add one")
        #expect(result.contains("> [!tip]+ A tip"))
        #expect(result.contains("Text after, with [brackets] and a [link](url)."))
        #expect(result.contains("# Notes"))
    }

    @Test("A callout with no title still folds")
    func noTitle() throws {
        let text = "> [!note]\n> body\n"
        #expect(try CalloutMarker.toggled(in: text, headerRange: header(in: text))
                == "> [!note]-\n> body\n")
    }

    @Test("A range that is not a callout header is rejected")
    func rejectsOtherRanges() {
        let text = "> an ordinary quote\n"
        #expect(CalloutMarker.toggled(in: text, headerRange: NSRange(location: 0, length: 19)) == nil)
        #expect(CalloutMarker.toggled(in: text, headerRange: NSRange(location: 500, length: 4)) == nil)
        #expect(CalloutMarker.toggled(in: text, headerRange: NSRange(location: 0, length: 0)) == nil)
    }

    @Test("The scanner reports the fold state it finds")
    func scannerReportsState() {
        func folded(_ text: String) -> Bool? {
            SyntaxScanner().scan(text).compactMap { token -> Bool? in
                if case .callout(_, let folded, _) = token.kind { return folded }
                return nil
            }.first
        }
        #expect(folded("> [!note]- Folded\n> body\n") == true)
        #expect(folded("> [!note]+ Expanded\n> body\n") == false)
        #expect(folded("> [!note] Plain\n> body\n") == false)
    }
}
