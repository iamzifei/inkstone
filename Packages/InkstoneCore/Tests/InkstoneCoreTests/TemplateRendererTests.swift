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

    @Test func unknownPlaceholdersAreLeftAlone() {
        #expect(render("{{tp.date.now()}} and {{unknown}}") == "{{tp.date.now()}} and {{unknown}}")
        #expect(render("no placeholders") == "no placeholders")
    }

    @Test func spacingAndCaseInsideBraces() {
        #expect(render("{{ title }} {{DATE}}") == "Meeting notes 2026-11-18")
    }
}
