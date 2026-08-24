import Foundation
import Testing
@testable import InkstoneCore

/// Progress has to be determinate from the first second.
///
/// Not a nicety: iOS forcibly expires a continued-processing task that looks
/// stalled, and this reported nothing until the plan existed. Two real runs were
/// killed that way — at 31 seconds and at 3½ minutes — with the bar never having
/// moved off zero.
@Suite("Sync progress phases")
struct SyncProgressPhaseTests {

    @Test("Every phase before the plan still reports a position")
    func earlyPhasesAreNotZeroForever() {
        let early: [SyncProgress.Phase] = [.verifying, .listing, .scanning, .planning]
        let percents = early.map { SyncProgress(phase: $0, message: "…").percent }

        // Verifying may legitimately be 0 — it is the first instant of the run.
        // What matters is that the run does not sit there through the phases
        // that actually take time.
        #expect(percents == percents.sorted())
        #expect(SyncProgress(phase: .listing, message: "…").percent > 0)
        #expect(SyncProgress(phase: .scanning, message: "…").percent > 0)
        #expect(SyncProgress(phase: .planning, message: "…").percent > 0)
    }

    @Test("Transferring maps the file count onto what is left of the scale")
    func transferringSpansTheRest() {
        func percent(_ done: Int, of total: Int) -> Int {
            SyncProgress(phase: .transferring, message: "…", completed: done, total: total).percent
        }
        let start = SyncProgress.Phase.transferring.start
        #expect(percent(0, of: 100) == start)
        #expect(percent(100, of: 100) == 100)
        #expect(percent(50, of: 100) == start + (100 - start) / 2)
    }

    /// The bar must never go backwards between phases, or it reads as a restart.
    @Test("A run's progress only ever increases")
    func monotonic() {
        var readings: [Int] = [
            SyncProgress(phase: .verifying, message: "…").percent,
            SyncProgress(phase: .listing, message: "…").percent,
            SyncProgress(phase: .scanning, message: "…").percent,
            SyncProgress(phase: .planning, message: "…").percent,
        ]
        for done in stride(from: 0, through: 800, by: 80) {
            readings.append(SyncProgress(phase: .transferring, message: "…",
                                         completed: done, total: 800).percent)
        }
        #expect(readings == readings.sorted())
        #expect(readings.last == 100)
    }

    /// Transferring with no plan yet — an empty vault, or the moment before the
    /// first action — must not divide by zero or jump to the end.
    @Test("Transferring with nothing to transfer reports its own start")
    func transferringWithNoTotal() {
        #expect(SyncProgress(phase: .transferring, message: "…").percent
                    == SyncProgress.Phase.transferring.start)
    }
}
