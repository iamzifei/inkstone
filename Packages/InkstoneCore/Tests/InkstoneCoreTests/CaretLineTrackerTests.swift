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

    @Test("A line that only changed length does not need a pass of its own")
    func lineGrew() {
        // Typing lengthens the caret's paragraph. The pass still has to happen —
        // and it does, from the text-change notification, which is unconditional.
        // Running it from the selection notification as well was the second of
        // the two passes every keystroke used to cost.
        var tracker = CaretLineTracker()
        tracker.record(caretLine: line(0, 20))
        #expect(!tracker.needsPass(caretLine: line(0, 21)))
    }

    @Test("A line that starts elsewhere needs a pass")
    func lineMoved() {
        // The case the length comparison was standing in for, and the one that
        // must never be skipped: the caret is on a different line, so a different
        // line reveals its source.
        var tracker = CaretLineTracker()
        tracker.record(caretLine: line(0, 20))
        #expect(tracker.needsPass(caretLine: line(21, 20)))
        // Including when the new line happens to be the same length.
        #expect(tracker.needsPass(caretLine: line(1, 20)))
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

    @Test("Typing costs one pass per keystroke, whichever notification comes first")
    func typingCostsOnePass() {
        // Models what the editor actually does. Both AppKit and UIKit post a
        // selection change *and* a text change for one keystroke, and the order
        // is not guaranteed — so the count is asserted both ways round. The text
        // pass is unconditional, which is what makes skipping the selection's
        // safe rather than a race.
        func passes(textFirst: Bool) -> Int {
            var tracker = CaretLineTracker()
            var count = 0
            func pass(_ caret: NSRange?) { count += 1; tracker.record(caretLine: caret) }
            func selectionChanged(_ caret: NSRange?) {
                if tracker.needsPass(caretLine: caret) { pass(caret) }
            }

            pass(line(40, 12))                       // the document opens
            for keystroke in 0..<10 {
                // Typing mid-line: the paragraph grows, its start does not move.
                let caret = line(40, 12 + keystroke + 1)
                if textFirst {
                    pass(caret)
                    selectionChanged(caret)
                } else {
                    selectionChanged(caret)
                    pass(caret)
                }
            }
            return count - 1                          // discount the opening pass
        }

        #expect(passes(textFirst: true) == 10)
        #expect(passes(textFirst: false) == 10)
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
