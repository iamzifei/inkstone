import Foundation

/// The pure part of keeping notes in the system search index (Spotlight):
/// what changed since the last push, and a plain-text summary to show.
public enum SpotlightPlan {
    public struct Changes: Equatable, Sendable {
        public var upsert: [URL]
        public var delete: [URL]
        public var isEmpty: Bool { upsert.isEmpty && delete.isEmpty }
    }

    /// `pushed`: each note's modification date when it was last written to
    /// the index. `current`: the vault as indexed now. New or changed notes
    /// are written again; notes no longer in the vault (deleted, renamed,
    /// moved) are removed.
    public static func diff(pushed: [URL: Date], current: [URL: Date]) -> Changes {
        let upsert = current.compactMap { url, modified in pushed[url] == modified ? nil : url }
        let delete = pushed.keys.filter { current[$0] == nil }
        return Changes(upsert: upsert.sorted { $0.path < $1.path }, delete: delete.sorted { $0.path < $1.path })
    }

    /// The note as plain text, for the result's description: frontmatter,
    /// Markdown markers and link brackets removed, whitespace collapsed,
    /// cut at `limit` characters.
    public static func summary(of text: String, limit: Int) -> String {
        var body = String(FrontmatterParser.parse(text).body)
        let patterns: [(String, String)] = [
            (#"%%[\s\S]*?%%|<!--[\s\S]*?-->"#, ""),       // comments
            (#"!?\[\[([^\]|]*\|)?([^\]]*)\]\]"#, "$2"),   // [[target|label]] → label
            (#"!?\[([^\]]*)\]\([^)]*\)"#, "$1"),           // [text](url) → text
            (#"(?m)^\s{0,3}(#{1,6}|>|[-*+]|\d+\.)\s+"#, ""), // block markers
            (#"(\*\*|__|==|~~|\*|_|`)"#, ""),              // inline markers
            (#"\s+"#, " "),
        ]
        for (pattern, template) in patterns {
            body = body.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
        }
        body = body.trimmingCharacters(in: .whitespacesAndNewlines)
        return body.count > limit ? String(body.prefix(limit)) + "…" : body
    }
}
