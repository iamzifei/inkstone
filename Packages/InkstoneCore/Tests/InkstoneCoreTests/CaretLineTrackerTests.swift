import Testing
import Foundation
@testable import InkstoneCore

/// The guard that stops the editor re-highlighting on every selection change.
///
/// Worth testing precisely because getting it wrong is invisible in the good
/// direction and unusable in the bad one: too eager and it costs a full document
/// scan per arrow key, too lazy and the caret moves onto a line whose syntax
/// never reveals.
@Suite("Caret line tracker")
struct CaretLineTrackerTests {

    private func line(_ location: Int, _ length: Int) -> NSRange {
        NSRange(location: location, length: length)
    }

    @Test("The first pass always runs")
    func firstPassRuns() {
        // Including in source mode, where the caret line is always nil. Skipping
        // it would leave the document with no attributes at all.
        #expect(CaretLineTracker().needsPass(caretLine: nil))
        #expect(CaretLineTracker().needsPass(caretLine: line(0, 10)))
    }

    @Test("Moving within the same line does not need a pass")
    func sameLine() {
        var tracker = CaretLineTracker()
        tracker.record(caretLine: line(0, 20))
        #expect(!tracker.needsPass(caretLine: line(0, 20)))
    }

    @Test("Moving to another line needs a pass")
    func differentLine() {
        // This is the one that must not be optimised away: live preview reveals
        // the source on the caret's line, so a new line means new attributes.
        var tracker = CaretLineTracker()
        tracker.record(caretLine: line(0, 20))
        #expect(tracker.needsPass(caretLine: line(21, 15)))
    }

    @Test("A line that changed length needs a pass")
    func lineGrew() {
        // Typing on a line changes its paragraph range, and the text changed too,
        // so the pass has to run.
        var tracker = CaretLineTracker()
        tracker.record(caretLine: line(0, 20))
        #expect(tracker.needsPass(caretLine: line(0, 21)))
    }

    @Test("Selection changes in source and reading mode stop after the first")
    func nilCaretSettles() {
        // Both modes always report a nil caret line. Before this, every arrow key
        // in source mode re-scanned the whole document to produce byte-identical
        // attributes.
        var tracker = CaretLineTracker()
        tracker.record(caretLine: nil)
        #expect(!tracker.needsPass(caretLine: nil))
    }

    @Test("Switching between a caret and no caret needs a pass")
    func modeChange() {
        var tracker = CaretLineTracker()
        tracker.record(caretLine: line(0, 20))
        #expect(tracker.needsPass(caretLine: nil), "live preview → source must restyle")

        var reverse = CaretLineTracker()
        reverse.record(caretLine: nil)
        #expect(reverse.needsPass(caretLine: line(0, 20)), "source → live preview must restyle")
    }

    @Test("A run of moves within one line costs exactly one pass")
    func realisticSequence() {
        // Ten right-arrows along one line, then one move to the next.
        var tracker = CaretLineTracker()
        var passes = 0
        func selectionChanged(to caret: NSRange?) {
            guard tracker.needsPass(caretLine: caret) else { return }
            passes += 1
            tracker.record(caretLine: caret)
        }

        for _ in 0..<10 { selectionChanged(to: line(0, 20)) }
        #expect(passes == 1)

        selectionChanged(to: line(21, 18))
        #expect(passes == 2)
    }
}
