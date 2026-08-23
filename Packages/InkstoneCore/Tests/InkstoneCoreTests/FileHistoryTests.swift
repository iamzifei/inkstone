import Foundation
import Testing
@testable import InkstoneCore

/// Local snapshots, so a bad edit or a bad sync is recoverable.
///
/// The tests that matter here are the ones about *not* recording: notes save as
/// you type, and a snapshot per save would fill the window within a paragraph
/// and leave the history covering the last four minutes.
@Suite("File history")
struct FileHistoryTests {

    private func vault() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "inkstone-history-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test("A first save is recorded, and can be read back")
    func recordsAndReadsBack() throws {
        let root = try vault()
        defer { try? FileManager.default.removeItem(at: root) }
        let history = FileHistory(vaultRoot: root)

        let version = try #require(try history.record("Note.md", contents: Data("one\n".utf8)))
        #expect(history.versions(of: "Note.md").count == 1)
        #expect(history.contents(of: version) == Data("one\n".utf8))
    }

    @Test("Saving the same bytes again is not a version")
    func identicalContentIsSkipped() throws {
        let root = try vault()
        defer { try? FileManager.default.removeItem(at: root) }
        let history = FileHistory(vaultRoot: root)
        let start = Date()

        _ = try history.record("Note.md", contents: Data("one\n".utf8), now: start)
        // An hour later, so the interval is not what stops it.
        let second = try history.record("Note.md", contents: Data("one\n".utf8),
                                        now: start.addingTimeInterval(3600))
        #expect(second == nil)
        #expect(history.versions(of: "Note.md").count == 1)
    }

    /// The one that decides whether this feature is useful or noise.
    @Test("Edits inside the interval do not each become a version")
    func rapidEditsCollapse() throws {
        let root = try vault()
        defer { try? FileManager.default.removeItem(at: root) }
        let history = FileHistory(vaultRoot: root)
        let start = Date()

        _ = try history.record("Note.md", contents: Data("a".utf8), now: start)
        for seconds in stride(from: 2.0, through: 120.0, by: 2.0) {
            _ = try history.record("Note.md", contents: Data("a\(seconds)".utf8),
                                   now: start.addingTimeInterval(seconds))
        }
        #expect(history.versions(of: "Note.md").count == 1)

        // Past the interval, the next edit does get its own version.
        _ = try history.record("Note.md", contents: Data("later".utf8),
                               now: start.addingTimeInterval(FileHistory.minimumInterval + 1))
        #expect(history.versions(of: "Note.md").count == 2)
    }

    @Test("Only the newest versions are kept, newest first")
    func prunesByCount() throws {
        let root = try vault()
        defer { try? FileManager.default.removeItem(at: root) }
        let history = FileHistory(vaultRoot: root)
        let start = Date()

        let total = FileHistory.maximumPerFile + 10
        for index in 0..<total {
            _ = try history.record(
                "Note.md", contents: Data("edit \(index)".utf8),
                now: start.addingTimeInterval(Double(index) * (FileHistory.minimumInterval + 1)))
        }

        let versions = history.versions(of: "Note.md")
        #expect(versions.count == FileHistory.maximumPerFile)
        #expect(versions == versions.sorted { $0.date > $1.date })
        // The survivors are the newest, so the last edit is among them.
        #expect(history.contents(of: versions[0]) == Data("edit \(total - 1)".utf8))
    }

    /// An old file still being edited should not lose its history to the age
    /// limit alone — pruning must never leave nothing behind.
    @Test("Age never prunes the last remaining version")
    func ageKeepsAtLeastOne() throws {
        let root = try vault()
        defer { try? FileManager.default.removeItem(at: root) }
        let history = FileHistory(vaultRoot: root)
        let longAgo = Date().addingTimeInterval(-FileHistory.maximumAge * 3)

        _ = try history.record("Note.md", contents: Data("ancient".utf8), now: longAgo)
        _ = try history.record("Note.md", contents: Data("still ancient".utf8),
                               now: longAgo.addingTimeInterval(FileHistory.minimumInterval + 1))
        #expect(!history.versions(of: "Note.md").isEmpty)
    }

    @Test("A file too large for history is skipped rather than copied")
    func skipsLargeFiles() throws {
        let root = try vault()
        defer { try? FileManager.default.removeItem(at: root) }
        let history = FileHistory(vaultRoot: root)

        let big = Data(repeating: 0x41, count: FileHistory.maximumFileSize + 1)
        #expect(try history.record("Huge.md", contents: big) == nil)
        #expect(history.versions(of: "Huge.md").isEmpty)
    }

    @Test("History follows a rename, and goes when the file does")
    func followsRenameAndDeletion() throws {
        let root = try vault()
        defer { try? FileManager.default.removeItem(at: root) }
        let history = FileHistory(vaultRoot: root)

        _ = try history.record("Old.md", contents: Data("kept\n".utf8))
        history.rename("Old.md", to: "Archive/New.md")
        #expect(history.versions(of: "Old.md").isEmpty)
        #expect(history.versions(of: "Archive/New.md").count == 1)

        history.forget("Archive/New.md")
        #expect(history.versions(of: "Archive/New.md").isEmpty)
    }

    /// Two files must not share a folder however similar their paths are.
    @Test("Different files keep separate histories")
    func pathsDoNotCollide() throws {
        let root = try vault()
        defer { try? FileManager.default.removeItem(at: root) }
        let history = FileHistory(vaultRoot: root)

        _ = try history.record("a/Note.md", contents: Data("A".utf8))
        _ = try history.record("b/Note.md", contents: Data("B".utf8))
        #expect(history.versions(of: "a/Note.md").count == 1)
        #expect(history.versions(of: "b/Note.md").count == 1)
        #expect(history.contents(of: history.versions(of: "a/Note.md")[0]) == Data("A".utf8))
    }

    /// It lives under `.inkstone`, which sync excludes — history is local to the
    /// device that made it, and saying so is part of the feature.
    @Test("Snapshots live in the folder sync leaves alone")
    func storedUnderInkstone() throws {
        let root = try vault()
        defer { try? FileManager.default.removeItem(at: root) }
        let history = FileHistory(vaultRoot: root)
        let version = try #require(try history.record("Note.md", contents: Data("x".utf8)))
        #expect(version.url.path(percentEncoded: false).contains("/.inkstone/history/"))
    }
}
