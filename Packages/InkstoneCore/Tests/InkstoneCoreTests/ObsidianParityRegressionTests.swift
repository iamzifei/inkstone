import Testing
import Foundation
@testable import InkstoneCore

/// Differences found by rendering real notes in Obsidian and in Inkstone and
/// comparing them (2026-11-18). Each case is how Obsidian reads the text.
@Suite("Obsidian parity regressions")
struct ObsidianParityRegressionTests {
    func tokens(_ text: String) -> [SyntaxToken] { SyntaxScanner().scan(text) }
    func links(_ text: String) -> [String] {
        tokens(text).compactMap { if case .markdownLink(let d) = $0.kind { return d } else { return nil } }
    }
    func mathCount(_ text: String) -> Int {
        tokens(text).filter { if case .mathInline = $0.kind { return true } else { return false } }.count
    }

    @Test func pricesAreNotMaths() {
        // Obsidian: a closing `$` followed by a digit does not close a formula.
        #expect(mathCount("定金 A$220 = A$200 + 10% GST") == 0)
        #expect(mathCount("costs $5 and $10 today") == 0)
        #expect(mathCount("inline $x^2$ maths") == 1)
        #expect(mathCount("$a$1") == 0)
    }

    @Test func bareURLsAreLinks() {
        #expect(links("see https://ozbeat.ai/ for more") == ["https://ozbeat.ai/"])
        #expect(links("| site | https://ozbeat.ai/news |") == ["https://ozbeat.ai/news"])
        #expect(links("www.example.com/path") == ["http://www.example.com/path"])
    }

    @Test func trailingPunctuationIsNotPartOfTheURL() {
        #expect(links("Go to https://a.com/x.") == ["https://a.com/x"])
        #expect(links("(https://a.com/y)") == ["https://a.com/y"])
        #expect(links("链接 https://a.com/z，然后") == ["https://a.com/z"])
        #expect(links("https://ozbeat.ai/news（推断）") == ["https://ozbeat.ai/news"])
    }

    @Test func urlsAlreadyInALinkOrCodeAreNotDoubled() {
        #expect(links("[https://a.com](https://a.com)") == ["https://a.com"])
        #expect(links("[site](https://a.com)") == ["https://a.com"])
        #expect(links("`https://a.com`").isEmpty)
        #expect(links("<https://a.com>") == ["https://a.com"])
        #expect(links("```\nhttps://a.com\n```").isEmpty)
    }

    @Test func aURLFragmentIsNotATag() {
        let t = tokens("see https://a.com/page#section now")
        #expect(links("see https://a.com/page#section now") == ["https://a.com/page#section"])
        #expect(!t.contains { if case .tag = $0.kind { return true } else { return false } })
    }

    func tagNames(_ text: String) -> [String] {
        tokens(text).compactMap { if case .tag(let n) = $0.kind { return n } else { return nil } }
    }

    /// Obsidian starts a tag only after whitespace or at the start of a line,
    /// or straight after another tag (`#a#b` is two). Seen in real notes:
    @Test func tagsFollowObsidiansBoundaryRule() {
        #expect(tagNames("超过99%的人！#短。做抖音").isEmpty)                    // after full-width ！
        #expect(tagNames("（迟来两天的视频）#母亲节 #妈妈") == ["妈妈"])           // after full-width ）
        #expect(tagNames("#抖音干货+#抖音起号") == ["抖音干货"])                   // after +
        #expect(tagNames("要#一分钟干货教学 #重庆短视频运营#干货分享 #新媒体运营")
                == ["重庆短视频运营", "干货分享", "新媒体运营"])                  // back to back
        #expect(tagNames("plain #tag here") == ["tag"])
        #expect(tagNames("#start of line") == ["start"])
        #expect(tagNames("issue #1 and #2026").isEmpty)                          // digits only
    }

    /// Obsidian ends a tag at whitespace or ASCII punctuation only; full-width
    /// punctuation is part of the tag, and a tag may start with a digit as
    /// long as it is not all digits. Exactly what Obsidian rendered for these
    /// lines of a real note.
    @Test func tagBodiesMatchObsidian() {
        #expect(tagNames("池子里 #7（表面解释先别急着推翻，80）和 #9（换个，74）")
                == ["7（表面解释先别急着推翻，80）和", "9（换个，74）"])
        #expect(tagNames("裁定 #28） 和 #25 ③") == ["28）"])
        #expect(tagNames("#13。原话见 #33）") == ["13。原话见", "33）"])
        #expect(tagNames("a #tag, b #two.") == ["tag", "two"])
        #expect(tagNames("#nested/tag-name_x") == ["nested/tag-name_x"])
    }

    /// Rendered in Obsidian itself (2026-11-18): a tag may also start right
    /// after emphasis / highlight / strikethrough markers or `[`, but not
    /// after `(` or a quote.
    @Test func tagsAfterInlineMarkupMatchObsidian() {
        #expect(tagNames("**#bold** text") == ["bold"])
        #expect(tagNames("==#mark== text") == ["mark"])
        #expect(tagNames("~~#del~~ text") == ["del"])
        #expect(tagNames("[#bracket] text") == ["bracket"])
        #expect(tagNames("(#paren) text").isEmpty)
        #expect(tagNames("\"#quote\" text").isEmpty)
        #expect(tagNames("| a | b |\n|---|---|\n| #cell | x |") == ["cell"])
        #expect(tagNames("中文#标签 x").isEmpty)
    }

    @Test func aURLInsideEmphasisIsALink() {
        #expect(links("_https://u.com_") == ["https://u.com"])
        #expect(links("**https://v.com**") == ["https://v.com"])
    }

    @Test func aBareURLHasNothingToConceal() throws {
        let token = try #require(tokens("x https://a.com y").first { if case .markdownLink = $0.kind { return true } else { return false } })
        #expect(token.range == token.contentRange)
    }
}
