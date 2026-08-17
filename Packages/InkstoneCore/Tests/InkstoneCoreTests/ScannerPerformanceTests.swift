import Testing
import Foundation
@testable import InkstoneCore

/// The scanner re-runs on every keystroke, so its cost on a realistically sized
/// note is a direct measure of typing latency.
///
/// **Nothing here is build-independent, so nothing here asserts one number.**
///
/// The previous version asserted "under 16ms, one frame" — measured in a debug
/// build. That is not shipped latency, it is the optimiser: measured on the same
/// machine on the same day,
///
///     55KB note      debug    release
///     parser engine  45.4 ms   16.1 ms
///     legacy engine   7.4 ms    6.5 ms
///
/// The two engines are not affected equally, because the legacy scanner is almost
/// entirely `NSRegularExpression` — a compiled system framework that our build
/// settings cannot touch — while the parser engine is cmark and Swift, both built
/// from source and both unoptimised in debug. So the *ratio* moves with the build
/// too (6.1× debug, 2.5× release), and an earlier draft of this file claimed
/// otherwise without checking.
///
/// What survives that: the ceilings are per-configuration, and the assertion that
/// actually protects typing latency is `staysLinear`, which is about the shape of
/// the curve rather than its height. Absolute numbers are printed on every run;
/// the release figures are recorded in
/// `docs/plans/2026-08-17-parser-migration.md`.
@Suite("Scanner performance")
struct ScannerPerformanceTests {

    /// A document with the mix of constructs a real note has, not one repeated
    /// paragraph — the two engines behave differently per construct.
    ///
    /// Note this is far denser in *blocks* than a real note of the same size: a
    /// heading, a table, a fenced block, three list items and a quote every 270
    /// bytes. That is the hardest case for a parser and the fairest one for a
    /// regression test, but it is not what typing in a 55KB essay costs.
    static func document(sections: Int) -> String {
        var parts = ["---\ntags: [bench, 性能]\n---\n"]
        for i in 0..<sections {
            parts.append("""
            ## Section \(i)

            A paragraph with **bold**, *italic*, `inline code`, a
            [[Wiki Link \(i)]] and a #tag/\(i % 20). 中英文混排 also appears here.

            - A bullet item
            - [ ] a task item
            - [x] a finished one

            > A quote line.

            | Col A | Col B |
            | --- | --- |
            | \(i) | value |

            ```swift
            let x = \(i)
            ```
            """)
        }
        return parts.joined(separator: "\n\n")
    }

    static func median(of samples: [Double]) -> Double {
        samples.sorted()[samples.count / 2]
    }

    static func timeScan(_ text: String, engine: SyntaxScanner.Engine = .parser, runs: Int = 5) -> Double {
        let scanner = SyntaxScanner(engine: engine)
        _ = scanner.scan(text)  // warm up
        var samples: [Double] = []
        for _ in 0..<runs {
            let start = DispatchTime.now().uptimeNanoseconds
            _ = scanner.scan(text)
            samples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
        }
        return median(of: samples)
    }

    /// Parsing is inherently dearer than pattern matching — it builds a tree
    /// where the regexes built nothing — and in release roughly 40% of what it
    /// costs is cmark itself, which is C we do not control. These are the measured
    /// ratios with headroom; well past them means something in the walk regressed.
    #if DEBUG
    private static let budget = 8.0
    private static let floorMs = 8.0
    #else
    private static let budget = 3.5
    private static let floorMs = 3.0
    #endif

    private func compare(sections: Int, label: String) {
        let text = Self.document(sections: sections)
        let parser = Self.timeScan(text, engine: .parser)
        let legacy = Self.timeScan(text, engine: .legacy)
        let sizeKB = text.utf8.count / 1024
        print("""
              scan \(label) (\(sizeKB) KB): \
              parser \(String(format: "%.1f", parser)) ms | \
              legacy \(String(format: "%.1f", legacy)) ms | \
              \(String(format: "%.1f", parser / legacy))×
              """)
        // Either within the ratio, or below the point where it could matter. On a
        // 2KB note the parser costs 1.7ms against the scanner's 0.4ms — a 4.6×
        // that is entirely cmark's fixed setup cost, and 1.7ms is not a latency
        // anyone can perceive. Failing on that ratio would be measuring a number
        // that has no consequence.
        #expect(
            parser < legacy * Self.budget || parser < Self.floorMs,
            "the parser engine went from \(legacy) ms to \(parser) ms — more than \(Self.budget)× the scanner it replaced"
        )
    }

    @Test("A short note stays cheap")
    func shortNote() { compare(sections: 10, label: " 10 sections") }

    @Test("A long note stays within budget")
    func longNote() {
        // ~55KB is a long working note.
        compare(sections: 200, label: "200 sections")
    }

    @Test("A very large note stays within budget")
    func veryLargeNote() { compare(sections: 800, label: "800 sections") }

    @Test("Cost is linear in document size, not quadratic")
    func staysLinear() {
        // The invariant that actually protects typing latency. The old scanner
        // had a genuine quadratic in it — a linear scan of an ever-growing masked
        // region, 39ms on a 55KB note and 517ms on a 223KB one — and it was found
        // by noticing the shape of these numbers, not by any single threshold.
        let small = Self.timeScan(Self.document(sections: 100))
        let large = Self.timeScan(Self.document(sections: 400))
        let ratio = large / small
        print("4× the text costs \(String(format: "%.1f", ratio))× the time")
        #expect(ratio < 6, "4× the document should cost about 4× the time, not \(ratio)×")
    }
}
