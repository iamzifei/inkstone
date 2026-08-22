import Testing
import Foundation
@testable import InkstoneCore

@Suite("Task markers")
struct TaskMarkerTests {

    /// The marker range for the first task in `text`, the way the editor's
    /// scanner reports it.
    private func marker(in text: String) throws -> NSRange {
        let tokens = SyntaxScanner().scan(text)
        let token = try #require(tokens.first {
            if case .task = $0.kind { return true }
            return false
        })
        return token.range
    }

    @Test("An unticked task becomes ticked")
    func tick() throws {
        let text = "- [ ] a task\n"
        #expect(TaskMarker.toggled(in: text, markerRange: try marker(in: text)) == "- [x] a task\n")
    }

    @Test("A ticked task becomes unticked")
    func untick() throws {
        let text = "- [x] a task\n"
        #expect(TaskMarker.toggled(in: text, markerRange: try marker(in: text)) == "- [ ] a task\n")
    }

    @Test("Any non-blank state counts as done")
    func nonBlankIsDone() throws {
        // `[X]` and `[✓]` are ticked in every renderer that supports task lists,
        // so toggling them has to clear rather than set.
        for text in ["- [X] a task\n", "- [✓] a task\n"] {
            let result = TaskMarker.toggled(in: text, markerRange: try marker(in: text))
            #expect(result?.contains("[ ]") == true, "\(text) should have been cleared")
        }
    }

    @Test("Indentation and bullet style are preserved")
    func preservesShape() throws {
        for (text, expected) in [
            ("  - [ ] nested\n", "  - [x] nested\n"),
            ("* [ ] star\n", "* [x] star\n"),
            ("+ [ ] plus\n", "+ [x] plus\n"),
            // Tab-indented, under a parent so it is a list rather than an
            // indented code block. Only the child line is compared.
            ("- parent\n\t- [ ] tabbed\n", "- parent\n\t- [x] tabbed\n"),
        ] {
            #expect(TaskMarker.toggled(in: text, markerRange: try marker(in: text)) == expected)
        }
    }

    @Test("Only the marker's own checkbox changes")
    func touchesOneTask() throws {
        // The surrounding document must come back byte for byte: a toggle that
        // rewrote anything else would corrupt the note on every tap.
        let text = """
        # Notes

        - [ ] first
        - [ ] second
        - [x] third

        Text with [brackets] and a [link](url).
        """
        let tokens = SyntaxScanner().scan(text)
        let tasks = tokens.filter { if case .task = $0.kind { return true }; return false }
        #expect(tasks.count == 3)

        let result = try #require(TaskMarker.toggled(in: text, markerRange: tasks[1].range))
        #expect(result.contains("- [ ] first"))
        #expect(result.contains("- [x] second"))
        #expect(result.contains("- [x] third"))
        #expect(result.contains("Text with [brackets] and a [link](url)."))
        #expect(result.count == text.count)
    }

    @Test("A range with no checkbox is rejected")
    func rejectsNonTasks() {
        let text = "- a plain bullet\n"
        #expect(TaskMarker.toggled(in: text, markerRange: NSRange(location: 0, length: 2)) == nil)
    }

    @Test("An out-of-bounds range is rejected rather than trapping")
    func rejectsBadRanges() {
        let text = "- [ ] a task\n"
        #expect(TaskMarker.toggled(in: text, markerRange: NSRange(location: 100, length: 6)) == nil)
        #expect(TaskMarker.toggled(in: text, markerRange: NSRange(location: 0, length: 999)) == nil)
        #expect(TaskMarker.toggled(in: text, markerRange: NSRange(location: 0, length: 0)) == nil)
    }

    @Test("Toggling twice returns the original")
    func roundTrips() throws {
        let text = "  - [ ] 中文任务\n"
        let range = try marker(in: text)
        let once = try #require(TaskMarker.toggled(in: text, markerRange: range))
        let twice = try #require(TaskMarker.toggled(in: once, markerRange: range))
        #expect(twice == text)
    }
}
