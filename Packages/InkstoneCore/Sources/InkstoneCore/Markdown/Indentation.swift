import Foundation

/// What the Tab key does, as a pure function of the text and the settings.
///
/// `indentWithTabs` and `tabSize` both had a control in Settings and no reader
/// anywhere — AppKit sends Tab as a *command*, never as a text replacement, so
/// the editor's `shouldChangeTextIn` hook never saw it and the two settings sat
/// there reading as features.
///
/// In the core rather than in the text view because the interesting parts — what
/// happens to a blank line inside an indented block, what outdent does to a file
/// that has both tabs and spaces in it — are decisions, and decisions want tests.
public enum Indentation {
    /// One level of indentation for the reader's settings.
    public static func unit(useTabs: Bool, tabSize: Int) -> String {
        useTabs ? "\t" : String(repeating: " ", count: max(1, tabSize))
    }

    /// The replacement Tab (or Shift-Tab) should make, or nil for "do nothing".
    ///
    /// - Returns: the range to replace and what to put there. Nil means the key
    ///   press changes nothing — outdenting a block that is already flush left —
    ///   and the caller should leave the document alone rather than push an
    ///   empty edit onto the undo stack.
    public static func edit(
        in text: String,
        selection: NSRange,
        outdent: Bool,
        useTabs: Bool,
        tabSize: Int
    ) -> (range: NSRange, replacement: String)? {
        let string = text as NSString
        let unit = unit(useTabs: useTabs, tabSize: tabSize)

        // A caret, indenting: just insert. Everything else works on whole lines,
        // because indenting half a line is not a thing anyone means.
        if selection.length == 0, !outdent {
            return (selection, unit)
        }

        let lines = string.paragraphRange(for: selection)
        guard lines.length > 0 else { return outdent ? nil : (selection, unit) }

        let block = string.substring(with: lines)
        let shifted = block.components(separatedBy: "\n").map { line -> String in
            if outdent { return self.outdent(line, tabSize: tabSize) }
            // A blank line in the middle of a block stays blank: indenting it
            // would leave a line of trailing whitespace that every linter and
            // every diff would then complain about.
            return line.isEmpty ? line : unit + line
        }.joined(separator: "\n")

        guard shifted != block else { return nil }
        return (lines, shifted)
    }

    /// Removes one level of indentation, whichever way it was written.
    ///
    /// Takes whatever is actually at the start of the line rather than assuming
    /// the current setting: a vault edited in two editors has both tabs and
    /// spaces in it, and Shift-Tab that only understands one of them is a
    /// Shift-Tab that sometimes does nothing.
    public static func outdent(_ line: String, tabSize: Int) -> String {
        if line.hasPrefix("\t") { return String(line.dropFirst()) }
        let spaces = line.prefix { $0 == " " }.count
        guard spaces > 0 else { return line }
        return String(line.dropFirst(min(spaces, max(1, tabSize))))
    }
}
