import Foundation
import JavaScriptCore

/// Code colouring by language, the platform-free part: running highlight.js in
/// JavaScriptCore and turning its HTML into scoped ranges. The app wraps it in
/// a cache, a background queue and the editor's colours (`CodeHighlighter`).
public enum CodeHighlighting {

    /// One run of code in one scope, relative to the start of the code.
    public struct Span: Equatable, Sendable {
        public let range: NSRange
        /// The highlight.js scope's first word: "keyword", "string", "title"…
        public let scope: String
        public init(range: NSRange, scope: String) { self.range = range; self.scope = scope }
    }

    /// Turns highlight.js's HTML (`<span class="hljs-keyword">let</span> x`)
    /// into scoped ranges of the original code. Nested spans: the innermost
    /// scope wins for its text, which is how highlight.js's own themes read.
    /// Offsets are UTF-16, matching NSString and TextKit.
    public static func parse(_ html: String) -> [Span] {
        var spans: [Span] = []
        var stack: [String?] = []
        var offset = 0
        var runStart = 0

        func close() {
            if let scope = stack.last ?? nil, offset > runStart {
                spans.append(Span(range: NSRange(location: runStart, length: offset - runStart), scope: scope))
            }
            runStart = offset
        }

        let units = Array(html.utf16)
        var i = 0
        while i < units.count {
            switch units[i] {
            case 0x3C: // "<" — a tag
                var j = i + 1
                while j < units.count, units[j] != 0x3E { j += 1 }
                let tag = String(decoding: units[(i + 1)..<min(j, units.count)], as: UTF16.self)
                close()
                if tag.hasPrefix("/") {
                    if !stack.isEmpty { stack.removeLast() }
                } else if tag.hasPrefix("span") {
                    // A span without a scope of its own continues the outer one.
                    stack.append(scope(ofTag: tag) ?? (stack.last ?? nil))
                }
                i = j + 1
            case 0x26: // "&" — an entity stands for one character
                var j = i + 1
                while j < units.count, j - i < 10, units[j] != 0x3B { j += 1 }
                i = j + 1
                offset += 1
            default:
                offset += 1
                i += 1
            }
        }
        close()
        return spans
    }

    /// `span class="hljs-title function_"` → "title".
    static func scope(ofTag tag: String) -> String? {
        guard let start = tag.range(of: "class=\"") else { return nil }
        let value = tag[start.upperBound...].prefix { $0 != "\"" }
        let first = value.split(separator: " ").first.map(String.init) ?? ""
        return first.hasPrefix("hljs-") ? String(first.dropFirst(5)) : nil
    }

    /// The name highlight.js knows a fence's language by: lowercased, first
    /// word only (```swift title="x" is swift), common spellings it does not
    /// alias itself mapped. nil for no language or one that is not code.
    public static func normalised(_ language: String?) -> String? {
        guard let raw = language?.trimmingCharacters(in: .whitespaces).lowercased(), !raw.isEmpty else { return nil }
        let word = raw.split(whereSeparator: { $0 == " " || $0 == "{" || $0 == "," }).first.map(String.init) ?? raw
        switch word {
        case "mermaid", "math", "latex", "tex", "katex", "text", "txt", "plain", "plaintext", "toc": return nil
        case "zsh", "sh", "console", "terminal", "shell-session": return "bash"
        case "jsx", "mjs", "cjs": return "javascript"
        case "tsx", "mts": return "typescript"
        case "objc", "objective-c", "obj-c": return "objectivec"
        case "c#", "cs": return "csharp"
        case "c++", "hpp", "cc": return "cpp"
        case "html", "svg", "plist", "xhtml": return "xml"
        case "yml": return "yaml"
        case "golang": return "go"
        case "py", "py3": return "python"
        case "rb": return "ruby"
        case "rs": return "rust"
        case "kt", "kts": return "kotlin"
        case "md": return "markdown"
        case "jsonc", "json5": return "json"
        default: return word
        }
    }

    /// The colour group a scope is painted in, or nil for scopes left in the
    /// text colour (operators, punctuation, plain). Eight groups, GitHub's.
    public static func group(for scope: String) -> String? {
        switch scope {
        case "keyword", "selector-tag", "doctag", "template-tag", "type": return "keyword"
        case "title", "section", "selector-id", "selector-class": return "title"
        case "string", "regexp", "char", "template-variable", "addition": return "string"
        case "number", "literal", "symbol", "bullet", "attr", "attribute", "variable",
             "built_in", "selector-attr", "selector-pseudo", "link": return "number"
        case "comment", "quote", "meta": return "comment"
        case "name", "tag": return "name"
        case "params", "subst", "property": return "params"
        case "deletion": return "deletion"
        default: return nil
        }
    }

    /// Each group's colour as hex: (light, dark). GitHub's code palettes.
    static let palette: [String: (light: String, dark: String)] = [
        "keyword": ("CF222E", "FF7B72"), "title": ("8250DF", "D2A8FF"),
        "string": ("0A3069", "A5D6FF"), "number": ("0550AE", "79C0FF"),
        "comment": ("6E7781", "8B949E"), "name": ("116329", "7EE787"),
        "params": ("953800", "FFA657"), "deletion": ("82071E", "FFA198"),
    ]

    /// The colour for a scope as hex, or nil for scopes left in the text
    /// colour. Shared by the editor and the reading view.
    public static func hex(for scope: String, isDark: Bool) -> String? {
        group(for: scope).flatMap { palette[$0] }.map { isDark ? $0.dark : $0.light }
    }

    /// The export stylesheet's rules for the groups, light by default and dark
    /// under `prefers-color-scheme: dark`, so an export opened (or rendered to
    /// an image) in dark mode keeps its code readable.
    public static var stylesheet: String {
        let groups = palette.keys.sorted()
        let light = groups.map { ".hl-\($0){color:#\(palette[$0]!.light)}" }.joined()
        let dark = groups.map { ".hl-\($0){color:#\(palette[$0]!.dark)}" }.joined()
        // Printed (PDF) on white whatever the app's appearance: the light
        // colours again under print, as the page's own variables do.
        return light + "@media (prefers-color-scheme:dark){" + dark + "}" + "@media print{" + light + "}"
    }

    /// Colours a code block in finished HTML: the code (escaped, as cmark wrote
    /// it) re-emitted with each coloured run wrapped in a span of its group's
    /// class (`stylesheet` gives the colours).
    static func colouredHTML(code: String, spans: [Span]) -> String {
        let ns = code as NSString
        var out = ""
        var cursor = 0
        for span in spans.sorted(by: { $0.range.location < $1.range.location }) {
            guard span.range.location >= cursor, NSMaxRange(span.range) <= ns.length else { continue }
            if span.range.location > cursor {
                out += escapeHTML(ns.substring(with: NSRange(location: cursor, length: span.range.location - cursor)))
            }
            let text = escapeHTML(ns.substring(with: span.range))
            if let group = group(for: span.scope) {
                out += #"<span class="hl-\#(group)">"# + text + "</span>"
            } else {
                out += text
            }
            cursor = NSMaxRange(span.range)
        }
        if cursor < ns.length { out += escapeHTML(ns.substring(from: cursor)) }
        return out
    }

    static func escapeHTML(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    /// highlight.js loaded into its own JavaScriptCore context. Not thread-safe:
    /// use one from one thread (the app keeps one on a serial queue).
    public final class Engine {
        private let context: JSContext
        private let function: JSValue

        /// - Parameter source: the highlight.js library (`highlight.min.js`).
        public init?(source: String) {
            guard let context = JSContext() else { return nil }
            context.evaluateScript(source)
            // Unknown languages return null rather than throwing, so the caller
            // can remember them and stop asking.
            context.evaluateScript("""
            function inkstoneHighlight(code, language) {
              if (typeof hljs === "undefined" || !hljs.getLanguage(language)) return null;
              return hljs.highlight(code, { language: language, ignoreIllegals: true }).value;
            }
            """)
            guard let function = context.objectForKeyedSubscript("inkstoneHighlight"),
                  !function.isUndefined, context.exception == nil else { return nil }
            self.context = context
            self.function = function
        }

        /// The scoped runs of `code`; nil only when highlight.js does not know
        /// the language (worth remembering). A failure on this one block — an
        /// exception inside the library — is no colours for it, not a verdict
        /// on the language. `language` must already be normalised.
        public func spans(code: String, language: String) -> [Span]? {
            let result = function.call(withArguments: [code, language])
            if context.exception != nil {
                context.exception = nil
                return []
            }
            guard let result, !result.isUndefined else { return [] }
            if result.isNull { return nil }
            guard let html = result.toString() else { return [] }
            return parse(html)
        }
    }
}
