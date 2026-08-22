import Testing
import Foundation
import Markdown
@testable import InkstoneCore

/// cmark reports positions as 1-based line and 1-based **UTF-8 byte** column;
/// TextKit wants 0-based UTF-16 offsets. Every range the new parser produces goes
/// through this conversion, so an error here is an error everywhere — and it is
/// invisible in an English-only test, which is exactly why these are mostly
/// Chinese.
@Suite("Source map")
struct SourceMapTests {

    /// The substring a cmark-style position pair addresses.
    private func slice(
        _ text: String, _ from: (Int, Int), _ to: (Int, Int)
    ) -> String {
        let map = SourceMap(text)
        let range = map.range(fromLine: from.0, fromColumn: from.1, toLine: to.0, toColumn: to.1)
        return (text as NSString).substring(with: range)
    }

    @Test("ASCII columns are a plain offset")
    func ascii() {
        #expect(slice("hello world", (1, 1), (1, 6)) == "hello")
        #expect(slice("hello world", (1, 7), (1, 12)) == "world")
    }

    @Test("A Chinese line maps by bytes, not characters")
    func chinese() {
        // 中文abc — 6 characters, 6 UTF-16 units, 10 UTF-8 bytes.
        // Counting characters would make column 11 land past the end.
        #expect(slice("中文abc tail", (1, 1), (1, 7)) == "中文")
        #expect(slice("中文abc tail", (1, 7), (1, 10)) == "abc")
    }

    @Test("Positions on later lines are offset correctly")
    func multipleLines() {
        let text = "第一行\nsecond\n第三行 third\n"
        #expect(slice(text, (2, 1), (2, 7)) == "second")
        #expect(slice(text, (3, 1), (3, 10)) == "第三行")
        #expect(slice(text, (3, 11), (3, 16)) == "third")
    }

    @Test("Emoji are four bytes and two UTF-16 units")
    func emoji() {
        // A surrogate pair: the two coordinate systems disagree in both directions.
        let text = "a🌏b"
        #expect(slice(text, (1, 2), (1, 6)) == "🌏")
        #expect(slice(text, (1, 6), (1, 7)) == "b")
    }

    @Test("A column past the end of a line clamps to the line end")
    func clamping() {
        // cmark reports an exclusive end column one past the last byte, and for an
        // unterminated fence it reports a line that does not exist.
        let text = "abc\n"
        #expect(slice(text, (1, 1), (1, 99)) == "abc\n")
        #expect(slice(text, (99, 1), (99, 5)) == "")
        #expect(slice(text, (0, 0), (1, 4)) == "abc")
    }

    @Test("A line's content range excludes its newline")
    func lineContent() {
        let text = "one\ntwo\n"
        let map = SourceMap(text)
        let ns = text as NSString
        #expect(ns.substring(with: map.lineRange(1)) == "one\n")
        #expect(ns.substring(with: map.lineContentRange(1)) == "one")
        #expect(ns.substring(with: map.lineContentRange(2)) == "two")
    }

    @Test("CRLF line endings do not shift columns")
    func crlf() {
        // A CR is one byte and one UTF-16 unit, so it costs nothing — but it must
        // not be counted as part of the next line.
        let text = "alpha\r\nbeta\r\n"
        #expect(slice(text, (2, 1), (2, 5)) == "beta")
    }

    // MARK: - Against the real parser

    /// The point of the map is to agree with cmark, so the strongest test asks
    /// cmark for the positions rather than asserting hand-written ones.
    private func parsedSlices(_ text: String) -> [String] {
        let map = SourceMap(text)
        let ns = text as NSString
        var slices: [String] = []

        func walk(_ markup: Markup) {
            if let range = markup.range, markup.childCount == 0 || markup is InlineMarkup {
                let converted = map.range(
                    fromLine: range.lowerBound.line, fromColumn: range.lowerBound.column,
                    toLine: range.upperBound.line, toColumn: range.upperBound.column
                )
                slices.append(ns.substring(with: converted))
            }
            for child in markup.children { walk(child) }
        }
        walk(Document(parsing: text))
        return slices
    }

    @Test("Inline node ranges round-trip through the map")
    func roundTripsAgainstCmark() {
        // Each of these is a case where byte and UTF-16 offsets diverge partway
        // along the line, so a wrong conversion shifts everything after it.
        let slices = parsedSlices("中文abc **粗体** tail")
        #expect(slices.contains("**粗体**"))
        #expect(slices.contains("粗体"))
        #expect(slices.contains("中文abc "))
        #expect(slices.contains(" tail"))
    }

    @Test("Table cell ranges round-trip through the map")
    func tableCellsRoundTrip() {
        let text = """
        | 项目 | 状态 |
        | --- | --- |
        | 表格 | 可以渲染 |
        """
        let slices = parsedSlices(text)
        #expect(slices.contains("项目"))
        #expect(slices.contains("可以渲染"))
    }

    @Test("Emoji mid-line do not shift the ranges after them")
    func emojiRoundTrip() {
        let slices = parsedSlices("see 🌏 then *emphasis* here")
        #expect(slices.contains("*emphasis*"))
        #expect(slices.contains("emphasis"))
    }
}
