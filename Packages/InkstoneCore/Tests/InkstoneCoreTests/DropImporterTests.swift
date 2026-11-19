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
        #expect(try FileManager.default.contentsOfDirectory(atPath: kb.appending(path: "00-收件箱").path).isEmpty)
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
}
