import Testing
import Foundation
@testable import InkstoneCore

/// Element counts per note, in the same categories as the Obsidian-side
/// script (`scratchpad/cmp/obsidian-run.js`), so the two renderers can be
/// compared note by note.
///
///     INKSTONE_PARITY_DIR=<vault copy> INKSTONE_PARITY_LIST=<sample.txt> \
///     INKSTONE_PARITY_OUT=<inkstone.jsonl> swift test --filter ObsidianParity
///
/// Opt-in: it reads a corpus that is not part of the repository.
@Suite("Obsidian parity counts", .enabled(if: ProcessInfo.processInfo.environment["INKSTONE_PARITY_DIR"] != nil))
struct ObsidianParityTests {
    /// Fenced blocks Obsidian renders as something other than `<pre>`.
    static let nonPreLanguages: Set<String> = ["mermaid", "dataview", "dataviewjs", "math", "tasks", "query", "chart", "tikz"]

    static func counts(_ text: String) -> [String: Int] {
        var c: [String: Int] = [:]
        func add(_ k: String) { c[k, default: 0] += 1 }
        for token in SyntaxScanner().scan(text) {
            switch token.kind {
            case .heading: add("h")
            case .listMarker: add("li")
            case .task: add("task")
            case .wikiLink: add("ilink")
            case .markdownLink(let destination):
                let d = destination.lowercased()
                if d.hasPrefix("http://") || d.hasPrefix("https://") || d.hasPrefix("mailto:") { add("xlink") } else { add("ilink") }
            case .codeBlock(let language):
                if !nonPreLanguages.contains((language ?? "").lowercased()) { add("code") }
            case .table: add("table")
            case .tag: add("tag")
            case .callout: add("callout")
            case .horizontalRule: add("hr")
            case .mathInline, .mathBlock: add("math")
            case .highlight: add("mark")
            case .strikethrough: add("del")
            case .embed: add("embed")
            case .footnoteReference: add("fn")
            case .blockquote: add("bq")
            default: break
            }
        }
        return c
    }

    @Test func writeCounts() throws {
        let env = ProcessInfo.processInfo.environment
        let root = URL(fileURLWithPath: env["INKSTONE_PARITY_DIR"]!)
        let list = try String(contentsOfFile: env["INKSTONE_PARITY_LIST"]!, encoding: .utf8)
            .split(separator: "\n").map(String.init)
        var out = ""
        for path in list {
            guard let text = try? String(contentsOf: root.appending(path: path), encoding: .utf8) else { continue }
            let data = try JSONSerialization.data(withJSONObject: ["path": path, "c": Self.counts(text)], options: [.sortedKeys])
            out += String(decoding: data, as: UTF8.self) + "\n"
        }
        try out.write(toFile: env["INKSTONE_PARITY_OUT"]!, atomically: true, encoding: .utf8)
    }
}
