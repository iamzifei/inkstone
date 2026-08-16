import Testing
import Foundation
@testable import InkstoneCore

/// Lists and blockquotes had `TokenKind` cases but no scanner patterns, so the
/// editor showed their `-` and `>` markers raw. These tests pin the patterns and,
/// just as importantly, the boundaries against task items and horizontal rules.
@Suite("Block elements")
struct BlockTests {
    private let scanner = SyntaxScanner()

    private func tokens(_ text: String) -> [SyntaxToken] { scanner.scan(text) }

    private func listMarkers(_ text: String) -> [(level: Int, ordered: Bool)] {
        tokens(text).compactMap {
            if case .listMarker(let level, let ordered) = $0.kind { return (level, ordered) }
            return nil
        }
    }

    private func quoteDepths(_ text: String) -> [Int] {
        tokens(text).compactMap {
            if case .blockquote(let depth) = $0.kind { return depth }
            return nil
        }
    }

    @Test("Bullets are found at their nesting level")
    func bullets() {
        let found = listMarkers("- one\n- two\n  - nested\n    - deeper")
        #expect(found.count == 4)
        #expect(found.map(\.level) == [0, 0, 1, 2])
        #expect(found.allSatisfy { !$0.ordered })
    }

    @Test("Ordered markers are flagged as ordered")
    func ordered() {
        let found = listMarkers("1. one\n2) two\n- bullet")
        #expect(found.map(\.ordered) == [true, true, false])
    }

    @Test("A tab indent counts as one level")
    func tabIndent() {
        #expect(listMarkers("\t- indented").map(\.level) == [1])
    }

    @Test("Task items are not also bullets")
    func tasksAreNotBullets() {
        // Otherwise a task would render a checkbox *and* a bullet.
        let text = "- [ ] a task\n- [x] done\n- a plain bullet"
        #expect(listMarkers(text).count == 1)
        #expect(tokens(text).contains { if case .task = $0.kind { return true }; return false })
    }

    @Test("Quote depth counts the markers")
    func quotes() {
        #expect(quoteDepths("> one\n> > nested\n>>> three") == [1, 2, 3])
    }

    @Test("A horizontal rule is not a list")
    func horizontalRuleIsNotAList() {
        // `---` must stay a rule; the bullet pattern requires a space after the
        // marker, which is what keeps these apart.
        let found = tokens("---")
        #expect(found.contains { if case .horizontalRule = $0.kind { return true }; return false })
        #expect(listMarkers("---").isEmpty)
    }

    @Test("Markers inside a fenced code block are ignored")
    func codeBlocksWin() {
        let text = "```\n- not a bullet\n> not a quote\n```"
        #expect(listMarkers(text).isEmpty)
        #expect(quoteDepths(text).isEmpty)
    }

    @Test("A hyphen mid-sentence is not a list marker")
    func inlineHyphen() {
        #expect(listMarkers("well - actually, no").isEmpty)
    }

    @Test("A callout's content range points at its title")
    func calloutTitle() {
        let text = "> [!warning] Mind the gap"
        let ns = text as NSString
        let callout = tokens(text).first { if case .callout = $0.kind { return true }; return false }
        #expect(callout.map { ns.substring(with: $0.contentRange) } == "Mind the gap")
    }

    @Test("A callout with no title still has a usable range")
    func calloutWithoutTitle() {
        let callout = tokens("> [!note]").first { if case .callout = $0.kind { return true }; return false }
        #expect(callout != nil)
        #expect(callout?.contentRange.length == 0)
    }
}
