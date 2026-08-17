import Testing
import Foundation
@testable import InkstoneCore

/// `![[photo.png|300]]` sizes an embed; `[[Meeting|notes]]` renames a link. The
/// two use the same pipe, so the only thing separating them is what follows it —
/// and reading a size where there is display text would render a note embed at
/// zero width.
@Suite("Embed size hints")
struct EmbedSizeTests {

    private func size(_ alias: String?) -> WikiLink.EmbedSize? {
        WikiLink(target: "photo.png", alias: alias).embedSize
    }

    @Test("A bare number is a width")
    func width() {
        #expect(size("300")?.width == 300)
        #expect(size("300")?.height == nil)
    }

    @Test("Width by height is an exact box")
    func widthByHeight() {
        #expect(size("300x200")?.width == 300)
        #expect(size("300x200")?.height == 200)
    }

    @Test("Spaces around the numbers are tolerated")
    func spaces() {
        #expect(size(" 300 x 200 ")?.width == 300)
        #expect(size(" 300 x 200 ")?.height == 200)
    }

    @Test("Display text is not a size")
    func displayText() {
        #expect(size("产品想法") == nil)
        #expect(size("notes") == nil)
        #expect(size("v2 draft") == nil)
        // The trap: alias text that happens to contain an `x`.
        #expect(size("box") == nil)
        #expect(size("300 pixels") == nil)
    }

    @Test("Nothing and nonsense are not sizes")
    func absent() {
        #expect(size(nil) == nil)
        #expect(size("") == nil)
        #expect(size("0") == nil, "a zero-wide embed is not what anyone meant")
        #expect(size("-40") == nil)
        #expect(size("300x") == nil)
        #expect(size("x200") == nil)
    }

    @Test("The scanner carries the hint through")
    func throughTheScanner() {
        let embeds = SyntaxScanner().scan("![[photo.png|160]] and ![[Meeting|notes]]")
            .compactMap { token -> WikiLink? in
                if case .embed(let link) = token.kind { return link }
                return nil
            }
        #expect(embeds.count == 2)
        #expect(embeds.first?.embedSize?.width == 160)
        #expect(embeds.last?.embedSize == nil, "an aliased note embed is not sized")
    }
}
