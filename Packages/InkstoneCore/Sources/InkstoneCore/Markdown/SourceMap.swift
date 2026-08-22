import Foundation

/// Converts cmark source positions into the UTF-16 ranges TextKit works in.
///
/// The two coordinate systems do not agree on anything. cmark reports a position
/// as a 1-based line and a 1-based **UTF-8 byte** column; `NSAttributedString`
/// addresses text by 0-based UTF-16 offset. For pure ASCII those differ only by
/// the off-by-one, which is why the mistake is easy to make and invisible in
/// tests written in English. They diverge the moment a note contains Chinese:
///
///     中文abc          6 characters, 6 UTF-16 units, 10 UTF-8 bytes
///
/// so a naive `column - 1` puts every range on a Chinese line in the wrong place,
/// and increasingly so as the line goes on.
///
/// Building this map costs one pass over the text. Lookups are O(1) on ASCII
/// lines — the overwhelming majority, even in a Chinese note, because headings,
/// list markers, code and tables are ASCII — and O(line length) otherwise.
struct SourceMap {
    /// The text this map describes, for callers that need to slice out a substring
    /// or hand it to `NSRegularExpression`.
    let text: NSString

    /// The same text as a flat UTF-16 buffer.
    ///
    /// The scan probes individual characters constantly — counting `>` markers,
    /// finding a fence, walking back over an indent, stripping backticks — and
    /// every one of those through `NSString.character(at:)` is a bridged call.
    /// Copying the text into an array once turns all of them into an array
    /// subscript, and pays for itself several times over on a note of any size.
    private let units: [UInt16]

    /// Per line, in source order. Index 0 is line 1.
    private struct Line {
        /// UTF-16 offset of the line's first character.
        let utf16Start: Int
        /// Number of UTF-16 units in the line, including its newline.
        let utf16Length: Int
        /// True when every unit of the line is ASCII, so a UTF-8 column maps to a
        /// UTF-16 offset by subtraction alone.
        let isASCII: Bool
    }

    private let lines: [Line]

    init(_ text: String) {
        self.init(text as NSString)
    }

    init(_ text: NSString) {
        self.text = text
        let units = Array(String(text).utf16)
        self.units = units

        var lines: [Line] = []
        // Reserve roughly one line per 40 characters; wrong either way is cheap,
        // but the default growth pattern on a 200KB note is not.
        lines.reserveCapacity(max(8, units.count / 40))

        // One pass, finding line breaks and noting whether each line is ASCII at
        // the same time. Deliberately not `NSString.lineRange(for:)` per line:
        // that is a bridged call per line, and on a 3000-line note it dominated
        // the cost of building this map.
        var lineStart = 0
        var isASCII = true
        var index = 0
        while index < units.count {
            let unit = units[index]
            if unit > 0x7F { isASCII = false }
            index += 1
            if unit == 0x0A || (unit == 0x0D && (index >= units.count || units[index] != 0x0A)) {
                lines.append(Line(utf16Start: lineStart, utf16Length: index - lineStart, isASCII: isASCII))
                lineStart = index
                isASCII = true
            } else if unit == 0x0D, index < units.count, units[index] == 0x0A {
                // CRLF is one break, not two.
                index += 1
                lines.append(Line(utf16Start: lineStart, utf16Length: index - lineStart, isASCII: isASCII))
                lineStart = index
                isASCII = true
            }
        }
        if lineStart < units.count {
            lines.append(Line(utf16Start: lineStart, utf16Length: units.count - lineStart, isASCII: isASCII))
        }
        // A document ending in a newline has an empty final line that the loop
        // never yields, but cmark will happily report a position on it. Give it
        // somewhere to land.
        lines.append(Line(utf16Start: units.count, utf16Length: 0, isASCII: true))

        self.lines = lines
    }

    /// The UTF-16 unit at `offset`, or 0 past the end.
    func unit(at offset: Int) -> UInt16 {
        guard offset >= 0, offset < units.count else { return 0 }
        return units[offset]
    }

    var length: Int { units.count }

    /// UTF-16 offset for a 1-based line and a 1-based UTF-8 byte column.
    ///
    /// Out-of-range positions are clamped rather than trapped. cmark reports
    /// positions one past the end of a line for a block that runs to the line's
    /// end, and a fenced block left unterminated at end of file reports a line
    /// that does not exist; neither is a programming error worth crashing over.
    func utf16Offset(line: Int, column: Int) -> Int {
        guard line >= 1 else { return 0 }
        guard line <= lines.count else { return units.count }
        let entry = lines[line - 1]
        let byteOffset = max(0, column - 1)

        if entry.isASCII {
            return min(entry.utf16Start + byteOffset, entry.utf16Start + entry.utf16Length)
        }

        // Walk the line, spending UTF-8 bytes and accumulating UTF-16 units, until
        // the byte budget is used up. Deliberately per-scalar rather than per
        // character: a grapheme cluster can span several scalars, and cmark counts
        // the bytes of each independently.
        var remainingBytes = byteOffset
        var utf16Offset = entry.utf16Start
        let end = entry.utf16Start + entry.utf16Length

        while utf16Offset < end, remainingBytes > 0 {
            let unit = units[utf16Offset]
            let scalarUTF16Width: Int
            let scalarUTF8Width: Int

            if UTF16.isLeadSurrogate(unit), utf16Offset + 1 < end,
               UTF16.isTrailSurrogate(units[utf16Offset + 1]) {
                // A surrogate pair — an emoji or a rare CJK ideograph. One scalar,
                // two UTF-16 units, four UTF-8 bytes.
                scalarUTF16Width = 2
                scalarUTF8Width = 4
            } else {
                scalarUTF16Width = 1
                scalarUTF8Width = Self.utf8Width(of: unit)
            }

            // A column landing *inside* a multi-byte scalar cannot be represented,
            // and cmark should never report one. If it does, round down to the
            // scalar's start rather than splitting it.
            if scalarUTF8Width > remainingBytes { break }

            remainingBytes -= scalarUTF8Width
            utf16Offset += scalarUTF16Width
        }

        return utf16Offset
    }

    /// Number of UTF-8 bytes a single (non-surrogate) UTF-16 unit encodes to.
    private static func utf8Width(of unit: UInt16) -> Int {
        if unit < 0x80 { return 1 }
        if unit < 0x800 { return 2 }
        return 3
    }

    /// UTF-16 range spanned by a cmark `SourceRange`-style pair of positions.
    ///
    /// cmark's end position is **exclusive**, which is what lets a node that runs
    /// to the end of a line report a column one past the last byte.
    func range(
        fromLine: Int, fromColumn: Int,
        toLine: Int, toColumn: Int
    ) -> NSRange {
        let start = utf16Offset(line: fromLine, column: fromColumn)
        let end = utf16Offset(line: toLine, column: toColumn)
        guard end > start else { return NSRange(location: min(start, units.count), length: 0) }
        return NSRange(location: start, length: min(end, units.count) - start)
    }

    /// UTF-16 range of a whole line, including its newline. Empty if out of range.
    func lineRange(_ line: Int) -> NSRange {
        guard line >= 1, line <= lines.count else { return NSRange(location: units.count, length: 0) }
        let entry = lines[line - 1]
        return NSRange(location: entry.utf16Start, length: entry.utf16Length)
    }

    /// The line's range with its trailing newline removed, which is what a token
    /// covering "a whole line" should span — a paragraph attribute that includes
    /// the newline bleeds into the following paragraph.
    func lineContentRange(_ line: Int) -> NSRange {
        var range = lineRange(line)
        while range.length > 0, Self.isNewline(units[NSMaxRange(range) - 1]) {
            range.length -= 1
        }
        return range
    }

    /// Whether a UTF-16 unit is a line break.
    static func isNewline(_ unit: UInt16) -> Bool {
        unit == 0x0A || unit == 0x0D || unit == 0x2028 || unit == 0x2029 || unit == 0x85
    }

    /// The UTF-16 range of the line containing `offset`, including its newline.
    func lineRange(containing offset: Int) -> NSRange {
        let clamped = max(0, min(offset, units.count))
        // Binary search: the walk visits nodes in document order, but not
        // strictly, so a linear scan from the last position is not safe.
        var low = 0
        var high = lines.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if lines[mid].utf16Start <= clamped { low = mid } else { high = mid - 1 }
        }
        return NSRange(location: lines[low].utf16Start, length: lines[low].utf16Length)
    }

    /// Number of lines, counting the empty one after a trailing newline.
    var lineCount: Int { lines.count }
}
