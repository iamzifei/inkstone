import Testing
import Foundation
@testable import InkstoneCore

/// Tab and Shift-Tab.
///
/// `indentWithTabs` and `tabSize` had controls in Settings and no reader at all
/// until this existed, so every test here is also the first evidence that either
/// switch does anything.
@Suite("Indentation")
struct IndentationTests {
    private func edit(
        _ text: String, _ selection: NSRange, outdent: Bool = false,
        useTabs: Bool = false, tabSize: Int = 4
    ) -> String? {
        guard let result = Indentation.edit(in: text, selection: selection, outdent: outdent,
                                            useTabs: useTabs, tabSize: tabSize)
        else { return nil }
        let updated = NSMutableString(string: text)
        updated.replaceCharacters(in: result.range, with: result.replacement)
        return updated as String
    }

    // MARK: - The settings themselves

    @Test("tabSize decides how many spaces a Tab inserts")
    func honoursTabSize() {
        let caret = NSRange(location: 0, length: 0)
        #expect(edit("x", caret, tabSize: 2) == "  x")
        #expect(edit("x", caret, tabSize: 4) == "    x")
        #expect(edit("x", caret, tabSize: 8) == "        x")
    }

    @Test("indentWithTabs decides whether it is a tab at all")
    func honoursIndentWithTabs() {
        let caret = NSRange(location: 0, length: 0)
        #expect(edit("x", caret, useTabs: true) == "\tx")
        #expect(edit("x", caret, useTabs: false) == "    x")
    }

    @Test("A tabSize of zero still indents by something")
    func clampsDegenerateTabSize() {
        // The stepper is 2...8, but a settings file is a file and can say
        // anything. One space is wrong; no indentation at all is a Tab key that
        // does nothing, which is worse.
        #expect(edit("x", NSRange(location: 0, length: 0), tabSize: 0) == " x")
    }

    // MARK: - Blocks

    @Test("A selection spanning lines indents every line of it")
    func indentsWholeBlocks() {
        let text = "one\ntwo\nthree"
        #expect(edit(text, NSRange(location: 0, length: text.utf16.count), tabSize: 2)
                == "  one\n  two\n  three")
    }

    @Test("A blank line inside a block stays blank")
    func leavesBlankLinesAlone() {
        // Indenting it would leave trailing whitespace that every linter and
        // every diff then complains about.
        #expect(edit("one\n\ntwo", NSRange(location: 0, length: 8), tabSize: 2)
                == "  one\n\n  two")
    }

    @Test("Half a line selected still indents the whole line")
    func roundsUpToWholeLines() {
        // Indenting half a line is not a thing anyone means by pressing Tab.
        #expect(edit("hello world", NSRange(location: 2, length: 3), tabSize: 2) == "  hello world")
    }

    // MARK: - Outdent

    @Test("Shift-Tab removes one level, however it was written")
    func outdentsEitherStyle() {
        // A vault edited in two editors has both in it, and a Shift-Tab that
        // only understands one of them is one that sometimes does nothing.
        #expect(Indentation.outdent("\tx", tabSize: 4) == "x")
        #expect(Indentation.outdent("    x", tabSize: 4) == "x")
        #expect(Indentation.outdent("  x", tabSize: 4) == "x")
        #expect(Indentation.outdent("      x", tabSize: 4) == "  x")
    }

    @Test("Outdenting a flush-left block changes nothing, and says so")
    func reportsNoChange() {
        // nil rather than an identical replacement, so an empty edit never lands
        // on the undo stack.
        #expect(edit("one\ntwo", NSRange(location: 0, length: 7), outdent: true) == nil)
        #expect(Indentation.outdent("x", tabSize: 4) == "x")
    }

    @Test("Indent then outdent gets the text back")
    func roundTrips() {
        let text = "one\n  two\n\tthree\n\nfour"
        let all = NSRange(location: 0, length: text.utf16.count)
        for (useTabs, size) in [(false, 2), (false, 4), (true, 4)] {
            guard let indented = edit(text, all, useTabs: useTabs, tabSize: size) else {
                Issue.record("indent produced no edit")
                continue
            }
            let back = edit(indented, NSRange(location: 0, length: indented.utf16.count),
                            outdent: true, useTabs: useTabs, tabSize: size)
            #expect(back == text, "useTabs: \(useTabs), tabSize: \(size)")
        }
    }

    // MARK: - CJK

    @Test("Offsets survive a document full of Chinese")
    func handlesCJK() {
        // `NSRange` is UTF-16 and a vault of Chinese notes is exactly where
        // assuming otherwise goes wrong.
        let text = "第一行\n第二行"
        let updated = edit(text, NSRange(location: 0, length: (text as NSString).length), tabSize: 2)
        #expect(updated == "  第一行\n  第二行")
    }
}
