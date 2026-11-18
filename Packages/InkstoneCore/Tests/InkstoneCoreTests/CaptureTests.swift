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

    // Review 2026-11-18.
    @Test func noteNamesFitTheFileSystem() {
        let cjk = Capture.noteName(from: String(repeating: "中", count: 150))
        #expect(cjk.utf8.count <= 200)
        #expect(cjk.count == 66)
        #expect(Capture.noteName(from: ".hidden") == "hidden")
        #expect(Capture.noteName(from: "..") == "Untitled")
        #expect(Capture.noteName(from: "a\tb\nc") == "a-b-c")
    }

    @Test func inboxEntryRoundTrips() throws {
        let item = Capture.SharedItem(text: "t", url: URL(string: "https://x.org"), title: "x")
        let data = try JSONEncoder().encode(item)
        #expect(try JSONDecoder().decode(Capture.SharedItem.self, from: data) == item)
    }
}


@Suite("Shared inbox")
struct SharedInboxTests {
    func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "inbox-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func itemsAreDeliveredOldestFirstAndRemoved() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try SharedInbox.add(.init(text: "second", url: nil, title: nil, date: Date(timeIntervalSince1970: 200)), in: dir)
        try SharedInbox.add(.init(text: "first", url: nil, title: nil, date: Date(timeIntervalSince1970: 100)), in: dir)
        var got: [String] = []
        SharedInbox.drain(in: dir) { got.append($0.text ?? ""); return true }
        #expect(got == ["first", "second"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
    }

    @Test func anItemTheVaultCannotTakeStaysForNextTime() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try SharedInbox.add(.init(text: "keep me", url: nil, title: nil, date: .now), in: dir)
        SharedInbox.drain(in: dir) { _ in false }
        var got: [String] = []
        SharedInbox.drain(in: dir) { got.append($0.text ?? ""); return true }
        #expect(got == ["keep me"])
    }

    @Test func entryHasATimestampHeading() {
        let item = Capture.SharedItem(text: "hi", url: nil, title: nil, date: Date(timeIntervalSince1970: 0))
        #expect(SharedInbox.entry(for: item, timeZone: TimeZone(identifier: "UTC")!) == "\n### 1970-01-01 00:00\n\nhi\n")
    }
}
