import Testing
import Foundation
@testable import InkstoneCore

@Suite("Knowledge base creator")
struct KnowledgeBaseCreatorTests {
    func temp() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "kbc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func namesBecomeSafeFolderNames() {
        #expect(KnowledgeBaseCreator.folderName("  我的/资料:库 ", language: .simplifiedChinese) == "我的 资料 库")
        #expect(KnowledgeBaseCreator.folderName("...", language: .english) == "My Knowledge Base")
        #expect(KnowledgeBaseCreator.folderName(".hidden", language: .english) == "hidden")
        #expect(KnowledgeBaseCreator.folderName("", language: .traditionalChinese) == "我的知識庫")
    }

    @Test func createsTheSkeletonInANewFolder() throws {
        let parent = try temp(); defer { try? FileManager.default.removeItem(at: parent) }
        let kb = try KnowledgeBaseCreator.create(named: "我的知识库", in: parent, language: .simplifiedChinese)
        #expect(kb.lastPathComponent == "我的知识库")
        #expect(KnowledgeBaseLayout.detect(in: kb)?.language == .simplifiedChinese)
        #expect(FileManager.default.fileExists(atPath: kb.appending(path: "00-收件箱").path))
        #expect(FileManager.default.fileExists(atPath: kb.appending(path: "AGENTS.md").path))
    }

    @Test func neverCreatesInsideAFolderThatHasFiles() throws {
        let parent = try temp(); defer { try? FileManager.default.removeItem(at: parent) }
        let taken = parent.appending(path: "Notes")
        try FileManager.default.createDirectory(at: taken, withIntermediateDirectories: true)
        try Data("mine".utf8).write(to: taken.appending(path: "a.md"))
        let kb = try KnowledgeBaseCreator.create(named: "Notes", in: parent, language: .english)
        #expect(kb.lastPathComponent == "Notes 2")
        #expect(try FileManager.default.contentsOfDirectory(atPath: taken.path) == ["a.md"])
        // An empty one is used as is.
        let empty = parent.appending(path: "Empty")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        #expect(try KnowledgeBaseCreator.create(named: "Empty", in: parent, language: .english).lastPathComponent == "Empty")
    }

    @Test func adoptingAddsOnlyTheSystemFolderAndEntryFiles() throws {
        let folder = try temp(); defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder.appending(path: "Work"), withIntermediateDirectories: true)
        try Data("mine".utf8).write(to: folder.appending(path: "Work/plan.md"))
        try Data("# My readme".utf8).write(to: folder.appending(path: "README.md"))
        try KnowledgeBaseCreator.adopt(folder, language: .english)
        let top = Set(try FileManager.default.contentsOfDirectory(atPath: folder.path))
        #expect(top == ["Work", "README.md", "_System", "AGENTS.md", "SOURCE_OF_TRUTH.md", "00-Inbox"])
        #expect(try String(contentsOf: folder.appending(path: "README.md"), encoding: .utf8) == "# My readme")
        #expect(try String(contentsOf: folder.appending(path: "Work/plan.md"), encoding: .utf8) == "mine")
    }

    @Test func adoptingAnEmptyFolderLaysOutEverything() throws {
        let folder = try temp(); defer { try? FileManager.default.removeItem(at: folder) }
        try KnowledgeBaseCreator.adopt(folder, language: .traditionalChinese)
        #expect(FileManager.default.fileExists(atPath: folder.appending(path: "00-收件匣").path))
    }
}
