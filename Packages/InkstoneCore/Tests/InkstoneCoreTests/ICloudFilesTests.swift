import Testing
import Foundation
@testable import InkstoneCore

@Suite("iCloud placeholders")
struct ICloudFilesTests {

    @Test("Recognises an eviction placeholder")
    func recognisesPlaceholders() {
        #expect(ICloudFiles.isPlaceholder(".Note.md.icloud"))
        #expect(ICloudFiles.isPlaceholder(".Meeting notes.md.icloud"))

        #expect(!ICloudFiles.isPlaceholder("Note.md"))
        #expect(!ICloudFiles.isPlaceholder(".DS_Store"))
        // A visible file that merely ends in .icloud is not a placeholder; the
        // leading dot is what makes it one.
        #expect(!ICloudFiles.isPlaceholder("Note.md.icloud"))
        #expect(!ICloudFiles.isPlaceholder(".icloud"))
    }

    @Test("Recovers the name the file will have once downloaded")
    func recoversNames() {
        #expect(ICloudFiles.materialisedName(for: ".Note.md.icloud") == "Note.md")
        #expect(ICloudFiles.materialisedName(for: ".A note (draft).md.icloud") == "A note (draft).md")
        #expect(ICloudFiles.materialisedName(for: ".图片.png.icloud") == "图片.png")
        #expect(ICloudFiles.materialisedName(for: "Note.md") == nil)
        #expect(ICloudFiles.materialisedName(for: ".inkstone") == nil)
    }

    @Test("An evicted note still appears in the file tree")
    func evictedNotesRemainVisible() throws {
        // The bug this guards: placeholders are hidden files, so a scan that
        // skips hidden files loses the note entirely and the sidebar shows a
        // vault that has apparently lost its contents.
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "inkstone-icloud-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try Data("# Here".utf8).write(to: root.appending(path: "Present.md"))
        try Data().write(to: root.appending(path: ".Evicted.md.icloud"))
        // Ordinary hidden files must stay hidden.
        try Data().write(to: root.appending(path: ".DS_Store"))
        try FileManager.default.createDirectory(
            at: root.appending(path: ".inkstone"), withIntermediateDirectories: true
        )

        let names = (VaultScanner().scan(root).children ?? []).map(\.name)
        #expect(names.contains("Present.md"))
        #expect(names.contains("Evicted.md"), "an evicted note must still be listed")
        #expect(!names.contains(where: { $0.hasPrefix(".") }))
        #expect(names.count == 2)
    }

    @Test("A file and its leftover placeholder are listed once")
    func downloadedFileIsNotDuplicated() throws {
        // Both can exist for a moment while a download completes.
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "inkstone-icloud-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try Data("# Here".utf8).write(to: root.appending(path: "Note.md"))
        try Data().write(to: root.appending(path: ".Note.md.icloud"))

        let names = (VaultScanner().scan(root).children ?? []).map(\.name)
        #expect(names == ["Note.md"])
    }

    @Test("A genuinely missing file is not reported as downloaded")
    func missingFileIsNotDownloaded() {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "inkstone-absent-\(UUID().uuidString).md")
        // No placeholder either, so this must fail immediately rather than
        // waiting out the timeout.
        #expect(!ICloudFiles.ensureDownloaded(url, timeout: 5))
    }

    @Test("An existing file needs no download")
    func existingFileIsAlreadyDownloaded() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "inkstone-present-\(UUID().uuidString).md")
        try Data("hi".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(ICloudFiles.ensureDownloaded(url, timeout: 0))
    }
}
