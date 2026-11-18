import Testing
@testable import InkstoneCore

/// Command palette matching: every typed character must appear in order;
/// word starts and contiguous runs rank first.
@Suite("Command matcher")
struct CommandMatcherTests {
    let titles = ["New Note", "New Canvas", "Graph View", "Whole Vault Graph", "Export as PDF…",
                  "Export as HTML…", "Insert Template…", "Show Inspector", "Search Vault", "Sync with GitHub"]

    func rank(_ q: String) -> [String] { CommandMatcher.rank(q, titles) { $0 }.map { $0 } }

    @Test func emptyQueryKeepsOrder() { #expect(rank("") == titles) }

    @Test func subsequenceAndCaseInsensitive() {
        #expect(rank("pdf") == ["Export as PDF…"])
        #expect(rank("EXPHTML") == ["Export as HTML…"])
        #expect(rank("zzz").isEmpty)
    }

    @Test func wordStartsRankFirst() {
        // "gv": Graph View (both word starts) before Whole Vault Graph.
        #expect(rank("gv").first == "Graph View")
        #expect(rank("nn").first == "New Note")
        #expect(rank("sv").first == "Search Vault")
    }

    @Test func contiguousBeatsScattered() {
        #expect(rank("graph").first == "Graph View")
        #expect(rank("vault").first == "Whole Vault Graph" || rank("vault").first == "Search Vault")
    }

    @Test func otherScriptsMatch() {
        let zh = ["新建笔记", "导出为 PDF…", "插入模板…"]
        #expect(CommandMatcher.rank("导出", zh) { $0 } == ["导出为 PDF…"])
        #expect(CommandMatcher.rank("模板", zh) { $0 } == ["插入模板…"])
    }
}
