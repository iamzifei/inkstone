import Testing
import Foundation
@testable import InkstoneCore

/// The cache is four lines, and the failure it can cause is not small: returning
/// tokens for the previous document would style the editor against text that is
/// no longer there — every range off, attributes landing mid-word, and in the
/// worst case a range past the end of the storage.
@Suite("Caching scanner")
struct CachingScannerTests {

    @Test("Scanning the same text twice scans once")
    func hit() {
        var scanner = CachingScanner()
        let text = "# Title\n\nSome **bold** text.\n"
        let first = scanner.tokens(for: text)
        let second = scanner.tokens(for: text)
        #expect(scanner.scanCount == 1)
        #expect(first == second)
    }

    @Test("Changed text is rescanned, and the result is not stale")
    func miss() {
        var scanner = CachingScanner()
        _ = scanner.tokens(for: "# One\n")
        let tokens = scanner.tokens(for: "# One\n\n## Two\n")
        #expect(scanner.scanCount == 2)
        #expect(tokens.contains { $0.kind == .heading(level: 2) })
    }

    @Test("A one-character edit is not mistaken for the same document")
    func singleCharacterEdit() {
        // The cheap-comparison trap: two documents of the same length differing
        // by one byte must not collide.
        var scanner = CachingScanner()
        let before = "Some *italic* text.\n"
        let after  = "Some _italic_ text.\n"
        #expect(before.count == after.count)
        _ = scanner.tokens(for: before)
        _ = scanner.tokens(for: after)
        #expect(scanner.scanCount == 2)
    }

    @Test("Alternating between two documents never returns the wrong one")
    func alternating() {
        // Switching tabs back and forth. A cache that returned the wrong entry
        // here would render one note with another note's structure.
        var scanner = CachingScanner()
        let a = "# Alpha\n\n- item\n"
        let b = "| A | B |\n| --- | --- |\n| 1 | 2 |\n"
        for _ in 0..<3 {
            #expect(scanner.tokens(for: a).contains { $0.kind == .heading(level: 1) })
            #expect(!scanner.tokens(for: a).contains { $0.kind == .table })
            #expect(scanner.tokens(for: b).contains { $0.kind == .table })
            #expect(!scanner.tokens(for: b).contains { if case .heading = $0.kind { return true }; return false })
        }
    }

    @Test("Cached tokens match an uncached scan exactly")
    func agreesWithTheScanner() {
        // The cache must be invisible. Anything else and a bug would appear only
        // on the second highlight of a document, which is the hardest kind to
        // reproduce.
        let text = """
        ---
        tags: [a]
        ---

        # 标题

        - [ ] task with **bold** and `code`

        | A | B |
        | --- | --- |
        | 1 | 2 |
        """
        var caching = CachingScanner()
        let direct = SyntaxScanner().scan(text)
        for _ in 0..<3 {
            #expect(caching.tokens(for: text) == direct)
        }
        #expect(caching.scanCount == 1)
    }

    @Test("An empty document is cached like any other")
    func emptyText() {
        var scanner = CachingScanner()
        #expect(scanner.tokens(for: "").isEmpty)
        #expect(scanner.tokens(for: "").isEmpty)
        #expect(scanner.scanCount == 1, "an empty document must not rescan forever")
    }
}
