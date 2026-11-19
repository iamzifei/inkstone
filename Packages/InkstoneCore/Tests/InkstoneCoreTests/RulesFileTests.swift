import Testing
import Foundation
@testable import InkstoneCore

@Suite("Rules file")
struct RulesFileTests {
    @Test func restoringTheDefaultKeepsMyRules() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "rules-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try VaultBlueprint.apply(to: root, language: .simplifiedChinese)
        let layout = KnowledgeBaseLayout(language: .simplifiedChinese)
        let original = try #require(RulesFile.read(root: root, layout: layout))
        var text = original
        text = text.replacingOccurrences(of: "## 我的规则\n", with: "## 我的规则\n\n- 发票 → 20-领域/财务\n")
        text = text.replacingOccurrences(of: "## 0. 角色与底线", with: "## 0. 我乱改的")
        try RulesFile.save(text, expected: original, root: root, layout: layout)
        let restored = RulesFile.restoringDefaultPolicy(try #require(RulesFile.read(root: root, layout: layout)), language: .simplifiedChinese)
        #expect(restored.contains("- 发票 → 20-领域/财务"))
        #expect(!restored.contains("我乱改的"))
        #expect(restored.hasSuffix(OrganizingPolicy.defaultText(.simplifiedChinese)))
        #expect(OrganizingRules(rulesFileText: restored).rules.map(\.keyword) == ["发票"])
        // Restoring an untouched file changes nothing.
        let fresh = SystemFileText(layout: layout, date: .now).rules(OrganizingPolicy.defaultText(.simplifiedChinese))
        #expect(RulesFile.restoringDefaultPolicy(fresh, language: .simplifiedChinese) == fresh)
    }

    @Test func aFileWithoutTheRulesSectionIsReplacedWhole() {
        let out = RulesFile.restoringDefaultPolicy("random text", language: .english)
        #expect(out.contains("## My rules"))
        #expect(out.hasSuffix(OrganizingPolicy.defaultText(.english)))
    }

    @Test func aSaveNeverOverwritesAnEditFromElsewhere() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "rules-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try VaultBlueprint.apply(to: root, language: .english)
        let layout = KnowledgeBaseLayout(language: .english)
        let opened = try #require(RulesFile.read(root: root, layout: layout))
        // The iPad's edit arrives through sync.
        try (opened + "\n- From the iPad → 20-Areas/X\n").write(to: root.appending(path: layout.rulesFile), atomically: true, encoding: .utf8)
        #expect(throws: RulesFile.SaveError.self) { try RulesFile.save(opened + "mine", expected: opened, root: root, layout: layout) }
        #expect(try #require(RulesFile.read(root: root, layout: layout)).contains("From the iPad"))
    }

    @Test func aHeadingInMyRulesIsNotTakenForThePolicy() {
        let layout = KnowledgeBaseLayout(language: .english)
        let fresh = SystemFileText(layout: layout, date: .now).rules(OrganizingPolicy.defaultText(.english))
        let mine = fresh.replacingOccurrences(of: "## My rules\n", with: "## My rules\n\n# Work\n- Invoices → 20-Areas/Money\n")
        let restored = RulesFile.restoringDefaultPolicy(mine, language: .english)
        #expect(restored.contains("# Work\n- Invoices → 20-Areas/Money"))
        #expect(restored.hasSuffix(OrganizingPolicy.defaultText(.english)))
    }
}

