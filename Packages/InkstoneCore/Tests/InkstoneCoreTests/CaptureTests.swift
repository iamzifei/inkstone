import Testing
import Foundation
@testable import InkstoneCore

/// Text arriving from outside the app — Shortcuts, the share sheet — and how
/// it lands in a note.
@Suite("Capture")
struct CaptureTests {
    @Test func appendingAddsOnItsOwnLine() {
        #expect(Capture.appending("- [ ] milk", to: "# Today\n") == "# Today\n- [ ] milk\n")
        #expect(Capture.appending("hello", to: "# Today") == "# Today\nhello\n")
        #expect(Capture.appending("hello", to: "") == "hello\n")
    }

    @Test func sharedItemsBecomeMarkdown() {
        let page = Capture.SharedItem(text: "Great read", url: URL(string: "https://example.com/a?b=1"), title: "An article")
        #expect(page.markdown == "Great read\n[An article](https://example.com/a?b=1)")
        let bare = Capture.SharedItem(text: nil, url: URL(string: "https://example.com"), title: nil)
        #expect(bare.markdown == "<https://example.com>")
        let textOnly = Capture.SharedItem(text: "just text", url: nil, title: nil)
        #expect(textOnly.markdown == "just text")
    }

    @Test func titlesInLinksAreEscaped() {
        let page = Capture.SharedItem(text: nil, url: URL(string: "https://x.org"), title: "a [b] c")
        #expect(page.markdown == "[a \\[b\\] c](https://x.org)")
    }

    @Test func noteNamesAreSafeFileNames() {
        #expect(Capture.noteName(from: "  Shopping / list: today?  ") == "Shopping - list- today-")
        #expect(Capture.noteName(from: "") == "Untitled")
        #expect(Capture.noteName(from: String(repeating: "a", count: 300)).count == 120)
    }

    @Test func inboxEntryRoundTrips() throws {
        let item = Capture.SharedItem(text: "t", url: URL(string: "https://x.org"), title: "x")
        let data = try JSONEncoder().encode(item)
        #expect(try JSONDecoder().decode(Capture.SharedItem.self, from: data) == item)
    }
}

