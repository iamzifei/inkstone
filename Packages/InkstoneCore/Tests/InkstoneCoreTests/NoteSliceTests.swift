import Testing
import Foundation
@testable import InkstoneCore

/// Where an embed's content comes from. The rules are all about text and all
/// easy to get subtly wrong — a section that stops at the first subheading, an
/// anchor that drags in the paragraph after it — so they are pinned here rather
/// than discovered in a note.
@Suite("Note slices")
struct NoteSliceTests {

    private let note = """
    ---
    tags: [demo]
    ---

    Intro paragraph.

    ## First section

    Body of first.

    ### A subsection

    Body of the subsection.

    ## Second section

    Body of second.

    A paragraph worth linking to.
    It runs over two lines. ^target

    Another paragraph after it.
    """

    private func slice(_ fragment: String?) -> String {
        let range = NoteSlice.range(in: note, fragment: fragment)
        return (note as NSString).substring(with: range)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @Test("No fragment gives the body, without the frontmatter")
    func wholeBody() {
        let body = slice(nil)
        #expect(body.hasPrefix("Intro paragraph."))
        #expect(!body.contains("tags: [demo]"), "frontmatter is properties, not content")
        #expect(body.contains("Another paragraph after it."))
    }

    @Test("A heading brings its own subsections and stops at the next peer")
    func section() {
        let first = slice("First section")
        #expect(first.hasPrefix("## First section"))
        #expect(first.contains("Body of first."))
        #expect(first.contains("### A subsection"), "a subsection belongs to its section")
        #expect(first.contains("Body of the subsection."))
        #expect(!first.contains("## Second section"), "and stops at the next heading of the same level")
    }

    @Test("A subsection stops at the next heading of any higher level")
    func subsection() {
        let sub = slice("A subsection")
        #expect(sub.contains("Body of the subsection."))
        #expect(!sub.contains("## Second section"))
    }

    @Test("The last section runs to the end")
    func lastSection() {
        let second = slice("Second section")
        #expect(second.contains("Body of second."))
        #expect(second.contains("Another paragraph after it."))
    }

    @Test("Heading lookup ignores case and surrounding space")
    func headingLookup() {
        #expect(slice("  first SECTION  ").hasPrefix("## First section"))
    }

    @Test("A block anchor brings its whole block and nothing after it")
    func blockAnchor() {
        let block = slice("^target")
        #expect(block.contains("A paragraph worth linking to."))
        #expect(block.contains("It runs over two lines."), "the block is the run of non-blank lines")
        #expect(!block.contains("Another paragraph after it."))
        #expect(!block.contains("Body of second."), "nor the paragraph before it")
    }

    @Test("A fragment the note does not have gives nothing")
    func missing() {
        // Empty, not the whole note: a typo in a heading name must not silently
        // transclude the entire file.
        #expect(slice("No Such Heading").isEmpty)
        #expect(slice("^no-such-anchor").isEmpty)
    }

    @Test("The anchor is stripped from what gets shown")
    func strippingAnchor() {
        #expect(NoteSlice.strippingAnchor("It runs over two lines. ^target") == "It runs over two lines.")
        #expect(NoteSlice.strippingAnchor("no anchor here") == "no anchor here")
        // A caret mid-line is superscript or arithmetic, not an anchor.
        #expect(NoteSlice.strippingAnchor("2^10 = 1024") == "2^10 = 1024")
    }

    @Test("A note with no frontmatter is all body")
    func noFrontmatter() {
        let plain = "# Title\n\nJust text.\n"
        let range = NoteSlice.range(in: plain, fragment: nil)
        #expect(range.location == 0)
        #expect(range.length == (plain as NSString).length)
    }
}
