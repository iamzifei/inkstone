import Testing
import Foundation
@testable import InkstoneCore

/// 0.4.0 plan B3: after an edit the editor's scanner re-scans only the blocks
/// around the change and splices the tokens. Whatever it does, the result must
/// be exactly what a full scan gives — checked over random edits on real notes
/// (the repo's demo vaults and docs; set INKSTONE_CORPUS to a folder of notes
/// to run the same check over a real vault locally).
@Suite("Incremental scan")
struct IncrementalScanTests {
    static let repo = URL(filePath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    static func notes() -> [(String, String)] {
        var roots = [repo.appending(path: "assets"), repo.appending(path: "docs")]
        if let extra = ProcessInfo.processInfo.environment["INKSTONE_CORPUS"] { roots.append(URL(filePath: extra)) }
        var found: [(String, String)] = []
        for root in roots {
            guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in walker where url.pathExtension == "md" {
                if let text = try? String(contentsOf: url, encoding: .utf8) { found.append((url.lastPathComponent, text)) }
            }
        }
        return found.sorted { $0.0 < $1.0 }
    }

    /// Deterministic random numbers, so a failure reproduces.
    struct Seeded: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
    }

    static let snippets = ["a", "x", " ", "\n", "\n\n", "#", "## ", "**", "*", "==", "~~", "[[", "]]", "[[Note]]",
                           "`", "```\n", "$", "$$", "%%", "---\n", "- ", "  - ", "> ", "> [!note] ", "|", "| a | b |\n",
                           "[^1]", "<b>", "\t", "1. ", "![[x.png]]", "#tag ", "[a](b)", "https://x.org ", "^block",
                           "中文", "：", "\\", "&amp;", "- [ ] "]

    static func edit(_ text: String, _ rng: inout Seeded) -> String {
        var chars = Array(text)
        let at = chars.isEmpty ? 0 : Int.random(in: 0...chars.count, using: &rng)
        switch Int.random(in: 0..<3, using: &rng) {
        case 0: // insert
            chars.insert(contentsOf: snippets.randomElement(using: &rng)!, at: at)
        case 1: // delete
            let n = min(Int.random(in: 1...12, using: &rng), chars.count - at)
            if n > 0 { chars.removeSubrange(at..<(at + n)) }
        default: // type a character, as the editor sees most
            chars.insert(Character(String(UnicodeScalar(UInt8.random(in: 32...126, using: &rng)))), at: at)
        }
        return String(chars)
    }

    @Test func incrementalEqualsFullScanOverRandomEdits() {
        let notes = Self.notes()
        #expect(notes.count > 20)
        var checked = 0, incremental = 0, longChecked = 0
        for (name, original) in notes {
            let long = (original as NSString).length > 4_000
            // Seeded by the note's name, so a failing note reproduces on its own.
            var rng = Seeded(state: name.utf8.reduce(UInt64(1469598103934665603)) { ($0 ^ UInt64($1)) &* 1099511628211 })
            var text = original
            var scanner = CachingScanner()
            _ = scanner.tokens(for: text)
            for step in 0..<40 {
                text = Self.edit(text, &rng)
                let got = scanner.tokens(for: text)
                let want = SyntaxScanner().scan(text)
                checked += 1
                if long { longChecked += 1 }
                if got != want {
                    // Show the first difference and the text around it.
                    let i = Array(zip(got, want)).firstIndex { $0.0 != $0.1 } ?? min(got.count, want.count)
                    let g = i < got.count ? "\(got[i].kind)@\(got[i].range)" : "—"
                    let w = i < want.count ? "\(want[i].kind)@\(want[i].range)" : "—"
                    let at = i < want.count ? want[i].range.location : (i < got.count ? got[i].range.location : 0)
                    let ns = text as NSString
                    let from = max(0, at - 120), to = min(ns.length, at + 120)
                    Issue.record("""
                        \(name) step \(step): incremental scan differs from a full scan
                        incremental: \(g)   full: \(w)
                        context: \(ns.substring(with: NSRange(location: from, length: to - from)).debugDescription)
                        """)
                    break
                }
            }
            if long { incremental += scanner.incrementalScans }
        }
        // The point: on long notes, where it matters, most edits did not need
        // a full scan. (Short notes always get one: it is already cheap.)
        print("incremental scan: \(incremental) of \(longChecked) edits on long notes re-scanned only part (\(checked) edits checked)")
        #expect(incremental > longChecked / 2)
    }

    @Test func aFenceTypedCharacterByCharacterStillMatches() {
        var text = "Intro paragraph.\n\nSome #tag text.\n\nMore [[link]] text.\n"
        var scanner = CachingScanner()
        _ = scanner.tokens(for: text)
        for ch in "```\n" {
            text.insert(ch, at: text.index(text.startIndex, offsetBy: 18))
            #expect(scanner.tokens(for: text) == SyntaxScanner().scan(text))
        }
    }
}

/// What the incremental scan buys: per-keystroke scan time while typing into
/// the middle of a long note, full scan vs incremental.
@Suite("Incremental scan performance")
struct IncrementalScanPerformanceTests {
    @Test func typingInALongNoteIsCheaper() {
        // ~88 KB of mixed prose, headings, lists, links and tags.
        var text = ""
        for i in 0..<220 {
            text += "## Section \(i)\n\nSome **bold** prose with a [[Link \(i)]] and a #tag/\(i % 7), "
            text += "plus ==highlight== and `code`. 中文与 English 混排的一段文字。\n\n"
            text += "- item one\n- item two with [a link](https://example.com/\(i))\n\n"
        }
        let typed = Array("The quick brown fox jumps over the lazy dog. ")
        var scanner = CachingScanner()
        _ = scanner.tokens(for: text)
        let insertAt = text.index(text.startIndex, offsetBy: text.count / 2)
        var current = text
        var position = current.distance(from: current.startIndex, to: insertAt)
        var incremental: [Double] = [], full: [Double] = []
        for ch in typed {
            current.insert(ch, at: current.index(current.startIndex, offsetBy: position))
            position += 1
            var start = DispatchTime.now().uptimeNanoseconds
            _ = scanner.tokens(for: current)
            incremental.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
            start = DispatchTime.now().uptimeNanoseconds
            _ = SyntaxScanner().scan(current)
            full.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
        }
        let median = { (a: [Double]) in a.sorted()[a.count / 2] }
        print(String(format: "typing in %d KB: full scan %.2f ms, incremental %.2f ms per keystroke (median)",
                     text.utf8.count / 1024, median(full), median(incremental)))
        #expect(scanner.incrementalScans >= typed.count - 2)
        // Generous margin: CI machines are noisy; locally it is far larger.
        #expect(median(incremental) * 3 < median(full))
    }
}
