import Testing
import Foundation
@testable import InkstoneCore

@Suite("TEMP loss")
struct TempLossTests {
    @Test("what gets lost")
    func lost() {
        let cases: [(String, String)] = [
            ("全角冒号 frontmatter", "---\n编号：N19\n类型：认知\n---\n# 标题\n"),
            ("正常 frontmatter", "---\ntags: [a, b]\ntitle: T\n---\n# 标题\n"),
            ("图片嵌入", "见 ![[diagram.png]] 这张"),
            ("笔记嵌入", "见 ![[Some Note]] 这段"),
            ("注释", "正文 %%隐藏的%% 继续"),
            ("表格", "| a | b |\n| --- | --- |\n| 1 | 2 |"),
            ("数学", "行内 $x^2$ 和\n$$\nE=mc^2\n$$"),
            ("脚注", "文字[^1]\n\n[^1]: 注解内容"),
            ("标签", "带 #项目/进行中 标签"),
            ("callout", "> [!note] 标题\n> 正文"),
        ]
        for (name, md) in cases {
            let out = ReadingRenderer.render(md).text
            print("── \(name)")
            print("   IN : \(md.replacingOccurrences(of: "\n", with: "⏎"))")
            print("   OUT: \(out.replacingOccurrences(of: "\n", with: "⏎"))")
        }
    }
}
