import Testing
import Foundation
@testable import InkstoneCore

/// The scanner re-runs on every keystroke, so its cost on a realistically sized
/// note is a direct measure of typing latency. A frame is 16ms; anything close
/// to that means the editor stutters as you type.
@Suite("Scanner performance")
struct ScannerPerformanceTests {

    /// A document with the mix of constructs a real note has, not one repeated
    /// paragraph — the masking passes behave differently per construct.
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

    static func timeScan(_ text: String, runs: Int = 5) -> Double {
        let scanner = SyntaxScanner()
        _ = scanner.scan(text)  // warm up
        var samples: [Double] = []
        for _ in 0..<runs {
            let start = DispatchTime.now().uptimeNanoseconds
            _ = scanner.scan(text)
            samples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
        }
        return median(of: samples)
    }

    @Test("Scanning a short note is imperceptible")
    func shortNote() {
        let text = Self.document(sections: 10)
        let ms = Self.timeScan(text)
        print("scan  10 sections (\(text.utf8.count / 1024) KB): \(String(format: "%.1f", ms)) ms")
        #expect(ms < 16, "a short note must scan well inside one frame")
    }

    @Test("Scanning a long note stays under a frame")
    func longNote() {
        // ~100KB is a long working note; Typora handles this without stutter.
        let text = Self.document(sections: 200)
        let ms = Self.timeScan(text)
        print("scan 200 sections (\(text.utf8.count / 1024) KB): \(String(format: "%.1f", ms)) ms")
        #expect(ms < 16, "typing in a long note must not drop frames")
    }

    @Test("Scanning a very large note is still usable")
    func veryLargeNote() {
        let text = Self.document(sections: 800)
        let ms = Self.timeScan(text)
        print("scan 800 sections (\(text.utf8.count / 1024) KB): \(String(format: "%.1f", ms)) ms")
        #expect(ms < 100, "a very large note may lag, but must not freeze")
    }
}
