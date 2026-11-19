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
        var text = RulesFile.read(root: root, layout: layout)
        text = text.replacingOccurrences(of: "## 我的规则\n", with: "## 我的规则\n\n- 发票 → 20-领域/财务\n")
        text = text.replacingOccurrences(of: "## 0. 角色与底线", with: "## 0. 我乱改的")
        try RulesFile.save(text, root: root, layout: layout)
        let restored = RulesFile.restoringDefaultPolicy(RulesFile.read(root: root, layout: layout), language: .simplifiedChinese)
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
}
