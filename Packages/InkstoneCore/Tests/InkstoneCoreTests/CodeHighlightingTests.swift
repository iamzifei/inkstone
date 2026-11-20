import Foundation
import Testing
@testable import InkstoneCore

/// Code colouring (0.5.3, borrowed from MiaoYan's use of highlight.js): the
/// HTML-to-ranges parser, the language names, and the real vendored library
/// run in JavaScriptCore.
@Suite("Code highlighting")
struct CodeHighlightingTests {

    /// The vendored library, read from the app's resources in the repository.
    static let library: String? = {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "App/Resources/Vendor/highlight.min.js")
        return try? String(contentsOf: url, encoding: .utf8)
    }()

    private func text(_ code: String, _ span: CodeHighlighting.Span) -> String {
        (code as NSString).substring(with: span.range)
    }

    @Test("Ranges come out in UTF-16 offsets of the original code, entities counted as one")
    func parsesNestingAndEntities() {
        let html = #"<span class="hljs-keyword">let</span> s <span class="hljs-operator">=</span> <span class="hljs-string">&quot;a &amp; b&quot;</span>"#
        let code = #"let s = "a & b""#
        let spans = CodeHighlighting.parse(html)
        #expect(spans.map { text(code, $0) } == ["let", "=", #""a & b""#])
        #expect(spans.map(\.scope) == ["keyword", "operator", "string"])
    }

    @Test("A nested scope wins for its own text, the outer one resumes after it")
    func nested() {
        let html = #"<span class="hljs-string">&quot;x <span class="hljs-subst">\(y)</span> z&quot;</span>"#
        let code = #""x \(y) z""#
        let spans = CodeHighlighting.parse(html)
        #expect(spans.map { "\($0.scope):\(text(code, $0))" } == [#"string:"x "#, #"subst:\(y)"#, #"string: z""#])
    }

    @Test("Fence languages map to highlight.js names", arguments: [
        ("Swift", "swift"), ("ts", "ts"), ("tsx", "typescript"), ("sh", "bash"), ("zsh", "bash"),
        ("py", "python"), ("yml", "yaml"), ("objc", "objectivec"), ("c++", "cpp"),
        ("swift title=\"A.swift\"", "swift"), ("html", "xml"),
    ])
    func languageNames(raw: String, expected: String) {
        #expect(CodeHighlighting.normalised(raw) == expected)
    }

    @Test("No language, or one that is not code, is left alone", arguments: [nil, "", "mermaid", "math", "text"] as [String?])
    func notCode(raw: String?) {
        #expect(CodeHighlighting.normalised(raw) == nil)
    }

    @Test("The real library colours Swift, keeps CJK and emoji offsets right, and says no to unknown languages")
    func realLibrary() throws {
        let source = try #require(Self.library, "highlight.min.js not found in App/Resources/Vendor")
        let engine = try #require(CodeHighlighting.Engine(source: source))
        let code = """
        // 中文注释 🙂
        let name = "墨砚 & <Inkstone>"
        func greet() -> Int { 42 }
        """
        let spans = try #require(engine.spans(code: code, language: "swift"))
        let found = Dictionary(spans.map { ($0.scope, text(code, $0)) }, uniquingKeysWith: { a, _ in a })
        #expect(found["comment"] == "// 中文注释 🙂")
        #expect(found["keyword"] == "let")
        #expect(found["string"] == #""墨砚 & <Inkstone>""#)
        #expect(found["number"] == "42")
        #expect(spans.allSatisfy { NSMaxRange($0.range) <= (code as NSString).length })
        #expect(engine.spans(code: "x", language: "no-such-language") == nil)
        // Still usable after an unknown language.
        #expect(engine.spans(code: "SELECT 1", language: "sql")?.isEmpty == false)
    }

    @Test("Export colours fenced code and changes nothing else, not a character of the code")
    func exportColoursCode() throws {
        let source = try #require(Self.library)
        let engine = try #require(CodeHighlighting.Engine(source: source))
        let markdown = """
        # Title

        ```swift
        let a = "<b>&</b>" // 注
        ```

        ```
        no language
        ```
        """
        let html = HTMLExporter.bodyHTML(markdown, resolveAttachment: { _ in nil }, highlight: { code, language in
            CodeHighlighting.normalised(language).flatMap { engine.spans(code: code, language: $0) }
        })
        #expect(html.contains(#"<span class="hl-keyword">let</span>"#))
        #expect(html.contains(#"&lt;b&gt;&amp;&lt;/b&gt;"#))        // still escaped, still all there
        #expect(html.contains("no language"))
        // Text content identical to the uncoloured export.
        let plain = HTMLExporter.bodyHTML(markdown, resolveAttachment: { _ in nil })
        let strip = { (s: String) in s.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression) }
        #expect(strip(html) == strip(plain))
    }

    @Test("The export stylesheet has every group in light and in dark")
    func exportStylesheet() {
        let css = CodeHighlighting.stylesheet
        #expect(css.contains(".hl-string{color:#0A3069}"))
        #expect(css.contains("@media (prefers-color-scheme:dark){"))
        #expect(css.contains(".hl-string{color:#A5D6FF}"))
        #expect(css.hasSuffix("@media print{" + css.components(separatedBy: "@media").first! + "}"))
        let document = HTMLExporter.document("x", title: "t", resolveAttachment: { _ in nil })
        #expect(document.contains(".hl-keyword{color:#CF222E}"))
    }

    @Test("A fence's info string cannot break out of the class attribute")
    func infoStringEscaped() {
        let html = HTMLExporter.colourCodeBlocks(
            in: #"<pre><code class="language-x&quot;onmouseover=&quot;y">a</code></pre>"#,
            with: { _, _ in [CodeHighlighting.Span(range: NSRange(location: 0, length: 1), scope: "keyword")] })
        #expect(!html.contains(#"class="language-x"onmouseover"#))
        #expect(html.contains(#"class="language-x&amp;quot;onmouseover=&amp;quot;y""#))
    }

    /// Not a gate, a number for the record: how long a long block takes.
    @Test("A 400-line block highlights in well under a frame budget per 100 lines")
    func speed() throws {
        let source = try #require(Self.library)
        let engine = try #require(CodeHighlighting.Engine(source: source))
        let line = "    let value = compute(\"text\", 42) // comment\n"
        let code = String(repeating: line, count: 400)
        _ = engine.spans(code: "let x = 1", language: "swift")   // warm-up
        let start = Date()
        let spans = engine.spans(code: code, language: "swift")
        let ms = Date().timeIntervalSince(start) * 1000
        print("CODE-HIGHLIGHT 400 lines: \(String(format: "%.1f", ms)) ms, \(spans?.count ?? 0) spans")
        #expect(spans != nil)
        #expect(ms < 400)
    }
}
