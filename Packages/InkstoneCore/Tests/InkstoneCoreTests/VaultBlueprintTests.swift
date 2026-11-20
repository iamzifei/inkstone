import Testing
import Foundation
@testable import InkstoneCore

/// 0.5.0 P1: a new knowledge base gets a skeleton and three entry files; an
/// existing folder only gets what is missing, and nothing a person wrote is
/// ever overwritten.
@Suite("Vault blueprint")
struct VaultBlueprintTests {
    func tempVault() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "kb-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    func exists(_ root: URL, _ path: String) -> Bool {
        FileManager.default.fileExists(atPath: root.appending(path: path).path(percentEncoded: false))
    }
    func read(_ root: URL, _ path: String) throws -> String {
        try String(contentsOf: root.appending(path: path), encoding: .utf8)
    }

    @Test(arguments: [KnowledgeBaseLanguage.simplifiedChinese, .traditionalChinese, .english])
    func createsTheSkeletonInTheVaultsLanguage(_ language: KnowledgeBaseLanguage) throws {
        let root = try tempVault(); defer { try? FileManager.default.removeItem(at: root) }
        let layout = KnowledgeBaseLayout(language: language)
        let created = try VaultBlueprint.apply(to: root, language: language, date: Date(timeIntervalSince1970: 0))
        for folder in layout.allFolders { #expect(exists(root, folder), "\(folder)") }
        for file in [layout.rulesFile, layout.logFile, layout.indexFile, layout.duplicatesFile,
                     "AGENTS.md", "README.md", "SOURCE_OF_TRUTH.md"] {
            #expect(exists(root, file), "\(file)")
        }
        #expect(!created.isEmpty)
        // The language is read back from the folders themselves.
        #expect(KnowledgeBaseLayout.detect(in: root)?.language == language)
    }

    @Test func folderNamesPerLanguage() {
        #expect(KnowledgeBaseLayout(language: .simplifiedChinese).inbox == "00-收件箱")
        #expect(KnowledgeBaseLayout(language: .traditionalChinese).inbox == "00-收件匣")
        #expect(KnowledgeBaseLayout(language: .english).inbox == "00-Inbox")
        #expect(KnowledgeBaseLayout(language: .simplifiedChinese).trash == "_归档/待删除")
    }

    @Test func applyingTwiceChangesNothing() throws {
        let root = try tempVault(); defer { try? FileManager.default.removeItem(at: root) }
        _ = try VaultBlueprint.apply(to: root, language: .simplifiedChinese)
        let before = try snapshot(root)
        let second = try VaultBlueprint.apply(to: root, language: .simplifiedChinese)
        #expect(second.isEmpty)
        #expect(try snapshot(root) == before)
    }

    @Test func anExistingFolderOnlyGetsWhatIsMissing() throws {
        let root = try tempVault(); defer { try? FileManager.default.removeItem(at: root) }
        // A hand-made vault: its own README and AGENTS, its own folders.
        try "# My vault\n\nMine.\n".write(to: root.appending(path: "README.md"), atomically: true, encoding: .utf8)
        try "# Rules\n\nDo X.\n".write(to: root.appending(path: "AGENTS.md"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: root.appending(path: "A-产品"), withIntermediateDirectories: true)
        try "note".write(to: root.appending(path: "A-产品/x.md"), atomically: true, encoding: .utf8)
        _ = try VaultBlueprint.apply(to: root, language: .simplifiedChinese, skeleton: false)
        #expect(try read(root, "README.md") == "# My vault\n\nMine.\n")
        #expect(try read(root, "AGENTS.md") == "# Rules\n\nDo X.\n")
        #expect(try read(root, "A-产品/x.md") == "note")
        #expect(exists(root, "SOURCE_OF_TRUTH.md"))          // missing one is created
        #expect(exists(root, "_系统/整理规则.md"))              // system files are added
        #expect(!exists(root, "10-项目"))                        // but no skeleton forced on it
    }

    @Test func entryFilesKeepWhatThePersonWroteAroundTheAutoBlocks() throws {
        let root = try tempVault(); defer { try? FileManager.default.removeItem(at: root) }
        _ = try VaultBlueprint.apply(to: root, language: .english)
        let readme = root.appending(path: "README.md")
        let original = try String(contentsOf: readme, encoding: .utf8)
        let edited = "My own intro.\n\n" + original + "\n## My notes\n\nKeep this.\n"
        try edited.write(to: readme, atomically: true, encoding: .utf8)
        // Something changes in the vault: a new project folder, with a note in
        // it. (2026-11-20: an empty folder no longer counts — git cannot carry
        // it, so listing it made each device's entry files differ. A folder
        // with something in it is the change this test is about.)
        try FileManager.default.createDirectory(at: root.appending(path: "10-Projects/Garden"), withIntermediateDirectories: true)
        try Data("plan".utf8).write(to: root.appending(path: "10-Projects/Garden/Plan.md"))
        let changed = try EntryFiles.refresh(in: root)
        let now = try String(contentsOf: readme, encoding: .utf8)
        #expect(changed.contains("README.md"))
        #expect(now.hasPrefix("My own intro.\n\n"))
        #expect(now.hasSuffix("## My notes\n\nKeep this.\n"))
        #expect(now.contains("Garden"))
    }

    @Test func refreshWritesNothingWhenNothingChanged() throws {
        let root = try tempVault(); defer { try? FileManager.default.removeItem(at: root) }
        _ = try VaultBlueprint.apply(to: root, language: .simplifiedChinese)
        #expect(try EntryFiles.refresh(in: root).isEmpty)
    }

    @Test func entryFilesWithoutAutoBlocksAreLeftAlone() throws {
        let root = try tempVault(); defer { try? FileManager.default.removeItem(at: root) }
        _ = try VaultBlueprint.apply(to: root, language: .simplifiedChinese)
        try "# 我自己的入口\n".write(to: root.appending(path: "AGENTS.md"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: root.appending(path: "10-项目/新项目"), withIntermediateDirectories: true)
        _ = try EntryFiles.refresh(in: root)
        #expect(try read(root, "AGENTS.md") == "# 我自己的入口\n")
    }

    @Test func entryFilesDescribeTheRealTree() throws {
        let root = try tempVault(); defer { try? FileManager.default.removeItem(at: root) }
        _ = try VaultBlueprint.apply(to: root, language: .simplifiedChinese)
        try FileManager.default.createDirectory(at: root.appending(path: "10-项目/装修"), withIntermediateDirectories: true)
        for i in 0..<3 { try "x".write(to: root.appending(path: "10-项目/装修/n\(i).md"), atomically: true, encoding: .utf8) }
        _ = try EntryFiles.refresh(in: root)
        let sot = try read(root, "SOURCE_OF_TRUTH.md")
        #expect(sot.contains("10-项目/装修"))
        #expect(sot.contains("_系统/整理规则.md"))
        let agents = try read(root, "AGENTS.md")
        #expect(agents.contains("00-收件箱"))
        #expect(agents.contains("_归档/待删除"))
    }

    func snapshot(_ root: URL) throws -> [String: String] {
        var out: [String: String] = [:]
        let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)!
        for case let url as URL in e {
            let rel = String(url.path(percentEncoded: false).dropFirst(root.path(percentEncoded: false).count))
            out[rel] = (try? String(contentsOf: url, encoding: .utf8)) ?? "<dir>"
        }
        return out
    }

    // Review 2026-11-19.
    @Test func aQuotedOrDuplicatedMarkerNeverWipesText() throws {
        let root = try tempVault(); defer { try? FileManager.default.removeItem(at: root) }
        _ = try VaultBlueprint.apply(to: root, language: .english)
        let readme = root.appending(path: "README.md")
        let original = try String(contentsOf: readme, encoding: .utf8)
        // The person quotes the marker in their own text, above the block.
        let quoted = "How it works: Inkstone rewrites what's after `<!-- inkstone:auto:start -->`.\n\nPrecious paragraph.\n\n" + original
        try quoted.write(to: readme, atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: root.appending(path: "10-Projects/New"), withIntermediateDirectories: true)
        _ = try EntryFiles.refresh(in: root)
        #expect(try String(contentsOf: readme, encoding: .utf8).contains("Precious paragraph."))
        // Two blocks: ambiguous, so the file is left alone.
        let doubled = original + "\n" + original
        try doubled.write(to: readme, atomically: true, encoding: .utf8)
        _ = try EntryFiles.refresh(in: root)
        #expect(try String(contentsOf: readme, encoding: .utf8) == doubled)
        // Markers inside a code fence are not a block.
        let fenced = "# Mine\n\n```\n<!-- inkstone:auto:start -->\nexample\n<!-- inkstone:auto:end -->\n```\n"
        try fenced.write(to: readme, atomically: true, encoding: .utf8)
        _ = try EntryFiles.refresh(in: root)
        #expect(try String(contentsOf: readme, encoding: .utf8) == fenced)
    }

    @Test func aStrayFolderNameDoesNotMakeAVaultLookLikeAnotherLanguage() throws {
        let root = try tempVault(); defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appending(path: "_System"), withIntermediateDirectories: true)
        #expect(KnowledgeBaseLayout.detect(in: root) == nil)
        _ = try VaultBlueprint.apply(to: root, language: .simplifiedChinese, skeleton: false)
        #expect(exists(root, "_系统/整理规则.md"))
        #expect(!exists(root, "_System/Organizing Rules.md"))
        #expect(KnowledgeBaseLayout.detect(in: root)?.language == .simplifiedChinese)
    }

    @Test func folderNamesCannotBreakTheTables() throws {
        let root = try tempVault(); defer { try? FileManager.default.removeItem(at: root) }
        _ = try VaultBlueprint.apply(to: root, language: .english)
        for name in ["a|b", "c`d", "x <!-- inkstone:auto:end --> y"] {
            try FileManager.default.createDirectory(at: root.appending(path: "10-Projects/\(name)"), withIntermediateDirectories: true)
        }
        _ = try EntryFiles.refresh(in: root)
        let sot = try read(root, "SOURCE_OF_TRUTH.md")
        #expect(sot.components(separatedBy: "<!-- inkstone:auto:end -->").count == 2)   // exactly one end marker
        for line in sot.split(separator: "\n") where line.hasPrefix("| ") && line.contains("a") && line.contains("b") && line.contains("10-Projects/a") {
            #expect(line.components(separatedBy: " | ").count == 3)                     // still three cells
        }
        // Refreshing again is stable.
        #expect(try EntryFiles.refresh(in: root).isEmpty)
    }

    @Test func longListsAreCapped() throws {
        let root = try tempVault(); defer { try? FileManager.default.removeItem(at: root) }
        _ = try VaultBlueprint.apply(to: root, language: .english)
        // Each with a note: empty folders are not listed (2026-11-20, see above).
        for i in 0..<60 {
            try FileManager.default.createDirectory(at: root.appending(path: "20-Areas/a\(i)"), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: root.appending(path: "20-Areas/a\(i)/n.md"))
        }
        _ = try EntryFiles.refresh(in: root)
        let sot = try read(root, "SOURCE_OF_TRUTH.md")
        #expect(sot.components(separatedBy: "20-Areas/a").count - 1 <= 21)
        #expect(sot.contains("40 more") || sot.contains("more"))
    }

    @Test func aFileWhereAFolderShouldBeDoesNotAbortSetup() throws {
        let root = try tempVault(); defer { try? FileManager.default.removeItem(at: root) }
        try "not a folder".write(to: root.appending(path: "30-资料"), atomically: true, encoding: .utf8)
        _ = try VaultBlueprint.apply(to: root, language: .simplifiedChinese)
        #expect(try read(root, "30-资料") == "not a folder")
        #expect(exists(root, "AGENTS.md"))
        #expect(exists(root, "50-产出"))
    }
}
