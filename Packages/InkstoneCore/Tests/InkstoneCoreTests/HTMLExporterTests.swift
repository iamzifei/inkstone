import Testing
import Foundation
@testable import InkstoneCore

/// Export to HTML (and, through it, PDF): CommonMark/GFM by cmark, Obsidian's
/// own syntax by our scanner, one self-contained file.
@Suite("HTML export")
struct HTMLExporterTests {
    func body(_ md: String, resolve: @escaping (String) -> URL? = { _ in nil }) -> String {
        HTMLExporter.bodyHTML(md, resolveAttachment: resolve)
    }

    @Test func markdownBasics() {
        let html = body("# Title\n\nSome **bold** and `code`.\n\n| a | b |\n|---|---|\n| 1 | 2 |\n")
        #expect(html.contains("<h1>Title</h1>"))
        #expect(html.contains("<strong>bold</strong>"))
        #expect(html.contains("<code>code</code>"))
        #expect(html.contains("<table>"))
    }

    @Test func obsidianSyntax() {
        let html = body("See [[Other Note|the other]] and [[Plain]]. ==marked== #tag %%hidden%%\n")
        #expect(html.contains(#"<span class="wikilink">the other</span>"#))
        #expect(html.contains(#"<span class="wikilink">Plain</span>"#))
        #expect(html.contains("<mark>marked</mark>"))
        #expect(html.contains(#"<span class="tag">#tag</span>"#))
        #expect(!html.contains("hidden"))
        #expect(!html.contains("[["))
    }

    @Test func codeIsLeftAlone() {
        let html = body("```\n[[not a link]] ==not marked==\n```\n")
        #expect(html.contains("[[not a link]] ==not marked=="))
        #expect(!html.contains("wikilink"))
    }

    @Test func frontmatterIsNotPrinted() {
        let html = body("---\ntags: [a]\ntitle: x\n---\n# Heading\n")
        #expect(!html.contains("tags:"))
        #expect(html.contains("<h1>Heading</h1>"))
    }

    @Test func aliasTextIsEscaped() {
        let html = body("[[R&D|Q&A]] and [[A&B]]\n")
        #expect(html.contains(#"<span class="wikilink">Q&amp;A</span>"#))
        #expect(html.contains(#"<span class="wikilink">A&amp;B</span>"#))
    }

    @Test func embeddedImagesAreInlined() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "inkstone-export-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let png = dir.appending(path: "pic.png")
        // 1x1 transparent PNG.
        try Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=")!.write(to: png)
        let html = body("![[pic.png]]\n", resolve: { $0 == "pic.png" ? png : nil })
        #expect(html.contains(#"<img src="data:image/png;base64,"#))
    }

    @Test func aWholeDocumentIsSelfContained() {
        let doc = HTMLExporter.document("# Hi\n", title: "Hi & bye", resolveAttachment: { _ in nil })
        #expect(doc.hasPrefix("<!doctype html>"))
        #expect(doc.contains("<title>Hi &amp; bye</title>"))
        #expect(doc.contains("<style>"))
        #expect(!doc.contains("http://") && !doc.contains("https://"))   // nothing fetched from the network
    }
}
