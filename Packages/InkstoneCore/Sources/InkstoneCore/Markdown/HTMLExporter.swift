import Foundation
import Markdown

/// Turns a note into one self-contained HTML file: CommonMark / GFM through
/// cmark (swift-markdown), Obsidian's own syntax — wiki links, embeds,
/// ==highlights==, #tags, %%comments%% — through our scanner first, so code
/// spans and blocks are left exactly as written. Images are inlined as data
/// URIs and the stylesheet is embedded: nothing is fetched when it is opened,
/// which is also what PDF export (printing this HTML) needs.
public enum HTMLExporter {
    /// The body of the note as HTML, without the frontmatter.
    /// - Parameter highlight: colours fenced code by language (the app passes
    ///   `CodeHighlighter`); nil leaves code plain.
    public static func bodyHTML(
        _ markdown: String, resolveAttachment: (String) -> URL?,
        highlight: ((_ code: String, _ language: String?) -> [CodeHighlighting.Span]?)? = nil
    ) -> String {
        let body = String(FrontmatterParser.parse(markdown).body)
        let source = body as NSString
        var edits: [(range: NSRange, text: String)] = []

        var inlined: [String: String] = [:]   // each image read and encoded once
        for token in SyntaxScanner().scan(body) {
            switch token.kind {
            case .wikiLink(let link):
                edits.append((token.range, #"<span class="wikilink">"# + escape(link.displayText) + "</span>"))
            case .embed(let link):
                edits.append((token.range, embedHTML(link, resolveAttachment: resolveAttachment, cache: &inlined)))
            case .tag:
                edits.append((token.range, #"<span class="tag">"# + escape(source.substring(with: token.range)) + "</span>"))
            case .comment:
                // %%Obsidian comments%% go; HTML comments stay — invisible
                // anyway, and CommonMark uses `<!-- -->` to separate lists.
                if source.substring(with: token.range).hasPrefix("%%") { edits.append((token.range, "")) }
            case .highlight:
                // Only the == delimiters change; what is inside is still Markdown.
                let open = NSRange(location: token.range.location, length: token.contentRange.location - token.range.location)
                let closeStart = NSMaxRange(token.contentRange)
                let close = NSRange(location: closeStart, length: NSMaxRange(token.range) - closeStart)
                edits.append((open, "<mark>"))
                edits.append((close, "</mark>"))
            default:
                continue
            }
        }

        // An edit inside another (a link inside a comment) is dropped — the
        // outer one replaces it anyway. Then apply back to front, so earlier
        // ranges stay valid.
        let outer = edits.filter { edit in
            !edits.contains { other in
                other.range != edit.range && other.range.length > edit.range.length
                    && NSIntersectionRange(other.range, edit.range) == edit.range
            }
        }
        let rewritten = NSMutableString(string: body)
        var floor = Int.max
        for edit in outer.sorted(by: { $0.range.location > $1.range.location }) {
            guard NSMaxRange(edit.range) <= floor else { continue }
            rewritten.replaceCharacters(in: edit.range, with: edit.text)
            floor = edit.range.location
        }
        let html = HTMLFormatter.format(rewritten as String)
        return highlight.map { colourCodeBlocks(in: html, with: $0) } ?? html
    }

    /// cmark writes a fenced block as `<pre><code class="language-x">…</code></pre>`
    /// with the code HTML-escaped. Each such block is re-emitted with its
    /// coloured runs in styled spans; anything else is left as it was.
    static func colourCodeBlocks(
        in html: String, with highlight: (_ code: String, _ language: String?) -> [CodeHighlighting.Span]?
    ) -> String {
        guard let pattern = try? NSRegularExpression(
            pattern: #"<pre><code class="language-([^"]+)">(.*?)</code></pre>"#,
            options: [.dotMatchesLineSeparators]) else { return html }
        let ns = html as NSString
        var out = ""
        var cursor = 0
        for match in pattern.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            let language = ns.substring(with: match.range(at: 1))
            let code = unescapeHTML(ns.substring(with: match.range(at: 2)))
            guard let spans = highlight(code, language), !spans.isEmpty else { continue }
            out += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            out += #"<pre><code class="language-\#(language)">"# + CodeHighlighting.colouredHTML(code: code, spans: spans) + "</code></pre>"
            cursor = NSMaxRange(match.range)
        }
        out += ns.substring(from: cursor)
        return out
    }

    private static func unescapeHTML(_ s: String) -> String {
        s.replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    /// A complete HTML document for the note.
    public static func document(
        _ markdown: String, title: String, resolveAttachment: (String) -> URL?,
        highlight: ((_ code: String, _ language: String?) -> [CodeHighlighting.Span]?)? = nil
    ) -> String {
        """
        <!doctype html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data:; style-src 'unsafe-inline'">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(escape(title))</title>
        <style>\(stylesheet)\(CodeHighlighting.stylesheet)</style>
        </head>
        <body>
        <article>
        \(bodyHTML(markdown, resolveAttachment: resolveAttachment, highlight: highlight))
        </article>
        </body>
        </html>

        """
    }

    private static let imageTypes: [String: String] = [
        "png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "gif": "image/gif",
        "webp": "image/webp", "svg": "image/svg+xml", "heic": "image/heic", "bmp": "image/bmp",
    ]

    /// Images larger than this are named, not inlined: a photo straight off a
    /// phone, base64-encoded and copied through the pipeline, costs several
    /// times its size in memory.
    public static let maxInlineImageBytes = 15_000_000

    private static func embedHTML(_ link: WikiLink, resolveAttachment: (String) -> URL?,
                                  cache: inout [String: String]) -> String {
        let ext = (link.target as NSString).pathExtension.lowercased()
        if let type = imageTypes[ext] {
            if let cached = cache[link.target] { return cached }
            if let url = resolveAttachment(link.target),
               let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize,
               bytes <= maxInlineImageBytes,
               let data = try? Data(contentsOf: url) {
                // Markdown image syntax, not an <img> tag: a tag alone on a
                // line opens a CommonMark HTML block, and the lines after it
                // would come out as raw text. Embed sizes are left to the
                // stylesheet (max-width: 100%).
                // Empty alt: a file name with * or _ in it would otherwise be
                // read as Markdown there.
                let image = "![](data:\(type);base64,\(data.base64EncodedString()))"
                cache[link.target] = image
                return image
            }
        }
        // A note, or a file we do not inline: say what was embedded.
        return #"<span class="embed">"# + escape(link.displayText) + "</span>"
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// Plain, print-friendly, light and dark. No web fonts, no URLs.
    static let stylesheet = """
    :root{color-scheme:light dark;--fg:#1d1d1f;--muted:#6e6e73;--bg:#fff;--rule:#d2d2d7;--code:#f5f5f7;--accent:#b5482d;--mark:#fff3a3}
    @media (prefers-color-scheme:dark){:root{--fg:#f5f5f7;--muted:#a1a1a6;--bg:#1d1d1f;--rule:#424245;--code:#2c2c2e;--accent:#e07a5f;--mark:#6b5d00}}
    @media print{:root{--fg:#000;--bg:#fff;--code:#f5f5f7;--mark:#fff3a3}article{padding:0;max-width:none}h1:first-child{margin-top:0}}
    *{-webkit-print-color-adjust:exact;print-color-adjust:exact}
    html{background:var(--bg);color:var(--fg)}
    body{margin:0;font:16px/1.65 -apple-system,BlinkMacSystemFont,"Helvetica Neue","PingFang SC","Hiragino Sans",sans-serif}
    article{max-width:46rem;margin:0 auto;padding:2.5rem 1.25rem}
    h1,h2,h3,h4{line-height:1.25;margin:1.6em 0 .5em}
    h1{font-size:2em}h2{font-size:1.5em}h3{font-size:1.2em}
    a{color:var(--accent)}
    code,pre{font:.9em ui-monospace,SFMono-Regular,Menlo,monospace;background:var(--code);border-radius:4px}
    code{padding:.1em .3em}pre{padding:1em;overflow:auto}pre code{padding:0;background:none}
    blockquote{margin:1em 0;padding:0 1em;border-left:3px solid var(--rule);color:var(--muted)}
    table{border-collapse:collapse;margin:1em 0}th,td{border:1px solid var(--rule);padding:.35em .7em;text-align:left}
    img{max-width:100%;height:auto}
    hr{border:0;border-top:1px solid var(--rule);margin:2em 0}
    mark{background:var(--mark);color:inherit;padding:0 .1em}
    .wikilink{color:var(--accent)}
    .tag{color:var(--accent);background:color-mix(in srgb,var(--accent) 12%,transparent);border-radius:999px;padding:0 .45em;font-size:.9em}
    .embed{color:var(--muted);font-style:italic}
    li>input[type=checkbox]{margin-right:.4em}
    """
}
