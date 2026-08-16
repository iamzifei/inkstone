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

/// Typography defaults are calibrated against Typora's default theme, which is
/// the reference James asked to match. These pin the ratios so a later tweak to
/// one value cannot quietly break the scale.
@Suite("Typography scale")
struct TypographyScaleTests {

    @Test("Heading sizes follow the GitHub/Typora ratios")
    func headingRatios() {
        var typography = Typography()
        typography.editorFontSize = 16

        #expect(typography.headingSize(level: 1) == 36)     // 2.25em
        #expect(typography.headingSize(level: 2) == 28)     // 1.75em
        #expect(typography.headingSize(level: 3) == 24)     // 1.5em
        #expect(typography.headingSize(level: 4) == 20)     // 1.25em
        #expect(typography.headingSize(level: 6) == 16)     // 1em — a label, not emphasis
    }

    @Test("Headings never shrink below body text")
    func headingsNeverSmallerThanBody() {
        // The old modular scale made h6 *larger* than body text; the opposite
        // mistake would be just as wrong.
        var typography = Typography()
        typography.editorFontSize = 16
        for level in 1...6 {
            #expect(typography.headingSize(level: level) >= typography.editorFontSize)
        }
    }

    @Test("Heading sizes decrease monotonically")
    func monotonic() {
        let typography = Typography()
        let sizes = (1...6).map { typography.headingSize(level: $0) }
        #expect(sizes == sizes.sorted(by: >))
    }

    @Test("Out-of-range levels are clamped rather than crashing")
    func clamping() {
        let typography = Typography()
        #expect(typography.headingSize(level: 0) == typography.headingSize(level: 1))
        #expect(typography.headingSize(level: 99) == typography.headingSize(level: 6))
    }
}
