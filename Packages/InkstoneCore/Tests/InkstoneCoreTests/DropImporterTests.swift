import Testing
import Foundation
@testable import InkstoneCore

@Suite("Drop importer")
struct DropImporterTests {
    func setup() throws -> (URL, URL, KnowledgeBaseLayout) {
        let base = FileManager.default.temporaryDirectory.appending(path: "drop-\(UUID().uuidString)")
        let outside = base.appending(path: "Desktop"), kb = base.appending(path: "KB")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: kb, withIntermediateDirectories: true)
        try VaultBlueprint.apply(to: kb, language: .simplifiedChinese)
        return (outside, kb, KnowledgeBaseLayout(language: .simplifiedChinese))
    }

    @Test func copyLeavesTheOriginal() throws {
        let (outside, kb, layout) = try setup(); defer { try? FileManager.default.removeItem(at: outside.deletingLastPathComponent()) }
        let file = outside.appending(path: "报价.pdf"); try Data("pdf".utf8).write(to: file)
        let r = DropImporter.importItems([file], into: kb, layout: layout, action: .copy)
        #expect(r.first?.destination == "00-收件箱/报价.pdf")
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(try Data(contentsOf: kb.appending(path: "00-收件箱/报价.pdf")) == Data("pdf".utf8))
    }

    @Test func moveRemovesTheOriginalOnlyAfterACompleteCopy() throws {
        let (outside, kb, layout) = try setup(); defer { try? FileManager.default.removeItem(at: outside.deletingLastPathComponent()) }
        let folder = outside.appending(path: "Trip")
        try FileManager.default.createDirectory(at: folder.appending(path: "photos"), withIntermediateDirectories: true)
        try Data("a".utf8).write(to: folder.appending(path: "photos/1.jpg"))
        try Data("b".utf8).write(to: folder.appending(path: ".hidden"))
        let r = DropImporter.importItems([folder], into: kb, layout: layout, action: .move)
        #expect(r.first?.originalKept == false)
        #expect(!FileManager.default.fileExists(atPath: folder.path))
        #expect(FileManager.default.fileExists(atPath: kb.appending(path: "00-收件箱/Trip/photos/1.jpg").path))
        #expect(FileManager.default.fileExists(atPath: kb.appending(path: "00-收件箱/Trip/.hidden").path))
    }

    @Test func sameNamesGetANumberNeverOverwrite() throws {
        let (outside, kb, layout) = try setup(); defer { try? FileManager.default.removeItem(at: outside.deletingLastPathComponent()) }
        try Data("old".utf8).write(to: kb.appending(path: "00-收件箱/a.md"))
        let file = outside.appending(path: "a.md"); try Data("new".utf8).write(to: file)
        let r = DropImporter.importItems([file], into: kb, layout: layout, action: .copy)
        #expect(r.first?.destination == "00-收件箱/a 2.md")
        #expect(try String(contentsOf: kb.appending(path: "00-收件箱/a.md"), encoding: .utf8) == "old")
    }

    @Test func aFailedCopyLeavesTheOriginalAndNoDebris() throws {
        let (outside, kb, layout) = try setup(); defer { try? FileManager.default.removeItem(at: outside.deletingLastPathComponent()) }
        let missing = outside.appending(path: "gone.txt")
        let r = DropImporter.importItems([missing], into: kb, layout: layout, action: .move)
        #expect(r.first?.destination == nil)
        #expect(r.first?.error != nil)
        #expect(try visible(kb.appending(path: "00-收件箱")).isEmpty)
    }

    @Test func somethingAlreadyInTheVaultIsNotBroughtIn() throws {
        let (outside, kb, layout) = try setup(); defer { try? FileManager.default.removeItem(at: outside.deletingLastPathComponent()) }
        let inside = kb.appending(path: "30-资料/x.md"); try Data("x".utf8).write(to: inside)
        let r = DropImporter.importItems([inside], into: kb, layout: layout, action: .move)
        #expect(r.first?.destination == nil)
        #expect(FileManager.default.fileExists(atPath: inside.path))
    }

    @Test func aMoveWhoseOriginalCannotBeRemovedKeepsBoth() throws {
        let (outside, kb, layout) = try setup(); defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: outside.path)
            try? FileManager.default.removeItem(at: outside.deletingLastPathComponent())
        }
        let file = outside.appending(path: "locked.txt"); try Data("x".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: outside.path)   // can't delete from here
        let r = DropImporter.importItems([file], into: kb, layout: layout, action: .move)
        #expect(r.first?.destination == "00-收件箱/locked.txt")
        #expect(r.first?.originalKept == true)
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    // Review of #28.
    @Test func aFolderThatContainsTheVaultIsRefused() throws {
        let (outside, kb, layout) = try setup(); defer { try? FileManager.default.removeItem(at: outside.deletingLastPathComponent()) }
        let parent = kb.deletingLastPathComponent()
        let r = DropImporter.importItems([parent], into: kb, layout: layout, action: .move)
        #expect(r.first?.destination == nil)
        #expect(FileManager.default.fileExists(atPath: kb.appending(path: "AGENTS.md").path))
        #expect(try visible(kb.appending(path: "00-收件箱")).isEmpty)
    }

    @Test func symlinksAndEmptyFoldersComeAlongAndAreChecked() throws {
        let (outside, kb, layout) = try setup(); defer { try? FileManager.default.removeItem(at: outside.deletingLastPathComponent()) }
        let folder = outside.appending(path: "Proj")
        try FileManager.default.createDirectory(at: folder.appending(path: "empty"), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: folder.appending(path: "a.txt"))
        try FileManager.default.createSymbolicLink(atPath: folder.appending(path: "link").path, withDestinationPath: "a.txt")
        let r = DropImporter.importItems([folder], into: kb, layout: layout, action: .copy)
        #expect(r.first?.destination == "00-收件箱/Proj")
        let copied = kb.appending(path: "00-收件箱/Proj")
        #expect(FileManager.default.fileExists(atPath: copied.appending(path: "empty").path))
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: copied.appending(path: "link").path) == "a.txt")
        #expect(DropImporter.identical(folder, copied))
        try Data("y".utf8).write(to: copied.appending(path: "a.txt"))
        #expect(!DropImporter.identical(folder, copied))
    }

    @Test func anICloudPlaceholderIsNeverMoved() throws {
        let (outside, kb, layout) = try setup(); defer { try? FileManager.default.removeItem(at: outside.deletingLastPathComponent()) }
        let placeholder = outside.appending(path: ".report.pdf.icloud"); try Data("stub".utf8).write(to: placeholder)
        let r = DropImporter.importItems([placeholder], into: kb, layout: layout, action: .move)
        #expect(r.first?.destination == nil)
        #expect(FileManager.default.fileExists(atPath: placeholder.path))
    }

    @Test func noTemporaryCopyIsLeftBehind() throws {
        let (outside, kb, layout) = try setup(); defer { try? FileManager.default.removeItem(at: outside.deletingLastPathComponent()) }
        let file = outside.appending(path: "a.md"); try Data("x".utf8).write(to: file)
        _ = DropImporter.importItems([file], into: kb, layout: layout, action: .copy)
        let names = try visible(kb.appending(path: "00-收件箱"))
        #expect(names == ["a.md"])
    }

    @Test func aFolderWithNestedPlaceholdersIsNotMoved() throws {
        let (outside, kb, layout) = try setup(); defer { try? FileManager.default.removeItem(at: outside.deletingLastPathComponent()) }
        let folder = outside.appending(path: "Docs")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("stub".utf8).write(to: folder.appending(path: ".a.pdf.icloud"))
        let r = DropImporter.importItems([folder], into: kb, layout: layout, action: .move)
        #expect(r.first?.destination == nil)
        #expect(FileManager.default.fileExists(atPath: folder.appending(path: ".a.pdf.icloud").path))
    }

    @Test func aFreshTemporaryCopyIsNotSweptButAnOldOneIs() throws {
        let (outside, kb, layout) = try setup(); defer { try? FileManager.default.removeItem(at: outside.deletingLastPathComponent()) }
        let fresh = kb.appending(path: "00-收件箱/.big.mov\(Metadata.tempMarker)aaaa1111")
        let old = kb.appending(path: "00-收件箱/.old.mov\(Metadata.tempMarker)bbbb2222")
        try Data("x".utf8).write(to: fresh); try Data("y".utf8).write(to: old)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -2 * 86_400)], ofItemAtPath: old.path)
        DropImporter.sweepLeftovers(root: kb)
        #expect(FileManager.default.fileExists(atPath: fresh.path))
        #expect(!FileManager.default.fileExists(atPath: old.path))
        _ = layout
    }

    @Test func aCopyWithAnOldDateButAFreshNameIsNotSwept() throws {
        let (outside, kb, layout) = try setup(); defer { try? FileManager.default.removeItem(at: outside.deletingLastPathComponent()) }
        // Just made (the time is in its name), though copying kept the
        // original's two-year-old date.
        let temp = kb.appending(path: "\(layout.inbox)/" + Metadata.temporaryName(for: "old video.mov"))
        try Data("x".utf8).write(to: temp)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -2 * 365 * 86_400)], ofItemAtPath: temp.path)
        DropImporter.sweepLeftovers(root: kb)
        #expect(FileManager.default.fileExists(atPath: temp.path))
        // Made two days ago: swept.
        let stale = kb.appending(path: "\(layout.inbox)/" + Metadata.temporaryName(for: "x.mov", now: Date(timeIntervalSinceNow: -2 * 86_400)))
        try Data("y".utf8).write(to: stale)
        DropImporter.sweepLeftovers(root: kb)
        #expect(!FileManager.default.fileExists(atPath: stale.path))
    }

    /// A folder's entries without the skeleton's `.gitkeep` (2026-11-20: the
    /// empty inbox carries one so it syncs; it is not debris). Any other
    /// hidden leftover — a temporary copy — still counts.
    private func visible(_ folder: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path)
            .filter { $0 != SyncFilePolicy.keepFileName }.sorted()
    }
}
