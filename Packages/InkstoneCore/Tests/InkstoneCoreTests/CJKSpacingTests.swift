import Foundation
import Testing
@testable import InkstoneCore

@Suite("CJK–Latin spacing")
struct CJKSpacingTests {
    private func marked(_ s: String) -> String {
        let ns = s as NSString
        let positions = Set(CJKSpacing.positions(in: ns, range: NSRange(location: 0, length: ns.length)))
        var out = ""
        var i = 0
        while i < ns.length {
            let r = ns.rangeOfComposedCharacterSequence(at: i)
            out += ns.substring(with: r)
            if positions.contains(i) { out += "·" }
            i = NSMaxRange(r)
        }
        return out
    }

    @Test("Space goes on both sides of a Latin word inside Chinese, and nowhere else")
    func chineseAndLatin() {
        #expect(marked("用Inkstone写笔记") == "用·Inkstone·写笔记")
        #expect(marked("共3篇") == "共·3·篇")
        #expect(marked("用 Inkstone 写") == "用 Inkstone 写")      // already spaced
        #expect(marked("plain English") == "plain English")
        #expect(marked("中文，English") == "中文，English")          // punctuation is not a boundary
    }

    @Test("Japanese kana counts; Korean does not")
    func japaneseAndKorean() {
        #expect(marked("これはMacです") == "これは·Mac·です")
        #expect(marked("한국어Mac") == "한국어Mac")
    }

    @Test("A character outside the BMP is one character, and offsets stay right after it")
    func surrogates() {
        // U+20000 (𠀀) is a CJK Extension B ideograph: two UTF-16 units.
        #expect(marked("𠀀A") == "𠀀·A")
        #expect(marked("🙂用A") == "🙂用·A")
    }

    @Test("Positions respect the range they are asked about")
    func scoped() {
        let ns = "用A。用B" as NSString
        #expect(CJKSpacing.positions(in: ns, range: NSRange(location: 3, length: 2)) == [3])
    }
}
