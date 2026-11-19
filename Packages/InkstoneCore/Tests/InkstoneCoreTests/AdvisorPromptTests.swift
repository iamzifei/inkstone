import Testing
import Foundation
@testable import InkstoneCore

@Suite("Advisor prompt")
struct AdvisorPromptTests {
    let layout = KnowledgeBaseLayout(language: .simplifiedChinese)

    func facts(text: String) -> FileFacts {
        FileFacts(url: URL(fileURLWithPath: "/x/note.md"), name: "note", ext: "md", kind: .markdown, size: 1, sha256: nil,
                  contentDate: .now, contentDateSource: "file", text: text, title: "标题", pixelSize: nil, duration: nil,
                  simHash: nil, perceptualHash: nil)
    }

    @Test func staysWithinItsBudgetAndLeavesOutTheMachinery() {
        let folders = ["10-项目/装修", "_系统", "_归档/待删除", "00-收件箱/x"] + (0..<500).map { "20-领域/领域\($0)" }
        let context = AdvisorContext(layout: layout, folders: folders, rules: "## 我的规则\n\n- 发票 → 20-领域/财务\n\n## 策略\n很长")
        let p = AdvisorPrompt.prompt(facts(text: String(repeating: "内容很多。", count: 2000)), context: context, budget: 3000)
        #expect(p.count <= 3000)
        #expect(p.contains("10-项目/装修"))
        #expect(!p.contains("- _系统"))
        #expect(!p.contains("待删除"))
        #expect(!p.contains("00-收件箱"))
        #expect(p.contains("标题"))
    }

    @Test func includesOnlyTheOwnRules() {
        let context = AdvisorContext(layout: layout, folders: [], rules: "## 我的规则\n\n- 发票 → 20-领域/财务\n<!-- 注释 -->\n\n## 默认策略\n不要发给模型")
        let p = AdvisorPrompt.prompt(facts(text: "短"), context: context)
        #expect(p.contains("发票 → 20-领域/财务"))
        #expect(!p.contains("不要发给模型"))
        #expect(!p.contains("注释"))
    }

    @Test func readsJSONEvenWrappedInProse() throws {
        let text = "Sure:\n```json\n{\"folder\": \"30-资料/园艺\", \"confidence\": 1.7, \"title\": \"玫瑰\", \"tags\": [\"园艺\", 3, \"\"], \"isPrivate\": false, \"reason\": \"讲园艺\"}\n```"
        let a = try #require(AdvisorPrompt.parse(text))
        #expect(a.folder == "30-资料/园艺")
        #expect(a.confidence == 1)              // clamped
        #expect(a.tags == ["园艺"])
        #expect(a.summary == nil)
    }

    @Test func rejectsAnswersWithoutAFolder() {
        #expect(AdvisorPrompt.parse("no json here") == nil)
        #expect(AdvisorPrompt.parse("{\"confidence\": 0.9}") == nil)
        #expect(AdvisorPrompt.parse("{\"folder\": \"\"}") == nil)
        #expect(AdvisorPrompt.parse("{broken") == nil)
    }

    @Test func privateFolderNamesAndPrivateTextNeverGoOffDevice() {
        let context = AdvisorContext(layout: layout, folders: ["私密/病历2025", "20-领域/病历", "30-资料/园艺"], rules: "## 我的规则\n- 银行流水 → 私密\n")
        let p = AdvisorPrompt.prompt(facts(text: "普通内容"), context: context)
        #expect(!p.contains("病历2025"))
        #expect(!p.contains("20-领域/病历"))
        #expect(p.contains("30-资料/园艺"))
        // A private word anywhere in the file stops it …
        let long = String(repeating: "普通的一句话。", count: 200) + "我的信用卡号码是……"
        #expect(!AdvisorPrompt.maySendOffDevice(facts(text: long)))
        // … but private words in folder names or the rules say nothing about this file.
        #expect(AdvisorPrompt.maySendOffDevice(facts(text: "周末去花市")))
    }

    @Test func aHangingAdvisorDoesNotHoldTheRound() async {
        struct Hang: PlacementAdvisor {
            func advise(_ facts: FileFacts, context: AdvisorContext) async throws -> PlacementAdvice? {
                try await Task.sleep(for: .seconds(3600)); return nil
            }
        }
        let start = ContinuousClock.now
        let answer = await Organizer.ask(Hang(), facts(text: ""), AdvisorContext(layout: layout, folders: [], rules: ""),
                                         timeout: .milliseconds(100))
        #expect(answer == nil)
        #expect(ContinuousClock.now - start < .seconds(5))
    }
}
