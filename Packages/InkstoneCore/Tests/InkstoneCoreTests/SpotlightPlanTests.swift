import Testing
import Foundation
@testable import InkstoneCore

/// What to write to and remove from the system search index after the vault
/// index changes: only what changed since the last push.
@Suite("Spotlight plan")
struct SpotlightPlanTests {
    let a = URL(filePath: "/v/a.md"), b = URL(filePath: "/v/b.md"), c = URL(filePath: "/v/c.md")
    let t0 = Date(timeIntervalSince1970: 1_000), t1 = Date(timeIntervalSince1970: 2_000)

    @Test func firstPushIndexesEverything() {
        let plan = SpotlightPlan.diff(pushed: [:], current: [a: t0, b: t0])
        #expect(Set(plan.upsert) == [a, b])
        #expect(plan.delete.isEmpty)
    }

    @Test func onlyChangedAndNewNotesAreRewritten() {
        let plan = SpotlightPlan.diff(pushed: [a: t0, b: t0], current: [a: t0, b: t1, c: t0])
        #expect(Set(plan.upsert) == [b, c])
        #expect(plan.delete.isEmpty)
    }

    @Test func deletedAndRenamedNotesAreRemoved() {
        // b renamed to c: b goes, c comes.
        let plan = SpotlightPlan.diff(pushed: [a: t0, b: t0], current: [a: t0, c: t0])
        #expect(plan.upsert == [c])
        #expect(plan.delete == [b])
    }

    @Test func nothingChangedIsNothingToDo() {
        let plan = SpotlightPlan.diff(pushed: [a: t0], current: [a: t0])
        #expect(plan.isEmpty)
    }

    @Test func summaryDropsFrontmatterAndMarkup() {
        let text = "---\ntags: [x]\n---\n# Title\n\nSome **bold** text and a [[Link|label]].\n"
        let s = SpotlightPlan.summary(of: text, limit: 200)
        #expect(!s.contains("tags:"))
        #expect(!s.contains("**"))
        #expect(!s.contains("[["))
        #expect(s.contains("Some bold text and a label."))
    }

    @Test func summaryIsCapped() {
        let s = SpotlightPlan.summary(of: String(repeating: "word ", count: 500), limit: 100)
        #expect(s.count <= 101)
    }
}
