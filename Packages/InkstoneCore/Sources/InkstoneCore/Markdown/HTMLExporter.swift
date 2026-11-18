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
    public static func bodyHTML(_ markdown: String, resolveAttachment: (String) -> URL?) -> String {
        let body = String(FrontmatterParser.parse(markdown).body)
        let source = body as NSString
        var edits: [(range: NSRange, text: String)] = []

        for token in SyntaxScanner().scan(body) {
            switch token.kind {
            case .wikiLink(let link):
                edits.append((token.range, #"<span class="wikilink">"# + escape(link.displayText) + "</span>"))
            case .embed(let link):
                edits.append((token.range, embedHTML(link, resolveAttachment: resolveAttachment)))
            case .tag:
                edits.append((token.range, #"<span class="tag">"# + escape(source.substring(with: token.range)) + "</span>"))
            case .comment:
                edits.append((token.range, ""))
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

        // Apply back to front; an edit inside one already applied (a link in a
        // comment) is dropped.
        let rewritten = NSMutableString(string: body)
        var floor = Int.max
        for edit in edits.sorted(by: { $0.range.location > $1.range.location }) {
            guard NSMaxRange(edit.range) <= floor else { continue }
            rewritten.replaceCharacters(in: edit.range, with: edit.text)
            floor = edit.range.location
        }
        return HTMLFormatter.format(rewritten as String)
    }

    /// A complete HTML document for the note.
    public static func document(_ markdown: String, title: String, resolveAttachment: (String) -> URL?) -> String {
        """
        <!doctype html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(escape(title))</title>
        <style>\(stylesheet)</style>
        </head>
        <body>
        <article>
        \(bodyHTML(markdown, resolveAttachment: resolveAttachment))
        </article>
        </body>
        </html>

        """
    }

    private static let imageTypes: [String: String] = [
        "png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "gif": "image/gif",
        "webp": "image/webp", "svg": "image/svg+xml", "heic": "image/heic", "bmp": "image/bmp",
    ]

    private static func embedHTML(_ link: WikiLink, resolveAttachment: (String) -> URL?) -> String {
        let ext = (link.target as NSString).pathExtension.lowercased()
        if let type = imageTypes[ext], let url = resolveAttachment(link.target),
           let data = try? Data(contentsOf: url) {
            var size = ""
            if let s = link.embedSize {
                size = #" width="\#(Int(s.width))""#
                if let h = s.height { size += #" height="\#(Int(h))""# }
            }
            return #"<img src="data:\#(type);base64,\#(data.base64EncodedString())" alt="\#(escape(link.target))"\#(size)>"#
        }
        // A note or file we do not inline: say what was embedded.
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
