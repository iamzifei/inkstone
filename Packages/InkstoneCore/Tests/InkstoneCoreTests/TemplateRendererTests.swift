import Testing
import Foundation
@testable import InkstoneCore

/// Templates follow Obsidian's core Templates plugin, so a template folder
/// brought over from Obsidian renders the same here.
@Suite("Template renderer")
struct TemplateRendererTests {
    // 2026-11-18 09:05:07 in a fixed zone, so the test does not depend on the machine's.
    static let date: Date = {
        var c = DateComponents(); c.year = 2026; c.month = 11; c.day = 18; c.hour = 9; c.minute = 5; c.second = 7
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "Australia/Sydney")!
        return cal.date(from: c)!
    }()
    static let zone = TimeZone(identifier: "Australia/Sydney")!

    func render(_ s: String) -> String {
        TemplateRenderer.render(s, title: "Meeting notes", date: Self.date, timeZone: Self.zone)
    }

    @Test func defaultsMatchObsidian() {
        #expect(render("# {{title}}") == "# Meeting notes")
        #expect(render("{{date}}") == "2026-11-18")
        #expect(render("{{time}}") == "09:05")
    }

    @Test func momentStyleFormats() {
        #expect(render("{{date:YYYY/MM/DD}}") == "2026/11/18")
        #expect(render("{{date:dddd, D MMMM YYYY}}") == "Wednesday, 18 November 2026")
        #expect(render("{{time:HH:mm:ss}}") == "09:05:07")
        #expect(render("{{date:YYYY-MM-DD HH:mm}}") == "2026-11-18 09:05")
        #expect(render("{{date:[Week] W}}") == "Week 47")
    }

    /// Review 2026-11-18: tokens with no single Unicode field were mistranslated.
    @Test func tokensWithoutAUnicodeEquivalent() {
        #expect(render("{{date:MMMM Do YYYY}}") == "November 18th 2026")
        #expect(render("{{date:DDD}}") == "322")          // day of year, unpadded
        #expect(render("{{date:DDDD}}") == "322")
        #expect(render("{{date:Q}}") == "4")
        #expect(render("{{time:h:mm a}}") == "9:05 am")
        #expect(render("{{time:h:mm A}}") == "9:05 AM")
        #expect(render("{{date:X}}") == String(Int(Self.date.timeIntervalSince1970)))
        #expect(render("{{date:x}}") == String(Int(Self.date.timeIntervalSince1970 * 1000)))
        #expect(render("{{date:GGGG-[W]WW}}") == "2026-W47")
    }

    @Test func ordinals() {
        let cases = [(1, "1st"), (2, "2nd"), (3, "3rd"), (4, "4th"), (11, "11th"), (12, "12th"), (13, "13th"), (21, "21st"), (22, "22nd"), (23, "23rd")]
        for (n, s) in cases { #expect(TemplateRenderer.ordinal(n) == s) }
    }

    @Test func unknownPlaceholdersAreLeftAlone() {
        #expect(render("{{tp.date.now()}} and {{unknown}}") == "{{tp.date.now()}} and {{unknown}}")
        #expect(render("no placeholders") == "no placeholders")
    }

    @Test func spacingAndCaseInsideBraces() {
        #expect(render("{{ title }} {{DATE}}") == "Meeting notes 2026-11-18")
    }
}
