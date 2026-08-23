import Foundation
import Testing
@testable import InkstoneCore

/// What a vault file should open as.
///
/// Everything that was not a canvas used to open as text, so a JPEG in the
/// sidebar opened as a screenful of mojibake. The fix is not a longer list of
/// extensions — a vault holds whatever its owner put there — it is asking the
/// bytes when the extension does not settle it.
@Suite("Deciding how to open a file")
struct FileOpeningTests {

    private func decide(_ name: String, _ bytes: Data? = nil) -> FileOpening {
        FileOpening.decide(for: URL(fileURLWithPath: "/vault/\(name)"), sampling: bytes)
    }

    @Test("Kinds that are never text are settled by extension alone")
    func binaryKindsByExtension() {
        #expect(decide("vt-hero-glitch.jpeg") == .preview(.image))
        #expect(decide("Clip.mp4") == .preview(.video))
        #expect(decide("Take.m4a") == .preview(.audio))
        #expect(decide("Paper.pdf") == .preview(.pdf))
        #expect(decide("Map.canvas") == .canvas)
    }

    @Test("Markdown does not need the bytes read")
    func markdownIsText() {
        #expect(decide("Note.md") == .text)
        #expect(decide("Note.markdown") == .text)
    }

    /// The case a fixed allowlist gets wrong: extensions nobody thought to list.
    @Test("An unlisted extension is decided by its contents")
    func unknownExtensionsAreSniffed() {
        #expect(decide("script.py", Data("print('hi')\n".utf8)) == .text)
        #expect(decide("subtitles.srt", Data("1\n00:00:01,000\n".utf8)) == .text)
        #expect(decide("notes.tex", Data("\\section{One}\n".utf8)) == .text)
        #expect(decide("figures.csv", Data("a,b\n1,2\n".utf8)) == .text)
    }

    @Test("A NUL byte means binary, wherever it is")
    func nulMeansBinary() {
        var data = Data(repeating: 0x41, count: 4000)   // a long ASCII run first
        data.append(0)
        data.append(contentsOf: [0xFF, 0xFE])
        #expect(decide("thing.bin", data) == .preview(.other))
    }

    @Test("Bytes that are not UTF-8 are binary")
    func invalidUTF8IsBinary() {
        // 0xC3 starts a two-byte sequence; 0x28 cannot continue it.
        let data = Data([0xC3, 0x28, 0xC3, 0x28, 0xC3, 0x28])
        #expect(decide("thing.dat", data) == .preview(.other))
    }

    /// A sample cut mid-character is the sniff's own doing, not the file's.
    @Test("A multi-byte character split by the sample is still text")
    func truncatedMultibyteIsStillText() {
        let full = Data("念念不忘，必有回响。".utf8)
        #expect(FileOpening.looksLikeText(full))
        #expect(FileOpening.looksLikeText(full.dropLast(1)))
        #expect(FileOpening.looksLikeText(full.dropLast(2)))
    }

    @Test("An empty file is text, because a new note is empty")
    func emptyIsText() {
        #expect(decide("Untitled.md", Data()) == .text)
        #expect(decide("Untitled", Data()) == .text)
    }

    @Test("Unreadable contents fall back to a preview rather than to mojibake")
    func unreadableFallsBackToPreview() {
        #expect(decide("mystery", nil) == .preview(.other))
    }
}
