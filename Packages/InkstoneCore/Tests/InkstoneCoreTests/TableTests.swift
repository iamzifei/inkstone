import Testing
import Foundation
@testable import InkstoneCore

/// GFM tables were not scanned at all before, so they rendered as raw pipes in
/// the editor. These tests pin down both halves of the fix: that a table is
/// recognised, and — just as important — that recognising it does not swallow
/// the inline syntax inside its cells.
@Suite("Tables")
struct TableTests {
    private let scanner = SyntaxScanner()

    private func kinds(_ text: String) -> [TokenKind] {
        scanner.scan(text).map(\.kind)
    }

    private func token(_ text: String, _ kind: TokenKind) -> SyntaxToken? {
        scanner.scan(text).first { $0.kind == kind }
    }

    @Test("Recognises a table with its header and alignment rows")
    func recognisesTable() {
        let text = """
        | Area | State |
        | --- | --- |
        | Tables | works |
        """
        let found = kinds(text)
        #expect(found.contains(.table))
        #expect(found.contains(.tableHeaderRow))
        #expect(found.contains(.tableDelimiterRow))
    }

    @Test("Header and alignment rows cover the right text")
    func rowRangesAreCorrect() {
        let text = """
        | Area | State |
        | --- | --- |
        | Tables | works |
        """
        let ns = text as NSString
        let header = token(text, .tableHeaderRow)
        let delimiter = token(text, .tableDelimiterRow)

        #expect(header.map { ns.substring(with: $0.range) } == "| Area | State |")
        #expect(delimiter.map { ns.substring(with: $0.range) } == "| --- | --- |")
    }

    @Test("Alignment colons are accepted")
    func acceptsAlignmentColons() {
        let text = """
        | L | C | R |
        |:--- | :---: | ---:|
        | a | b | c |
        """
        #expect(kinds(text).contains(.table))
    }

    @Test("Inline syntax inside cells is still scanned")
    func cellsKeepInlineSyntax() {
        // The whole point of not masking the table: a cell is ordinary Markdown.
        let text = """
        | Note | Tag |
        | --- | --- |
        | [[Typography Notes]] | #排版 **bold** |
        """
        let found = kinds(text)
        #expect(found.contains(.table))
        #expect(found.contains(.bold))
        #expect(found.contains(where: { if case .wikiLink = $0 { return true }; return false }))
        #expect(scanner.tags(in: text).contains("排版"))
    }

    @Test("A table inside a fenced code block is not a table")
    func codeBlocksWin() {
        let text = """
        ```
        | Area | State |
        | --- | --- |
        ```
        """
        #expect(!kinds(text).contains(.table))
    }

    @Test("Prose containing a pipe is not a table")
    func proseIsNotATable() {
        let text = "Use `a | b` for alternation, or write a | b inline."
        #expect(!kinds(text).contains(.table))
    }

    @Test("A header row without an alignment row is not a table")
    func requiresAlignmentRow() {
        let text = """
        | Area | State |
        | Tables | works |
        """
        #expect(!kinds(text).contains(.table))
    }

    @Test("A table with CJK cells is measured over the whole block")
    func cjkTable() {
        let text = """
        | 项目 | 状态 |
        | --- | --- |
        | 表格 | 可以渲染 |
        | 中英 mixed | ok |
        """
        let table = token(text, .table)
        #expect(table != nil)
        // The block token has to span every row, not just the first two.
        let covered = table.map { (text as NSString).substring(with: $0.range) } ?? ""
        #expect(covered.contains("可以渲染"))
        #expect(covered.contains("中英 mixed"))
    }
}
