import Foundation
import Testing
@testable import InkstoneCore

@Suite("Bookmarks")
struct BookmarksTests {

    @Test("Toggling adds, then removes, and keeps the order in between")
    func toggling() {
        var marks = Bookmarks()
        marks.toggle("Notes/A.md")
        marks.toggle("B.md")
        marks.toggle("Notes/C.md")
        #expect(marks.paths == ["Notes/A.md", "B.md", "Notes/C.md"])

        marks.toggle("B.md")
        #expect(marks.paths == ["Notes/A.md", "Notes/C.md"])
        #expect(!marks.contains("B.md"))

        // Re-adding appends rather than restoring the old position: the order is
        // the order they were pinned in, and this was pinned again just now.
        marks.toggle("B.md")
        #expect(marks.paths == ["Notes/A.md", "Notes/C.md", "B.md"])
    }

    /// A bookmark that stops pointing anywhere the moment a file is renamed
    /// would be worse than none — the user pinned the note, not the filename.
    @Test("A renamed or moved file keeps its place in the list")
    func followsRenames() {
        var marks = Bookmarks(paths: ["A.md", "B.md", "C.md"])
        marks.rename("B.md", to: "Archive/B.md")
        #expect(marks.paths == ["A.md", "Archive/B.md", "C.md"])

        // A path that was never bookmarked changes nothing.
        marks.rename("Z.md", to: "Y.md")
        #expect(marks.paths == ["A.md", "Archive/B.md", "C.md"])
    }

    /// Stored in the vault so the list travels with it. An absolute path would
    /// be right on exactly one machine.
    @Test("Round-trips through the vault, and an absent file reads as empty")
    func storage() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "inkstone-marks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(Bookmarks.load(from: root).isEmpty)

        var marks = Bookmarks()
        marks.toggle("Daily/2026-08-23.md")
        try marks.save(to: root)

        #expect(Bookmarks.load(from: root).paths == ["Daily/2026-08-23.md"])
        // Relative, so the same vault opened from another path still resolves.
        let text = try String(contentsOf: root.appending(path: ".inkstone/bookmarks.json"),
                              encoding: .utf8)
        #expect(!text.contains(root.path))
    }
}
